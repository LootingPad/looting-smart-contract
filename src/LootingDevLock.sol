// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {FeeSplitter} from "./FeeSplitter.sol";
import {LootingLaunchRegistry} from "./LootingLaunchRegistry.sol";

/// @title LootingDevLock
/// @notice Lets the creator of a LOOTING launch lock or vest supply of their own coin. A lock can
///         never be cancelled; tokens return to the owner only as the schedule releases them.
/// @dev Backs the /devlock page. Share cards are frontend-only and touch no contract (spec 54).
contract LootingDevLock is FeeSplitter, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum DevLockMode {
        Time,
        Vest
    }

    /// @notice UI metadata only. Vesting math is continuous linear regardless of cadence (spec 16).
    enum DevLockCadence {
        Day,
        Week,
        Month
    }

    struct DevLockPosition {
        uint256 id;
        address owner;
        address token;
        DevLockMode mode;
        uint256 amount;
        uint256 claimed;
        uint64 start;
        uint64 cliff;
        uint64 unlock;
        DevLockCadence cadence;
    }

    LootingLaunchRegistry public immutable registry;

    uint256 public nextLockId = 1;

    mapping(uint256 lockId => DevLockPosition) private _locks;
    mapping(address owner => uint256[] lockIds) private _ownerLocks;
    /// @dev Position of a lock id inside its owner's array, so closing a lock is O(1).
    mapping(uint256 lockId => uint256 index) private _ownerLockIndex;

    event DevLockCreated(
        uint256 indexed lockId,
        address indexed owner,
        address indexed token,
        uint8 mode,
        uint256 amount,
        uint64 cliff,
        uint64 unlock,
        uint256 feePaid
    );
    event DevLockClaimed(uint256 indexed lockId, address indexed owner, uint256 amount);
    event DevLockClosed(uint256 indexed lockId);

    error NotLaunchCreator(address token, address caller, address creator);
    error ZeroAmount();
    error UnlockNotInFuture(uint64 unlockAt, uint256 now_);
    error CliffInThePast(uint64 cliffAt, uint256 now_);
    error UnlockBeforeCliff(uint64 cliffAt, uint64 unlockAt);
    error UnknownLock(uint256 lockId);
    error NotLockOwner(uint256 lockId, address caller);
    error NothingToClaim(uint256 lockId);
    error UnexpectedTokenBalance(uint256 expected, uint256 received);

    constructor(address admin, address keeper, address ops, uint256 initialFee, LootingLaunchRegistry registry_)
        FeeSplitter(admin, keeper, ops, initialFee)
    {
        if (address(registry_) == address(0)) revert ZeroAddress();
        registry = registry_;
    }

    /// @notice Locks `amount` until `unlockAt`, when the whole amount becomes claimable at once.
    function createTimeLock(address token, uint256 amount, uint64 unlockAt)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 lockId)
    {
        if (unlockAt <= block.timestamp) revert UnlockNotInFuture(unlockAt, block.timestamp);
        return _create(token, amount, DevLockMode.Time, uint64(block.timestamp), unlockAt, DevLockCadence.Day);
    }

    /// @notice Vests `amount` linearly from `cliffAt` to `unlockAt`. Nothing is claimable before the cliff.
    function createVesting(address token, uint256 amount, uint64 cliffAt, uint64 unlockAt, DevLockCadence cadence)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 lockId)
    {
        if (cliffAt < block.timestamp) revert CliffInThePast(cliffAt, block.timestamp);
        if (unlockAt <= cliffAt) revert UnlockBeforeCliff(cliffAt, unlockAt);
        return _create(token, amount, DevLockMode.Vest, cliffAt, unlockAt, cadence);
    }

    /// @notice Sends everything vested but not yet claimed to the lock owner.
    function claim(uint256 lockId) external nonReentrant returns (uint256 paid) {
        DevLockPosition storage lock = _locks[lockId];
        if (lock.owner == address(0)) revert UnknownLock(lockId);
        if (lock.owner != msg.sender) revert NotLockOwner(lockId, msg.sender);

        paid = _claimable(lock);
        if (paid == 0) revert NothingToClaim(lockId);

        uint256 claimedAfter = lock.claimed + paid;
        address token = lock.token;
        address owner = lock.owner;
        bool closing = claimedAfter >= lock.amount;

        if (closing) {
            _removeOwnerLock(owner, lockId);
            delete _locks[lockId];
        } else {
            lock.claimed = claimedAfter;
        }

        emit DevLockClaimed(lockId, owner, paid);
        if (closing) emit DevLockClosed(lockId);

        IERC20(token).safeTransfer(owner, paid);
    }

    /// @notice vested(now) per spec 16: full after unlock, zero for time locks and before the cliff,
    ///         otherwise linear from cliff to unlock.
    function vestedAmount(uint256 lockId) external view returns (uint256) {
        DevLockPosition storage lock = _locks[lockId];
        if (lock.owner == address(0)) revert UnknownLock(lockId);
        return _vested(lock);
    }

    function claimableAmount(uint256 lockId) external view returns (uint256) {
        DevLockPosition storage lock = _locks[lockId];
        if (lock.owner == address(0)) revert UnknownLock(lockId);
        return _claimable(lock);
    }

    function lockOf(uint256 lockId) external view returns (DevLockPosition memory) {
        DevLockPosition storage lock = _locks[lockId];
        if (lock.owner == address(0)) revert UnknownLock(lockId);
        return lock;
    }

    /// @notice Active lock ids for one wallet. Fully claimed locks are removed.
    function locksOf(address owner) external view returns (uint256[] memory) {
        return _ownerLocks[owner];
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _create(
        address token,
        uint256 amount,
        DevLockMode mode,
        uint64 cliffAt,
        uint64 unlockAt,
        DevLockCadence cadence
    ) private returns (uint256 lockId) {
        if (amount == 0) revert ZeroAmount();

        // Only the launch creator may lock that launch's supply (spec 61.5).
        address creator = registry.creatorOf(token);
        if (creator != msg.sender) revert NotLaunchCreator(token, msg.sender, creator);

        (uint256 feePaid, uint256 refund) = _collectFee();

        lockId = nextLockId++;
        _locks[lockId] = DevLockPosition({
            id: lockId,
            owner: msg.sender,
            token: token,
            mode: mode,
            amount: amount,
            claimed: 0,
            start: uint64(block.timestamp),
            cliff: cliffAt,
            unlock: unlockAt,
            cadence: cadence
        });
        _ownerLockIndex[lockId] = _ownerLocks[msg.sender].length;
        _ownerLocks[msg.sender].push(lockId);

        emit DevLockCreated(lockId, msg.sender, token, uint8(mode), amount, cliffAt, unlockAt, feePaid);

        // Rebasing and fee-on-transfer tokens are rejected rather than silently under-funding the
        // schedule (spec 61.7).
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        if (received != amount) revert UnexpectedTokenBalance(amount, received);

        _refundExcess(refund);
    }

    function _vested(DevLockPosition storage lock) private view returns (uint256) {
        if (block.timestamp >= lock.unlock) return lock.amount;
        if (lock.mode == DevLockMode.Time || block.timestamp <= lock.cliff) return 0;
        return (lock.amount * (block.timestamp - lock.cliff)) / (lock.unlock - lock.cliff);
    }

    function _claimable(DevLockPosition storage lock) private view returns (uint256) {
        uint256 vested = _vested(lock);
        return vested > lock.claimed ? vested - lock.claimed : 0;
    }

    function _removeOwnerLock(address owner, uint256 lockId) private {
        uint256[] storage ids = _ownerLocks[owner];
        uint256 index = _ownerLockIndex[lockId];
        uint256 last = ids.length - 1;
        if (index != last) {
            uint256 moved = ids[last];
            ids[index] = moved;
            _ownerLockIndex[moved] = index;
        }
        ids.pop();
        delete _ownerLockIndex[lockId];
    }
}
