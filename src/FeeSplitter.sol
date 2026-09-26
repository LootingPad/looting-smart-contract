// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The only shape `buyback` may call. This must be a LOOTING-deployed adapter, never a raw
///         DEX router: Uniswap-style routers take a path array and a different argument order, so
///         allowlisting one directly would mis-decode the calldata.
interface ILootingBuybackAdapter {
    function swapExactETHForTokens(uint256 amountOutMin, address token, address to, uint256 deadline)
        external
        payable
        returns (uint256 amountOut);
}

/// @title FeeSplitter
/// @notice Collects the flat ETH fee charged when creating a Dev Lock or a staking vault and splits
///         it in half: one half is credited to operations, the other is held for a LOOTING buyback.
/// @dev Shared by LootingDevLock and LootingStakingFactory so the split is written once. Both halves
///      leave the contract through pull-style functions with fixed destinations, so no fee path can
///      ever be blocked by a misbehaving recipient or redirected by the keeper.
abstract contract FeeSplitter is AccessControl {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    /// @notice Upper bound on `fee`. The admin can move the fee within this cap only.
    uint256 public constant MAX_FEE = 0.05 ether;

    /// @notice Delay a fee increase must wait before it can be applied, so a create transaction
    ///         already in flight can never be charged more than the UI quoted (spec 26).
    uint256 public constant FEE_TIMELOCK = 1 days;

    /// @notice Half of every fee goes to operations, half to the LOOTING buyback.
    uint16 public constant OPS_SHARE_BPS = 5_000;

    /// @notice Flat ETH fee per create. 0.003 ETH at deploy.
    uint256 public fee;

    /// @notice A scheduled fee increase, applied by `applyFee` once `pendingFeeEffectiveAt` passes.
    uint256 public pendingFee;
    uint64 public pendingFeeEffectiveAt;

    /// @notice Fixed destination of the operations half.
    address public opsWallet;

    /// @notice Fixed destination of the LOOTING bought by `buyback`.
    address public buybackRecipient;

    /// @notice LOOTING token bought by `buyback`. Zero until the token exists.
    address public lootingToken;

    /// @notice Floor price the buyback must beat, in LOOTING per 1 ETH. Bounds how much value a
    ///         compromised keeper could give away through an otherwise valid route (spec 30).
    uint256 public minLootingPerEth;

    /// @notice Adapters the keeper may call from `buyback`.
    mapping(address adapter => bool allowed) public buybackRouter;

    /// @notice ETH held for the LOOTING buyback.
    uint256 public buybackAccrued;

    /// @notice ETH owed to `opsWallet`, withdrawn by `withdrawOps`.
    uint256 public opsAccrued;

    /// @notice Total ETH ever paid out to `opsWallet`, for reporting.
    uint256 public opsPaid;

    event FeeCollected(address indexed payer, uint256 fee, uint256 toOps, uint256 toBuyback, uint256 refunded);
    event FeeChangeScheduled(uint256 currentFee, uint256 newFee, uint64 effectiveAt);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event OpsWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event OpsWithdrawn(address indexed to, uint256 amount);
    event BuybackRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event LootingTokenUpdated(address indexed oldToken, address indexed newToken);
    event MinLootingPerEthUpdated(uint256 oldFloor, uint256 newFloor);
    event BuybackRouterUpdated(address indexed adapter, bool allowed);
    event BuybackExecuted(address indexed adapter, uint256 ethIn, uint256 lootingOut, address indexed to);
    event UntrackedEthSwept(address indexed to, uint256 amount);

    error FeeTooLow(uint256 sent, uint256 required);
    error FeeAboveCap(uint256 requested, uint256 cap);
    error NoPendingFee();
    error FeeTimelockPending(uint64 effectiveAt, uint256 now_);
    error ZeroAddress();
    error EthTransferFailed();
    error NothingToWithdraw();
    error NothingToBuyBack();
    error RouterNotAllowed(address adapter);
    error LootingTokenUnset();
    error BuybackRecipientUnset();
    error PriceFloorUnset();
    error AmountExceedsAccrued(uint256 requested, uint256 available);
    error DeadlinePassed();
    error InsufficientOutput(uint256 received, uint256 minimum);

    constructor(address admin, address keeper, address ops, uint256 initialFee) {
        if (admin == address(0) || keeper == address(0) || ops == address(0)) revert ZeroAddress();
        if (initialFee > MAX_FEE) revert FeeAboveCap(initialFee, MAX_FEE);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, keeper);
        opsWallet = ops;
        fee = initialFee;
    }

    /// @notice Accounts the flat fee out of `msg.value` and splits it.
    /// @dev Pure accounting, no external calls. The caller refunds `refund` with `_refundExcess`
    ///      after all its own state is written, keeping checks-effects-interactions intact.
    /// @return charged The fee kept, reported as `feePaid` in the create events.
    /// @return refund The overpay owed back to the caller.
    function _collectFee() internal returns (uint256 charged, uint256 refund) {
        uint256 required = fee;
        if (msg.value < required) revert FeeTooLow(msg.value, required);

        uint256 toOps = (required * OPS_SHARE_BPS) / 10_000;
        uint256 toBuyback = required - toOps;
        refund = msg.value - required;

        opsAccrued += toOps;
        buybackAccrued += toBuyback;

        emit FeeCollected(msg.sender, required, toOps, toBuyback, refund);
        return (required, refund);
    }

    /// @dev Must be the last statement of a create path.
    function _refundExcess(uint256 refund) internal {
        if (refund > 0) _sendEth(msg.sender, refund);
    }

    /// @notice Pays the accrued operations half to `opsWallet`. Callable by anyone, since the
    ///         destination is fixed, so a stuck wallet can never block a create.
    function withdrawOps() external returns (uint256 amount) {
        amount = opsAccrued;
        if (amount == 0) revert NothingToWithdraw();
        opsAccrued = 0;
        opsPaid += amount;
        address to = opsWallet;
        emit OpsWithdrawn(to, amount);
        _sendEth(to, amount);
    }

    /// @notice Swaps accrued ETH into LOOTING and sends it to `buybackRecipient`.
    /// @dev Keeper-only. The keeper supplies the route and the quote; this contract fixes the
    ///      destination and enforces the budget, the allowlist, the price floor and the deadline
    ///      (spec 10, 30). The output is measured from the recipient's balance rather than trusted
    ///      from the adapter's return value.
    function buyback(address adapter, uint256 ethIn, uint256 minLootingOut, uint256 deadline)
        external
        onlyRole(KEEPER_ROLE)
        returns (uint256 lootingOut)
    {
        if (!buybackRouter[adapter]) revert RouterNotAllowed(adapter);
        address token = lootingToken;
        address to = buybackRecipient;
        uint256 floorPrice = minLootingPerEth;
        if (token == address(0)) revert LootingTokenUnset();
        if (to == address(0)) revert BuybackRecipientUnset();
        if (floorPrice == 0) revert PriceFloorUnset();
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (ethIn == 0) revert NothingToBuyBack();
        if (ethIn > buybackAccrued) revert AmountExceedsAccrued(ethIn, buybackAccrued);

        // The keeper's quote may be tighter than the floor, never looser.
        uint256 floorOut = (ethIn * floorPrice) / 1 ether;
        if (minLootingOut < floorOut) minLootingOut = floorOut;

        buybackAccrued -= ethIn;

        uint256 before = IERC20(token).balanceOf(to);
        ILootingBuybackAdapter(adapter).swapExactETHForTokens{value: ethIn}(minLootingOut, token, to, deadline);
        lootingOut = IERC20(token).balanceOf(to) - before;
        if (lootingOut < minLootingOut) revert InsufficientOutput(lootingOut, minLootingOut);

        emit BuybackExecuted(adapter, ethIn, lootingOut, to);
    }

    /// @notice Lowers the fee immediately, or schedules an increase behind `FEE_TIMELOCK`.
    function setFee(uint256 newFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFee > MAX_FEE) revert FeeAboveCap(newFee, MAX_FEE);
        if (newFee <= fee) {
            emit FeeUpdated(fee, newFee);
            fee = newFee;
            pendingFee = 0;
            pendingFeeEffectiveAt = 0;
            return;
        }
        pendingFee = newFee;
        pendingFeeEffectiveAt = uint64(block.timestamp + FEE_TIMELOCK);
        emit FeeChangeScheduled(fee, newFee, pendingFeeEffectiveAt);
    }

    function applyFee() external {
        uint64 effectiveAt = pendingFeeEffectiveAt;
        if (effectiveAt == 0) revert NoPendingFee();
        if (block.timestamp < effectiveAt) revert FeeTimelockPending(effectiveAt, block.timestamp);
        emit FeeUpdated(fee, pendingFee);
        fee = pendingFee;
        pendingFee = 0;
        pendingFeeEffectiveAt = 0;
    }

    function setOpsWallet(address newWallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newWallet == address(0)) revert ZeroAddress();
        emit OpsWalletUpdated(opsWallet, newWallet);
        opsWallet = newWallet;
    }

    function setBuybackRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit BuybackRecipientUpdated(buybackRecipient, newRecipient);
        buybackRecipient = newRecipient;
    }

    function setLootingToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        emit LootingTokenUpdated(lootingToken, token);
        lootingToken = token;
    }

    function setMinLootingPerEth(uint256 floorPrice) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (floorPrice == 0) revert PriceFloorUnset();
        emit MinLootingPerEthUpdated(minLootingPerEth, floorPrice);
        minLootingPerEth = floorPrice;
    }

    function setBuybackRouter(address adapter, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (adapter == address(0)) revert ZeroAddress();
        buybackRouter[adapter] = allowed;
        emit BuybackRouterUpdated(adapter, allowed);
    }

    /// @notice Recovers ETH that arrived outside `_collectFee`, for example through selfdestruct.
    /// @dev Can only move the balance that no accounting bucket claims.
    function sweepUntrackedEth() external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 amount) {
        uint256 tracked = opsAccrued + buybackAccrued;
        uint256 balance = address(this).balance;
        if (balance <= tracked) revert NothingToWithdraw();
        amount = balance - tracked;
        address to = opsWallet;
        emit UntrackedEthSwept(to, amount);
        _sendEth(to, amount);
    }

    function _sendEth(address to, uint256 amount) private {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
