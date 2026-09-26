// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Base} from "./Base.t.sol";
import {LootingStakingFactory} from "../src/LootingStakingFactory.sol";
import {LootingStakingVault} from "../src/LootingStakingVault.sol";
import {MockERC20, MockFeeOnTransferERC20} from "./mocks/MockERC20.sol";

/// @notice Factory gates, clone isolation, lock enforcement and reward accounting (spec 36, 55, 55a).
contract LootingStakingTest is Base {
    uint256 internal constant REWARD = 100_000e18;
    uint8 internal constant FLEX = 0;
    uint8 internal constant LOCK_30 = 1;
    uint8 internal constant LOCK_90 = 2;

    uint64 internal endsAt;

    function setUp() public override {
        super.setUp();
        endsAt = uint64(block.timestamp + 180 days);
    }

    function _createVault() internal returns (LootingStakingVault vault) {
        return _createVault(REWARD, endsAt, 0x07, _aprs(800, 1_400, 2_200));
    }

    function _createVault(uint256 reward, uint64 end, uint8 lockMask, uint16[3] memory aprBps)
        internal
        returns (LootingStakingVault vault)
    {
        _fund(token, creator, reward, address(factory));
        vm.prank(creator);
        (address addr,) = factory.createVault{value: FEE}(address(token), reward, end, lockMask, aprBps);
        return LootingStakingVault(addr);
    }

    function _stake(LootingStakingVault vault, address who, uint256 amount, uint8 lockId) internal {
        _fund(token, who, amount, address(vault));
        vm.prank(who);
        vault.stake(amount, lockId);
    }

    function test_createVaultFundsCloneAndRegistersId() public {
        LootingStakingVault vault = _createVault();

        assertEq(factory.vaultIdOf(address(vault)), 1);
        assertEq(factory.vaultById(1), address(vault));
        assertEq(factory.vaultCount(), 1);
        assertEq(vault.rewardRemaining(), REWARD, "reward went into the vault");
        assertEq(token.balanceOf(address(vault)), REWARD);
        assertEq(token.balanceOf(address(factory)), 0, "factory never custodies reward tokens");
        assertEq(vault.creator(), creator);
    }

    function test_createFeeIsNotPartOfTheRewardPool() public {
        LootingStakingVault vault = _createVault();

        assertEq(factory.opsAccrued() + factory.buybackAccrued(), FEE);
        assertEq(vault.rewardFunded(), REWARD, "pool is exactly what the creator funded");
    }

    function test_createRejectsUnregisteredToken() public {
        MockERC20 stranger = new MockERC20("Stranger", "STR");
        _fund(stranger, creator, REWARD, address(factory));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LootingStakingFactory.TokenNotRegistered.selector, address(stranger)));
        factory.createVault{value: FEE}(address(stranger), REWARD, endsAt, 0x07, _aprs(800, 1_400, 2_200));
    }

    function test_createRejectsPastEnd() public {
        _fund(token, creator, REWARD, address(factory));
        uint64 past = uint64(block.timestamp);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LootingStakingFactory.EndNotInFuture.selector, past, block.timestamp));
        factory.createVault{value: FEE}(address(token), REWARD, past, 0x07, _aprs(800, 1_400, 2_200));
    }

    function test_createRequiresAtLeastOneLock() public {
        _fund(token, creator, REWARD, address(factory));

        vm.prank(creator);
        vm.expectRevert(LootingStakingFactory.NoLockEnabled.selector);
        factory.createVault{value: FEE}(address(token), REWARD, endsAt, 0, _aprs(0, 0, 0));
    }

    function test_createRejectsAprOnDisabledLock() public {
        _fund(token, creator, REWARD, address(factory));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LootingStakingFactory.AprSetForDisabledLock.selector, LOCK_90));
        factory.createVault{value: FEE}(address(token), REWARD, endsAt, 0x03, _aprs(800, 1_400, 2_200));
    }

    function test_createRejectsMissingAprOnEnabledLock() public {
        _fund(token, creator, REWARD, address(factory));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LootingStakingFactory.AprMissingForEnabledLock.selector, LOCK_30));
        factory.createVault{value: FEE}(address(token), REWARD, endsAt, 0x03, _aprs(800, 0, 0));
    }

    function test_createRejectsFeeOnTransferToken() public {
        MockFeeOnTransferERC20 fot = new MockFeeOnTransferERC20();
        _registerLaunch(address(fot), creator);
        fot.mint(creator, REWARD);
        vm.prank(creator);
        fot.approve(address(factory), REWARD);

        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(LootingStakingFactory.UnexpectedTokenBalance.selector, REWARD, REWARD - REWARD / 100)
        );
        factory.createVault{value: FEE}(address(fot), REWARD, endsAt, 0x07, _aprs(800, 1_400, 2_200));
    }

    /// @dev The implementation must never be initializable, or its storage could be hijacked.
    function test_vaultImplementationCannotBeInitialized() public {
        vm.expectRevert(LootingStakingVault.AlreadyInitialized.selector);
        vaultImpl.initialize(address(factory), 1, address(token), creator, REWARD, endsAt, 0x07, _aprs(1, 1, 1));
    }

    function test_cloneCannotBeReinitialized() public {
        LootingStakingVault vault = _createVault();

        vm.expectRevert(LootingStakingVault.AlreadyInitialized.selector);
        vault.initialize(address(factory), 99, address(token), bob, REWARD, endsAt, 0x07, _aprs(1, 1, 1));
    }

    /// @dev The reason for one clone per event: no vault can reach another vault's funds.
    function test_vaultsAreIsolated() public {
        LootingStakingVault first = _createVault();
        LootingStakingVault second = _createVault();

        _stake(first, alice, 1_000e18, FLEX);

        assertEq(second.totalStaked(), 0, "stakes do not leak between events");
        assertEq(first.vaultId(), 1);
        assertEq(second.vaultId(), 2);
        assertTrue(address(first) != address(second));
    }

    function test_flexibleStakeUnstakesImmediately() public {
        LootingStakingVault vault = _createVault();
        _stake(vault, alice, 1_000e18, FLEX);

        vm.prank(alice);
        vault.unstake(1_000e18, FLEX);

        assertEq(token.balanceOf(alice), 1_000e18, "principal back in full");
        assertEq(vault.totalStaked(), 0);
    }

    function test_thirtyDayLockBlocksEarlyUnstake() public {
        LootingStakingVault vault = _createVault();
        _stake(vault, alice, 1_000e18, LOCK_30);
        uint64 lockEnd = uint64(block.timestamp + 30 days);

        vm.warp(lockEnd - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LootingStakingVault.StillLocked.selector, lockEnd, block.timestamp));
        vault.unstake(1_000e18, LOCK_30);

        vm.warp(lockEnd);
        vm.prank(alice);
        vault.unstake(1_000e18, LOCK_30);
        assertEq(token.balanceOf(alice), 1_000e18);
    }

    function test_ninetyDayLockUsesNinetyDays() public {
        LootingStakingVault vault = _createVault();
        _stake(vault, alice, 1_000e18, LOCK_90);

        vm.warp(block.timestamp + 90 days - 1);
        vm.prank(alice);
        vm.expectRevert();
        vault.unstake(1_000e18, LOCK_90);

        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        vault.unstake(1_000e18, LOCK_90);
    }

    /// @dev Topping up re-locks the position, so a late dust stake cannot shorten the window.
    function test_topUpExtendsTheLock() public {
        LootingStakingVault vault = _createVault();
        _stake(vault, alice, 1_000e18, LOCK_30);

        vm.warp(block.timestamp + 29 days);
        _stake(vault, alice, 1e18, LOCK_30);

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vm.expectRevert();
        vault.unstake(1_001e18, LOCK_30);
    }

    function test_stakeRejectsDisabledLock() public {
        LootingStakingVault vault = _createVault(REWARD, endsAt, 0x01, _aprs(800, 0, 0));
        _fund(token, alice, 1_000e18, address(vault));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LootingStakingVault.LockDisabled.selector, LOCK_30));
        vault.stake(1_000e18, LOCK_30);
    }

    function test_rewardsAccrueAtTheSnapshottedApr() public {
        LootingStakingVault vault = _createVault();
        _stake(vault, alice, 1_000e18, FLEX);

        vm.warp(endsAt);
        // 8% APR over the full 180-day event.
        uint256 staked = 1_000e18;
        uint256 expected = (staked * 800 * uint256(180 days)) / (uint256(10_000) * 365 days);
        assertApproxEqAbs(vault.pendingRewards(alice, FLEX), expected, 1e12);
    }

    function test_accrualStopsAtEventEnd() public {
        LootingStakingVault vault = _createVault();
        _stake(vault, alice, 1_000e18, FLEX);

        vm.warp(endsAt);
        uint256 atEnd = vault.pendingRewards(alice, FLEX);

        vm.warp(endsAt + 365 days);
        assertEq(vault.pendingRewards(alice, FLEX), atEnd, "an abandoned vault stops accruing");
    }

    function test_claimPaysAndDecreasesRewardRemaining() public {
        LootingStakingVault vault = _createVault();
        _stake(vault, alice, 1_000e18, FLEX);

        vm.warp(block.timestamp + 90 days);
        uint256 expected = vault.pendingRewards(alice, FLEX);

        vm.prank(alice);
        uint256 paid = vault.claimRewards(FLEX);

        assertEq(paid, expected);
        assertEq(token.balanceOf(alice), paid);
        assertEq(vault.rewardRemaining(), REWARD - paid);
        assertEq(vault.pendingRewards(alice, FLEX), 0, "accrual was consumed");
    }

    /// @dev Invariant (spec 17): payouts can never exceed the funded pool.
    function test_rewardPayoutIsCappedByTheFundedPool() public {
        uint256 tinyReward = 1e18;
        LootingStakingVault vault = _createVault(tinyReward, endsAt, 0x01, _aprs(10_000, 0, 0));
        _stake(vault, alice, 1_000_000e18, FLEX);

        vm.warp(endsAt);
        assertEq(vault.pendingRewards(alice, FLEX), tinyReward, "pending is clamped to the pool");

        vm.prank(alice);
        uint256 paid = vault.claimRewards(FLEX);

        assertEq(paid, tinyReward);
        assertEq(vault.rewardRemaining(), 0);

        vm.prank(alice);
        assertEq(vault.claimRewards(FLEX), 0, "an empty pool pays nothing and does not revert");
    }

    /// @dev An empty reward pool must never block principal withdrawal.
    function test_principalIsWithdrawableWithAnEmptyRewardPool() public {
        LootingStakingVault vault = _createVault(1e18, endsAt, 0x01, _aprs(10_000, 0, 0));
        _stake(vault, alice, 1_000_000e18, FLEX);

        vm.warp(endsAt);
        vm.prank(alice);
        vault.claimRewards(FLEX);

        vm.prank(alice);
        vault.unstake(1_000_000e18, FLEX);
        assertEq(token.balanceOf(alice), 1_000_000e18 + 1e18);
    }

    function test_stakeRevertsAfterEventEnd() public {
        LootingStakingVault vault = _createVault();
        vm.warp(endsAt);
        _fund(token, alice, 1_000e18, address(vault));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LootingStakingVault.EventEnded.selector, endsAt, block.timestamp));
        vault.stake(1_000e18, FLEX);
    }

    function test_unstakeCannotExceedTheStake() public {
        LootingStakingVault vault = _createVault();
        _stake(vault, alice, 1_000e18, FLEX);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LootingStakingVault.InsufficientStake.selector, 1_001e18, 1_000e18));
        vault.unstake(1_001e18, FLEX);
    }

    function test_positionsAreTrackedPerLock() public {
        LootingStakingVault vault = _createVault();
        _stake(vault, alice, 1_000e18, FLEX);
        _stake(vault, alice, 2_000e18, LOCK_90);

        (uint256 flexStaked,,) = vault.position(alice, FLEX);
        (uint256 lockedStaked,, uint64 lockEndsAt) = vault.position(alice, LOCK_90);

        assertEq(flexStaked, 1_000e18);
        assertEq(lockedStaked, 2_000e18);
        assertEq(lockEndsAt, uint64(block.timestamp + 90 days));
        assertEq(vault.stakedOf(alice), 3_000e18);
        assertEq(vault.stakerCount(), 1, "one wallet, two locks");
    }

    function test_stakerCountTracksDistinctWallets() public {
        LootingStakingVault vault = _createVault();
        _stake(vault, alice, 1_000e18, FLEX);
        _stake(vault, bob, 1_000e18, FLEX);
        assertEq(vault.stakerCount(), 2);

        vm.prank(bob);
        vault.unstake(1_000e18, FLEX);
        assertEq(vault.stakerCount(), 1);
    }

    function test_factoryPauseFreezesStakesButNotExits() public {
        LootingStakingVault vault = _createVault();
        _stake(vault, alice, 1_000e18, FLEX);

        vm.prank(admin);
        factory.pause();

        _fund(token, bob, 1_000e18, address(vault));
        vm.prank(bob);
        vm.expectRevert(LootingStakingVault.VaultPaused.selector);
        vault.stake(1_000e18, FLEX);

        vm.prank(creator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        factory.createVault{value: FEE}(address(token), REWARD, endsAt, 0x07, _aprs(800, 1_400, 2_200));

        vm.warp(block.timestamp + 10 days);
        vm.prank(alice);
        vault.claimRewards(FLEX);
        vm.prank(alice);
        vault.unstake(1_000e18, FLEX);
        assertGe(token.balanceOf(alice), 1_000e18, "a pause never traps principal");
    }

    function test_pauseIsAdminOnly() public {
        vm.prank(bob);
        vm.expectRevert();
        factory.pause();
    }

    /// @dev Invariant (spec 17): the vault always holds enough to cover principal plus the pool.
    function testFuzz_vaultBalanceCoversPrincipalAndRewards(uint256 aliceAmount, uint256 bobAmount, uint32 elapsed)
        public
    {
        aliceAmount = bound(aliceAmount, 1e6, 1e27);
        bobAmount = bound(bobAmount, 1e6, 1e27);

        LootingStakingVault vault = _createVault();
        _stake(vault, alice, aliceAmount, FLEX);
        _stake(vault, bob, bobAmount, LOCK_30);

        vm.warp(block.timestamp + bound(elapsed, 1, 400 days));

        vm.prank(alice);
        vault.claimRewards(FLEX);
        vm.prank(bob);
        vault.claimRewards(LOCK_30);

        assertGe(token.balanceOf(address(vault)), vault.totalStaked() + vault.rewardRemaining());
    }
}
