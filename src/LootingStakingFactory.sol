// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {FeeSplitter} from "./FeeSplitter.sol";
import {LootingLaunchRegistry} from "./LootingLaunchRegistry.sol";
import {LootingStakingVault} from "./LootingStakingVault.sol";

/// @title LootingStakingFactory
/// @notice Creates one staking vault per Create Staking event and is the registry the Staking →
///         Events list is built from (spec 16, 55a).
/// @dev Vaults are EIP-1167 clones of a single implementation, so one event can never touch another
///      event's principal. `paused()` is read by every vault, so pausing here freezes all of them.
contract LootingStakingFactory is FeeSplitter, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 private constant LOCK_COUNT = 3;

    /// @notice Registry of LOOTING launches. Only registered tokens may be staked (spec 16).
    LootingLaunchRegistry public immutable registry;

    /// @notice Clone template. Locked against initialization in its own constructor.
    address public immutable vaultImplementation;

    /// @notice Highest APR a creator may promise, bounding the entitlement a vault can accrue.
    uint16 public constant MAX_APR_BPS = 10_000;

    /// @notice Longest event duration accepted at create.
    uint64 public constant MAX_DURATION = 365 days;

    uint256 public nextVaultId = 1;

    mapping(uint256 vaultId => address vault) public vaultById;
    mapping(address vault => uint256 vaultId) public vaultIdOf;

    /// @dev All vaults in creation order, for paginated reads.
    address[] private _vaults;
    /// @dev Vaults per stake token, so the UI can show every event for one coin.
    mapping(address stakeToken => address[] vaults) private _vaultsByToken;

    event StakingVaultCreated(
        uint256 indexed vaultId,
        address indexed vault,
        address indexed stakeToken,
        address creator,
        uint256 rewardAmount,
        uint256 feePaid,
        uint64 endsAt,
        uint8 lockMask
    );

    error TokenNotRegistered(address token);
    error ZeroAmount();
    error EndNotInFuture(uint64 endsAt, uint256 now_);
    error DurationTooLong(uint64 endsAt, uint256 max);
    error NoLockEnabled();
    error AprAboveCap(uint8 lockId, uint16 aprBps, uint16 cap);
    error AprSetForDisabledLock(uint8 lockId);
    error AprMissingForEnabledLock(uint8 lockId);
    error UnexpectedTokenBalance(uint256 expected, uint256 received);

    constructor(
        address admin,
        address keeper,
        address ops,
        uint256 initialFee,
        LootingLaunchRegistry registry_,
        address vaultImplementation_
    ) FeeSplitter(admin, keeper, ops, initialFee) {
        if (address(registry_) == address(0) || vaultImplementation_ == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        vaultImplementation = vaultImplementation_;
    }

    /// @notice Creates and funds a staking event. The wallet pays the flat create fee and the reward
    ///         pool; the fee is protocol revenue and is never part of the pool (spec 16).
    /// @param lockMask bit0 = flexible, bit1 = 30 days, bit2 = 90 days.
    /// @param aprBps APR per lock, snapshotted into the vault. Must be zero for disabled locks.
    function createVault(
        address stakeToken,
        uint256 rewardAmount,
        uint64 endsAt,
        uint8 lockMask,
        uint16[LOCK_COUNT] calldata aprBps
    ) external payable nonReentrant whenNotPaused returns (address vault, uint256 vaultId) {
        if (!registry.isLaunch(stakeToken)) revert TokenNotRegistered(stakeToken);
        if (rewardAmount == 0) revert ZeroAmount();
        if (endsAt <= block.timestamp) revert EndNotInFuture(endsAt, block.timestamp);
        if (endsAt - block.timestamp > MAX_DURATION) revert DurationTooLong(endsAt, MAX_DURATION);
        _validateLocks(lockMask, aprBps);

        (uint256 feePaid, uint256 refund) = _collectFee();

        vaultId = nextVaultId++;
        vault = Clones.clone(vaultImplementation);

        vaultById[vaultId] = vault;
        vaultIdOf[vault] = vaultId;
        _vaults.push(vault);
        _vaultsByToken[stakeToken].push(vault);

        LootingStakingVault(vault)
            .initialize(address(this), vaultId, stakeToken, msg.sender, rewardAmount, endsAt, lockMask, aprBps);

        emit StakingVaultCreated(vaultId, vault, stakeToken, msg.sender, rewardAmount, feePaid, endsAt, lockMask);

        // Reward tokens go straight into the vault, never through this contract. Fee-on-transfer and
        // rebasing tokens are rejected so `rewardRemaining` can never overstate the pool (spec 17).
        uint256 before = IERC20(stakeToken).balanceOf(vault);
        IERC20(stakeToken).safeTransferFrom(msg.sender, vault, rewardAmount);
        uint256 received = IERC20(stakeToken).balanceOf(vault) - before;
        if (received != rewardAmount) revert UnexpectedTokenBalance(rewardAmount, received);

        _refundExcess(refund);
    }

    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }

    /// @notice Paginated vault list. The indexer is the primary source; this is the on-chain fallback.
    function vaults(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 total = _vaults.length;
        if (offset >= total) return new address[](0);
        uint256 remaining = total - offset;
        uint256 size = limit < remaining ? limit : remaining;

        page = new address[](size);
        for (uint256 i = 0; i < size; ++i) {
            page[i] = _vaults[offset + i];
        }
    }

    function vaultsOf(address stakeToken) external view returns (address[] memory) {
        return _vaultsByToken[stakeToken];
    }

    /// @notice Freezes new vault creation and new stakes in every vault. Claims and unlocked
    ///         unstakes stay open, so a pause can never trap principal (spec 27).
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _validateLocks(uint8 lockMask, uint16[LOCK_COUNT] calldata aprBps) private pure {
        if (lockMask == 0 || lockMask > 0x07) revert NoLockEnabled();

        for (uint8 i = 0; i < LOCK_COUNT; ++i) {
            bool enabled = lockMask & (uint8(1) << i) != 0;
            uint16 apr = aprBps[i];
            if (enabled) {
                if (apr == 0) revert AprMissingForEnabledLock(i);
                if (apr > MAX_APR_BPS) revert AprAboveCap(i, apr, MAX_APR_BPS);
            } else if (apr != 0) {
                revert AprSetForDisabledLock(i);
            }
        }
    }
}
