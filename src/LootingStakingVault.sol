// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IStakingFactoryView {
    function paused() external view returns (bool);
}

/// @title LootingStakingVault
/// @notice One vault per Create Staking event. Holds the staked principal and the creator-funded
///         reward pool for a single LOOTING-launched token (spec 16, 55).
/// @dev Deployed as an EIP-1167 clone by LootingStakingFactory, so all setup happens in `initialize`
///      rather than a constructor. Reward accrual is continuous per position; nothing is minted, so
///      payouts are capped by what the creator funded.
contract LootingStakingVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Lock options, matching the Staking UI: 0 = Flexible, 1 = 30 days, 2 = 90 days.
    uint8 public constant LOCK_COUNT = 3;

    uint256 private constant YEAR = 365 days;
    uint256 private constant BPS = 10_000;

    struct Position {
        /// @dev Principal currently staked in this lock.
        uint256 staked;
        /// @dev Rewards already accrued but not yet paid out.
        uint256 accrued;
        /// @dev Timestamp `accrued` was last brought up to date.
        uint64 lastAccrualAt;
        /// @dev Principal is withdrawable from this timestamp. Always `block.timestamp` for flex.
        uint64 lockEndsAt;
    }

    /// @notice The factory that cloned this vault. Its pause flag also pauses this vault (spec 16).
    IStakingFactoryView public factory;

    /// @notice Id assigned by the factory, used as the indexed key in every event (spec 35).
    uint256 public vaultId;

    /// @notice Token that is both staked and paid out as reward (MVP: same ERC-20, spec 16).
    IERC20 public stakeToken;

    /// @notice Wallet that created and funded the event.
    address public creator;

    /// @notice Reward tokens still available to pay out.
    uint256 public rewardRemaining;

    /// @notice Total reward funded at create, kept for reporting.
    uint256 public rewardFunded;

    /// @notice Principal staked across all locks. Never counted as reward (spec 17).
    uint256 public totalStaked;

    /// @notice Event end. New stakes revert from here; claims and unlocked unstakes continue.
    uint64 public endsAt;

    /// @notice Enabled locks as a bitmask: bit0 = flex, bit1 = 30d, bit2 = 90d.
    uint8 public lockMask;

    /// @notice Distinct wallets holding a non-zero position, for the Events list.
    uint256 public stakerCount;

    /// @dev APR in bps per lock, snapshotted at create.
    uint16[LOCK_COUNT] private _aprBps;

    /// @dev Set once by `initialize`; pre-set in the constructor so the implementation itself is
    ///      never initializable.
    bool private _initialized;

    mapping(address wallet => mapping(uint8 lockId => Position)) private _positions;
    mapping(address wallet => uint256 totalStakedByWallet) public stakedOf;

    event Staked(uint256 indexed vaultId, address indexed wallet, uint8 lockId, uint256 amount);
    event Unstaked(uint256 indexed vaultId, address indexed wallet, uint8 lockId, uint256 amount);
    event StakingRewardsClaimed(uint256 indexed vaultId, address indexed wallet, uint8 lockId, uint256 amount);

    error AlreadyInitialized();
    error ZeroAddress();
    error ZeroAmount();
    error LockDisabled(uint8 lockId);
    error EventEnded(uint64 endsAt, uint256 now_);
    error StillLocked(uint64 lockEndsAt, uint256 now_);
    error InsufficientStake(uint256 requested, uint256 available);
    error VaultPaused();
    error UnexpectedTokenBalance(uint256 expected, uint256 received);

    /// @dev ReentrancyGuard's constructor does not run for clones, but its guard only rejects the
    ///      ENTERED sentinel, so zero-initialized clone storage behaves as NOT_ENTERED.
    constructor() {
        // Locks the implementation: a clone starts with fresh storage and can still initialize.
        _initialized = true;
    }

    /// @notice Configures a fresh clone. Callable exactly once, by the factory, inside `createVault`.
    function initialize(
        address factory_,
        uint256 vaultId_,
        address stakeToken_,
        address creator_,
        uint256 rewardAmount,
        uint64 endsAt_,
        uint8 lockMask_,
        uint16[LOCK_COUNT] calldata aprBps_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        if (factory_ == address(0) || stakeToken_ == address(0) || creator_ == address(0)) revert ZeroAddress();
        _initialized = true;

        factory = IStakingFactoryView(factory_);
        vaultId = vaultId_;
        stakeToken = IERC20(stakeToken_);
        creator = creator_;
        rewardFunded = rewardAmount;
        rewardRemaining = rewardAmount;
        endsAt = endsAt_;
        lockMask = lockMask_;
        _aprBps = aprBps_;
    }

    /// @notice Stakes `amount` into `lockId`. Restarts the lock window for that position.
    function stake(uint256 amount, uint8 lockId) external nonReentrant {
        _requireNotPaused();
        if (amount == 0) revert ZeroAmount();
        if (!lockEnabled(lockId)) revert LockDisabled(lockId);
        if (block.timestamp >= endsAt) revert EventEnded(endsAt, block.timestamp);

        Position storage pos = _positions[msg.sender][lockId];
        _accrue(pos, lockId);

        if (stakedOf[msg.sender] == 0) stakerCount += 1;

        pos.staked += amount;
        // Topping up re-locks the whole position, so the lock can never be shortened by staking
        // a dust amount late in the window.
        pos.lockEndsAt = uint64(block.timestamp + lockDuration(lockId));
        stakedOf[msg.sender] += amount;
        totalStaked += amount;

        emit Staked(vaultId, msg.sender, lockId, amount);

        // Fee-on-transfer and rebasing tokens are rejected rather than silently under-funding the
        // pool, which would otherwise break the "principal is always withdrawable" invariant.
        uint256 before = stakeToken.balanceOf(address(this));
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = stakeToken.balanceOf(address(this)) - before;
        if (received != amount) revert UnexpectedTokenBalance(amount, received);
    }

    /// @notice Withdraws principal from `lockId` once the lock window has passed.
    /// @dev Never blocked by an empty reward pool: accrual is recorded and stays claimable.
    function unstake(uint256 amount, uint8 lockId) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        Position storage pos = _positions[msg.sender][lockId];
        if (amount > pos.staked) revert InsufficientStake(amount, pos.staked);
        if (block.timestamp < pos.lockEndsAt) revert StillLocked(pos.lockEndsAt, block.timestamp);

        _accrue(pos, lockId);

        pos.staked -= amount;
        stakedOf[msg.sender] -= amount;
        totalStaked -= amount;
        if (stakedOf[msg.sender] == 0 && stakerCount > 0) stakerCount -= 1;

        emit Unstaked(vaultId, msg.sender, lockId, amount);

        stakeToken.safeTransfer(msg.sender, amount);
    }

    /// @notice Pays out accrued rewards for `lockId`, capped by `rewardRemaining` (spec 17).
    function claimRewards(uint8 lockId) external nonReentrant returns (uint256 paid) {
        Position storage pos = _positions[msg.sender][lockId];
        _accrue(pos, lockId);

        uint256 owed = pos.accrued;
        uint256 available = rewardRemaining;
        paid = owed < available ? owed : available;
        if (paid == 0) return 0;

        pos.accrued = owed - paid;
        rewardRemaining = available - paid;

        emit StakingRewardsClaimed(vaultId, msg.sender, lockId, paid);

        stakeToken.safeTransfer(msg.sender, paid);
    }

    /// @notice Rewards claimable now, capped by the remaining pool so the UI shows a payable number.
    function pendingRewards(address wallet, uint8 lockId) external view returns (uint256) {
        Position storage pos = _positions[wallet][lockId];
        uint256 owed = pos.accrued + _accrualSince(pos, lockId);
        uint256 available = rewardRemaining;
        return owed < available ? owed : available;
    }

    /// @notice Position shape the Staking → Positions UI reads (spec 16).
    function position(address wallet, uint8 lockId)
        external
        view
        returns (uint256 staked, uint256 rewardDebtOrAccrued, uint64 lockEndsAt)
    {
        Position storage pos = _positions[wallet][lockId];
        return (pos.staked, pos.accrued + _accrualSince(pos, lockId), pos.lockEndsAt);
    }

    /// @notice Everything the Staking → Events row needs in one call.
    function vaultInfo()
        external
        view
        returns (
            uint256 id,
            address token,
            address vaultCreator,
            uint256 funded,
            uint256 remaining,
            uint256 staked,
            uint64 endTime,
            uint8 mask,
            uint16[LOCK_COUNT] memory aprBps,
            uint256 stakers
        )
    {
        return (
            vaultId,
            address(stakeToken),
            creator,
            rewardFunded,
            rewardRemaining,
            totalStaked,
            endsAt,
            lockMask,
            _aprBps,
            stakerCount
        );
    }

    function aprBpsOf(uint8 lockId) public view returns (uint16) {
        if (lockId >= LOCK_COUNT) return 0;
        return _aprBps[lockId];
    }

    function lockEnabled(uint8 lockId) public view returns (bool) {
        if (lockId >= LOCK_COUNT) return false;
        return lockMask & (uint8(1) << lockId) != 0;
    }

    /// @notice Lock durations matching STAKING_LOCK_OPTIONS in the frontend.
    function lockDuration(uint8 lockId) public pure returns (uint256) {
        if (lockId == 1) return 30 days;
        if (lockId == 2) return 90 days;
        return 0;
    }

    /// @dev Folds elapsed accrual into the position and moves the accrual clock forward.
    function _accrue(Position storage pos, uint8 lockId) private {
        uint256 delta = _accrualSince(pos, lockId);
        if (delta > 0) pos.accrued += delta;
        pos.lastAccrualAt = uint64(_accrualCutoff());
    }

    /// @dev Simple interest on the current principal: `staked * apr * elapsed / (BPS * YEAR)`.
    ///      Accrual stops at `endsAt`, so an abandoned vault cannot keep minting entitlement.
    function _accrualSince(Position storage pos, uint8 lockId) private view returns (uint256) {
        uint256 staked = pos.staked;
        if (staked == 0) return 0;

        uint256 last = pos.lastAccrualAt;
        uint256 until = _accrualCutoff();
        if (until <= last) return 0;

        return (staked * aprBpsOf(lockId) * (until - last)) / (BPS * YEAR);
    }

    function _accrualCutoff() private view returns (uint256) {
        uint64 end = endsAt;
        return block.timestamp < end ? block.timestamp : end;
    }

    /// @dev Reads the pause flag from the factory so one admin action freezes every vault (spec 16).
    function _requireNotPaused() private view {
        if (factory.paused()) revert VaultPaused();
    }
}
