// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {LootingLaunchRegistry} from "./LootingLaunchRegistry.sol";

interface IPonsFeeEscrow {
    function balanceOf(address recipient) external view returns (uint256);
    function claim() external;
}

/// @dev Pons V2 bonding curve — accrued fees sit on-curve until the recipient/operator sweeps.
interface IPonsBondingCurve {
    function sweepFees(uint256 minBuybackTokensOut) external;
    function creatorTaxBalance() external view returns (uint256);
    function quoteFeeBalance() external view returns (uint256);
}

/// @title LootingRewardRouter
/// @notice Receives Pons creator-fee ETH (as `creatorFeeRecipient`) and splits it per launch config:
///         creator claimable vs Lucky Box pool. Of the box share, 20% accrues as $LOOTING burn budget
///         and 80% as openable box rewards (product brainstorm lock).
/// @dev Automatic path (no Pons owner): this router is set as `creatorFeeRecipient` at launch →
///      after trades call `sweepPonsCurveFees(curve)` (credits FeeEscrow) → `harvestPonsFees()` →
///      `allocate`. Prefer `buybackEnabled=false` on LOOTING launches so recipient sweep is not
///      blocked by Pons `InternalSwapRequiresOperator`. No arbitrary withdraw / rescue.
///      Creator paid to registry.creator. Box ETH pulled only by the configured lucky-box module.
contract LootingRewardRouter is AccessControl, ReentrancyGuard, Pausable {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint16 public constant BPS = 10_000;
    /// @notice Share of the Lucky Box cut reserved to buy+burn $LOOTING.
    uint16 public constant BOX_BURN_BPS = 2_000;

    LootingLaunchRegistry public immutable registry;

    /// @notice ETH received via `receive` not yet assigned to a launch.
    uint256 public unallocatedEth;

    /// @notice Creator claimable ETH per launch token.
    mapping(address token => uint256) public creatorAccrued;
    mapping(address token => uint256) public creatorPaid;

    /// @notice Lucky Box reward ETH (80% of box share) per launch token.
    mapping(address token => uint256) public luckyBoxRewardAccrued;
    mapping(address token => uint256) public luckyBoxRewardPaid;

    /// @notice Global ETH reserved to buy+burn $LOOTING (20% of every box share).
    uint256 public burnBudgetAccrued;
    uint256 public burnBudgetPaid;

    /// @notice Fixed pull destination for burn budget until the buyback adapter ships.
    address public burnWallet;

    /// @notice Only this module may pull lucky-box reward ETH (then forward to winners).
    address public luckyBoxModule;

    /// @notice Pons FeeEscrow — claimable native balance for this router as creatorFeeRecipient.
    address public ponsFeeEscrow;

    event TaxReceived(address indexed from, uint256 amount);
    event TaxAllocated(
        address indexed token, uint256 amount, uint256 toCreator, uint256 toBoxReward, uint256 toBurnBudget
    );
    event CreatorClaimed(address indexed token, address indexed creator, uint256 amount);
    event LuckyBoxRewardPulled(address indexed token, address indexed module, uint256 amount);
    event BurnBudgetWithdrawn(address indexed to, uint256 amount);
    event BurnWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event LuckyBoxModuleUpdated(address indexed oldModule, address indexed newModule);
    event PonsFeeEscrowUpdated(address indexed oldEscrow, address indexed newEscrow);
    event PonsFeesHarvested(address indexed escrow, uint256 amount);
    event PonsCurveFeesSwept(address indexed curve, uint256 minBuybackTokensOut);

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientUnallocated(uint256 requested, uint256 available);
    error InsufficientCreator(uint256 requested, uint256 available);
    error InsufficientBoxReward(uint256 requested, uint256 available);
    error InsufficientBurnBudget(uint256 requested, uint256 available);
    error RewardsPaused(address token);
    error NotLuckyBoxModule(address caller);
    error EthTransferFailed();
    error BadSplit();
    error FeeEscrowNotSet();
    error NothingToHarvest();

    constructor(address admin, address keeper, address pauser, address registry_, address burnWallet_) {
        if (
            admin == address(0) || keeper == address(0) || pauser == address(0) || registry_ == address(0)
                || burnWallet_ == address(0)
        ) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, keeper);
        _grantRole(PAUSER_ROLE, pauser);
        registry = LootingLaunchRegistry(registry_);
        burnWallet = burnWallet_;
    }

    receive() external payable {
        if (msg.value == 0) revert ZeroAmount();
        unallocatedEth += msg.value;
        emit TaxReceived(msg.sender, msg.value);
    }

    /// @notice Sweep accrued fees from a Pons bonding curve into FeeEscrow for this recipient.
    /// @dev Permissionless. `msg.sender` to the curve is this router (= creatorFeeRecipient).
    ///      Use `minBuybackTokensOut=0` when the launch was created with `buybackEnabled=false`.
    function sweepPonsCurveFees(address curve, uint256 minBuybackTokensOut)
        external
        nonReentrant
        whenNotPaused
    {
        if (curve == address(0)) revert ZeroAddress();
        IPonsBondingCurve(curve).sweepFees(minBuybackTokensOut);
        emit PonsCurveFeesSwept(curve, minBuybackTokensOut);
    }

    /// @notice Pull this router's claimable ETH from Pons FeeEscrow into `unallocatedEth`.
    /// @dev Permissionless. Destination is always this contract (FeeEscrow.claim → msg.sender).
    function harvestPonsFees() external nonReentrant whenNotPaused returns (uint256 amount) {
        address escrow = ponsFeeEscrow;
        if (escrow == address(0)) revert FeeEscrowNotSet();
        amount = IPonsFeeEscrow(escrow).balanceOf(address(this));
        if (amount == 0) revert NothingToHarvest();
        // FeeEscrow pays msg.sender; `receive` credits `unallocatedEth`.
        IPonsFeeEscrow(escrow).claim();
        emit PonsFeesHarvested(escrow, amount);
    }

    /// @notice Assign unallocated ETH to a registered launch and split per registry bps.
    /// @dev Permissionless so the indexer/keeper (or anyone) can settle after CurveBuy/Sell tax.
    function allocate(address token, uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (amount > unallocatedEth) revert InsufficientUnallocated(amount, unallocatedEth);

        LootingLaunchRegistry.LaunchRewardConfig memory cfg = registry.configOf(token);
        if (!cfg.rewardsEnabled) revert RewardsPaused(token);
        if (cfg.totalCreatorFeeBps == 0 || cfg.creatorBps + cfg.luckyBoxBps != cfg.totalCreatorFeeBps) {
            revert BadSplit();
        }

        unallocatedEth -= amount;

        uint256 toCreator = (amount * uint256(cfg.creatorBps)) / uint256(cfg.totalCreatorFeeBps);
        uint256 toBoxGross = amount - toCreator;
        uint256 toBurn = (toBoxGross * uint256(BOX_BURN_BPS)) / uint256(BPS);
        uint256 toBoxReward = toBoxGross - toBurn;

        creatorAccrued[token] += toCreator;
        luckyBoxRewardAccrued[token] += toBoxReward;
        burnBudgetAccrued += toBurn;

        emit TaxAllocated(token, amount, toCreator, toBoxReward, toBurn);
    }

    /// @notice Creator pulls claimable ETH for one launch. Destination is registry.creator only.
    function claimCreator(address token) external nonReentrant whenNotPaused returns (uint256 amount) {
        LootingLaunchRegistry.LaunchRewardConfig memory cfg = registry.configOf(token);
        if (!cfg.rewardsEnabled) revert RewardsPaused(token);

        uint256 accrued = creatorAccrued[token];
        uint256 paid = creatorPaid[token];
        if (accrued <= paid) revert InsufficientCreator(0, 0);
        amount = accrued - paid;
        creatorPaid[token] = accrued;

        address to = cfg.creator;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();

        emit CreatorClaimed(token, to, amount);
    }

    /// @notice Lucky-box module pulls reward ETH for `token` (module forwards to winners).
    function pullLuckyBoxReward(address token, uint256 amount) external nonReentrant whenNotPaused returns (uint256) {
        if (msg.sender != luckyBoxModule || luckyBoxModule == address(0)) {
            revert NotLuckyBoxModule(msg.sender);
        }
        if (amount == 0) revert ZeroAmount();

        uint256 accrued = luckyBoxRewardAccrued[token];
        uint256 paid = luckyBoxRewardPaid[token];
        uint256 available = accrued - paid;
        if (amount > available) revert InsufficientBoxReward(amount, available);

        luckyBoxRewardPaid[token] = paid + amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert EthTransferFailed();

        emit LuckyBoxRewardPulled(token, msg.sender, amount);
        return amount;
    }

    /// @notice Permissionless pull of burn budget to the fixed `burnWallet` (ops executes buy+burn).
    function withdrawBurnBudget(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        uint256 available = burnBudgetAccrued - burnBudgetPaid;
        if (amount > available) revert InsufficientBurnBudget(amount, available);

        burnBudgetPaid += amount;
        address to = burnWallet;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();

        emit BurnBudgetWithdrawn(to, amount);
    }

    function setBurnWallet(address newWallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newWallet == address(0)) revert ZeroAddress();
        address old = burnWallet;
        burnWallet = newWallet;
        emit BurnWalletUpdated(old, newWallet);
    }

    function setLuckyBoxModule(address module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address old = luckyBoxModule;
        luckyBoxModule = module;
        emit LuckyBoxModuleUpdated(old, module);
    }

    function setPonsFeeEscrow(address escrow) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (escrow == address(0)) revert ZeroAddress();
        address old = ponsFeeEscrow;
        ponsFeeEscrow = escrow;
        emit PonsFeeEscrowUpdated(old, escrow);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function creatorClaimable(address token) external view returns (uint256) {
        uint256 accrued = creatorAccrued[token];
        uint256 paid = creatorPaid[token];
        return accrued > paid ? accrued - paid : 0;
    }

    function luckyBoxClaimable(address token) external view returns (uint256) {
        uint256 accrued = luckyBoxRewardAccrued[token];
        uint256 paid = luckyBoxRewardPaid[token];
        return accrued > paid ? accrued - paid : 0;
    }

    function burnBudgetClaimable() external view returns (uint256) {
        return burnBudgetAccrued - burnBudgetPaid;
    }

    function ponsEscrowClaimable() external view returns (uint256) {
        address escrow = ponsFeeEscrow;
        if (escrow == address(0)) return 0;
        return IPonsFeeEscrow(escrow).balanceOf(address(this));
    }
}
