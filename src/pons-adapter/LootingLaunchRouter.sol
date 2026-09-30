// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @dev Minimal Pons V2 factory surface used by this router. Kept here (not a raw Multicall) so
///      LOOTING can collect its launch fee in the same user-signed tx as `launchToken`.
interface IPonsV2Factory {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    struct TokenParams {
        string name;
        string symbol;
        string logo;
        string description;
        Socials socials;
        address creatorFeeRecipient;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        bytes32 expectedEconomics;
        bytes32 salt;
    }

    function launchFee() external view returns (uint256);

    function launchToken(TokenParams calldata params, uint256 launchConfigId, address pairToken)
        external
        payable
        returns (address token, address curve);

    function launchToken(
        TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address[] calldata snipeTaxExemptions
    ) external payable returns (address token, address curve);
}

/// @title LootingLaunchRouter
/// @notice One user confirm: take LOOTING's flat launch fee, then forward the Pons `launchFee` into
///         `launchToken`. Pons records `msg.sender` (this router) as deployer; we force
///         `creatorFeeRecipient` to `LootingRewardRouter` and emit `LaunchViaLooting` so the
///         backend attributes the launch to the user wallet.
/// @dev Isolated under `pons-adapter/` (AGENTS.md). Creator tax accrues on the Pons curve until
///      `RewardRouter.sweepPonsCurveFees` → FeeEscrow → `harvestPonsFees` → `allocate`. LOOTING
///      launches force `buybackEnabled=false` so recipient sweep is not blocked by Pons operator.
///      Never Multicall3 — that would still make the multicall the deployer and cannot collect a
///      separate fee destination safely.
contract LootingLaunchRouter is AccessControl, ReentrancyGuard, Pausable {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 public constant MAX_FEE = 0.05 ether;

    IPonsV2Factory public immutable ponsFactory;

    /// @notice LOOTING cut of the create fee (product: 0.00035 ETH). Not part of the Pons launchFee.
    uint256 public fee;

    /// @notice Fixed destination for the LOOTING launch fee. Admin-set; never a call parameter.
    address public feeWallet;

    /// @notice LootingRewardRouter — forced as Pons `creatorFeeRecipient` on every launch.
    address public rewardRouter;

    uint256 public feesCollected;

    event LaunchViaLooting(
        address indexed creator,
        address indexed token,
        address indexed curve,
        uint256 lootingFeePaid,
        uint256 ponsFeePaid
    );
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event RewardRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event FeePaid(address indexed payer, address indexed to, uint256 amount);

    error ZeroAddress();
    error FeeAboveCap(uint256 requested, uint256 cap);
    error FeeTooLow(uint256 sent, uint256 required);
    error EthTransferFailed();
    error RewardRouterNotSet();
    error PonsLaunchFailed(bytes reason);

    constructor(
        address admin,
        address pauser,
        address ponsFactory_,
        address feeWallet_,
        address rewardRouter_,
        uint256 initialFee
    ) {
        if (
            admin == address(0) || pauser == address(0) || ponsFactory_ == address(0) || feeWallet_ == address(0)
                || rewardRouter_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (initialFee > MAX_FEE) revert FeeAboveCap(initialFee, MAX_FEE);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);

        ponsFactory = IPonsV2Factory(ponsFactory_);
        feeWallet = feeWallet_;
        rewardRouter = rewardRouter_;
        fee = initialFee;
    }

    /// @notice Launch on Pons and pay the LOOTING fee in one transaction.
    /// @dev Forces `creatorFeeRecipient = rewardRouter` and `buybackEnabled = false`.
    function launch(IPonsV2Factory.TokenParams calldata params, uint256 launchConfigId, address pairToken)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (address token, address curve)
    {
        return _launch(params, launchConfigId, pairToken, new address[](0));
    }

    function launch(
        IPonsV2Factory.TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address[] calldata snipeTaxExemptions
    ) external payable nonReentrant whenNotPaused returns (address token, address curve) {
        return _launch(params, launchConfigId, pairToken, snipeTaxExemptions);
    }

    function setFee(uint256 newFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFee > MAX_FEE) revert FeeAboveCap(newFee, MAX_FEE);
        uint256 old = fee;
        fee = newFee;
        emit FeeUpdated(old, newFee);
    }

    function setFeeWallet(address newWallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newWallet == address(0)) revert ZeroAddress();
        address old = feeWallet;
        feeWallet = newWallet;
        emit FeeWalletUpdated(old, newWallet);
    }

    function setRewardRouter(address newRouter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRouter == address(0)) revert ZeroAddress();
        address old = rewardRouter;
        rewardRouter = newRouter;
        emit RewardRouterUpdated(old, newRouter);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function _launch(
        IPonsV2Factory.TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address[] memory snipeTaxExemptions
    ) private returns (address token, address curve) {
        address router = rewardRouter;
        if (router == address(0)) revert RewardRouterNotSet();

        uint256 ponsFee = ponsFactory.launchFee();
        uint256 lootingFee = fee;
        uint256 required = ponsFee + lootingFee;
        if (msg.value < required) revert FeeTooLow(msg.value, required);

        // Force tax → RewardRouter; disable Pons buyback so recipient can sweepFees without operator.
        IPonsV2Factory.TokenParams memory p = params;
        p.creatorFeeRecipient = router;
        p.buybackEnabled = false;

        // Effects: account fee before external calls.
        feesCollected += lootingFee;

        // Interactions: pay LOOTING fee wallet (fixed destination).
        _payFee(lootingFee);

        // Interactions: Pons launch — deployer on-chain will be this router.
        if (snipeTaxExemptions.length == 0) {
            (token, curve) = ponsFactory.launchToken{value: ponsFee}(p, launchConfigId, pairToken);
        } else {
            (token, curve) = ponsFactory.launchToken{value: ponsFee}(p, launchConfigId, pairToken, snipeTaxExemptions);
        }

        emit LaunchViaLooting(msg.sender, token, curve, lootingFee, ponsFee);
        emit FeePaid(msg.sender, feeWallet, lootingFee);

        // Refund excess last (CEI).
        uint256 refund = msg.value - required;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert EthTransferFailed();
        }
    }

    function _payFee(uint256 amount) private {
        (bool ok,) = feeWallet.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
