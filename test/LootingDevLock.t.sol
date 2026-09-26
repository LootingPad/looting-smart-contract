// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Base} from "./Base.t.sol";
import {LootingDevLock} from "../src/LootingDevLock.sol";
import {MockERC20, MockFeeOnTransferERC20} from "./mocks/MockERC20.sol";

/// @notice Dev Lock gates, vesting math and the claim path (spec 36, 54).
contract LootingDevLockTest is Base {
    uint256 internal constant AMOUNT = 1_000e18;

    function _timeLock(uint64 unlockAt) internal returns (uint256 lockId) {
        _fund(token, creator, AMOUNT, address(devLock));
        vm.prank(creator);
        return devLock.createTimeLock{value: FEE}(address(token), AMOUNT, unlockAt);
    }

    function _vesting(uint64 cliffAt, uint64 unlockAt) internal returns (uint256 lockId) {
        _fund(token, creator, AMOUNT, address(devLock));
        vm.prank(creator);
        return
            devLock.createVesting{value: FEE}(
                address(token), AMOUNT, cliffAt, unlockAt, LootingDevLock.DevLockCadence.Day
            );
    }

    function test_onlyRegisteredTokenCanBeLocked() public {
        MockERC20 stranger = new MockERC20("Stranger", "STR");
        _fund(stranger, creator, AMOUNT, address(devLock));

        vm.prank(creator);
        vm.expectRevert();
        devLock.createTimeLock{value: FEE}(address(stranger), AMOUNT, uint64(block.timestamp + 30 days));
    }

    function test_onlyLaunchCreatorCanLock() public {
        _fund(token, bob, AMOUNT, address(devLock));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LootingDevLock.NotLaunchCreator.selector, address(token), bob, creator));
        devLock.createTimeLock{value: FEE}(address(token), AMOUNT, uint64(block.timestamp + 30 days));
    }

    function test_timeLockPullsTokensAndStoresSchedule() public {
        uint64 unlockAt = uint64(block.timestamp + 30 days);
        uint256 lockId = _timeLock(unlockAt);

        LootingDevLock.DevLockPosition memory lock = devLock.lockOf(lockId);
        assertEq(lock.owner, creator);
        assertEq(lock.amount, AMOUNT);
        assertEq(lock.claimed, 0);
        assertEq(lock.unlock, unlockAt);
        assertEq(token.balanceOf(address(devLock)), AMOUNT);
    }

    function test_timeLockClaimsNothingBeforeUnlock() public {
        uint64 unlockAt = uint64(block.timestamp + 30 days);
        uint256 lockId = _timeLock(unlockAt);

        vm.warp(unlockAt - 1);
        assertEq(devLock.claimableAmount(lockId), 0, "time lock is all-or-nothing");

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LootingDevLock.NothingToClaim.selector, lockId));
        devLock.claim(lockId);
    }

    function test_timeLockClaimsEverythingAtUnlock() public {
        uint64 unlockAt = uint64(block.timestamp + 30 days);
        uint256 lockId = _timeLock(unlockAt);

        vm.warp(unlockAt);
        vm.prank(creator);
        uint256 paid = devLock.claim(lockId);

        assertEq(paid, AMOUNT);
        assertEq(token.balanceOf(creator), AMOUNT);
        assertEq(token.balanceOf(address(devLock)), 0);
    }

    function test_vestingReleasesNothingBeforeCliff() public {
        uint64 cliffAt = uint64(block.timestamp + 30 days);
        uint64 unlockAt = uint64(block.timestamp + 365 days);
        uint256 lockId = _vesting(cliffAt, unlockAt);

        vm.warp(cliffAt);
        assertEq(devLock.vestedAmount(lockId), 0, "cliff is exclusive");
    }

    function test_vestingIsLinearBetweenCliffAndUnlock() public {
        uint64 cliffAt = uint64(block.timestamp + 30 days);
        uint64 unlockAt = cliffAt + 300 days;
        uint256 lockId = _vesting(cliffAt, unlockAt);

        vm.warp(cliffAt + 150 days);
        assertEq(devLock.vestedAmount(lockId), AMOUNT / 2, "half way through the ramp");

        vm.warp(unlockAt);
        assertEq(devLock.vestedAmount(lockId), AMOUNT, "fully vested at unlock");
    }

    function test_vestingPartialClaimThenRemainder() public {
        uint64 cliffAt = uint64(block.timestamp + 30 days);
        uint64 unlockAt = cliffAt + 300 days;
        uint256 lockId = _vesting(cliffAt, unlockAt);

        vm.warp(cliffAt + 150 days);
        vm.prank(creator);
        uint256 first = devLock.claim(lockId);
        assertEq(first, AMOUNT / 2);

        vm.warp(unlockAt);
        vm.prank(creator);
        uint256 second = devLock.claim(lockId);

        assertEq(first + second, AMOUNT, "never more, never less than the locked amount");
        assertEq(token.balanceOf(creator), AMOUNT);
    }

    function test_claimIsOwnerOnly() public {
        uint64 unlockAt = uint64(block.timestamp + 30 days);
        uint256 lockId = _timeLock(unlockAt);
        vm.warp(unlockAt);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LootingDevLock.NotLockOwner.selector, lockId, bob));
        devLock.claim(lockId);
    }

    function test_fullyClaimedLockLeavesTheOwnerList() public {
        uint64 unlockAt = uint64(block.timestamp + 30 days);
        uint256 lockId = _timeLock(unlockAt);
        uint256 second = _timeLock(unlockAt + 1);
        uint256 third = _timeLock(unlockAt + 2);

        vm.warp(unlockAt);
        vm.prank(creator);
        devLock.claim(lockId);

        uint256[] memory ids = devLock.locksOf(creator);
        assertEq(ids.length, 2);
        assertEq(ids[0], third, "swap-and-pop moved the last entry into the gap");
        assertEq(ids[1], second);
    }

    /// @dev The audit fix: removal is O(1) via the index map, and stays correct across many locks.
    function test_ownerListStaysConsistentAcrossManyRemovals() public {
        uint64 unlockAt = uint64(block.timestamp + 30 days);
        uint256[] memory created = new uint256[](5);
        for (uint256 i = 0; i < 5; ++i) {
            created[i] = _timeLock(unlockAt + uint64(i));
        }

        vm.warp(unlockAt + 5);
        vm.startPrank(creator);
        devLock.claim(created[0]);
        devLock.claim(created[4]);
        devLock.claim(created[2]);
        vm.stopPrank();

        uint256[] memory ids = devLock.locksOf(creator);
        assertEq(ids.length, 2);
        for (uint256 i = 0; i < ids.length; ++i) {
            assertTrue(ids[i] == created[1] || ids[i] == created[3], "only unclaimed locks remain");
        }
    }

    function test_rejectsFeeOnTransferToken() public {
        MockFeeOnTransferERC20 fot = new MockFeeOnTransferERC20();
        _registerLaunch(address(fot), creator);
        fot.mint(creator, AMOUNT);
        vm.prank(creator);
        fot.approve(address(devLock), AMOUNT);

        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(LootingDevLock.UnexpectedTokenBalance.selector, AMOUNT, AMOUNT - AMOUNT / 100)
        );
        devLock.createTimeLock{value: FEE}(address(fot), AMOUNT, uint64(block.timestamp + 30 days));
    }

    function test_unlockMustBeInTheFuture() public {
        _fund(token, creator, AMOUNT, address(devLock));
        uint64 past = uint64(block.timestamp);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LootingDevLock.UnlockNotInFuture.selector, past, block.timestamp));
        devLock.createTimeLock{value: FEE}(address(token), AMOUNT, past);
    }

    function test_vestingUnlockMustFollowCliff() public {
        _fund(token, creator, AMOUNT, address(devLock));
        uint64 cliffAt = uint64(block.timestamp + 30 days);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LootingDevLock.UnlockBeforeCliff.selector, cliffAt, cliffAt));
        devLock.createVesting{value: FEE}(address(token), AMOUNT, cliffAt, cliffAt, LootingDevLock.DevLockCadence.Day);
    }

    function test_pauseBlocksCreatesButNotClaims() public {
        uint64 unlockAt = uint64(block.timestamp + 30 days);
        uint256 lockId = _timeLock(unlockAt);

        vm.prank(admin);
        devLock.pause();

        _fund(token, creator, AMOUNT, address(devLock));
        vm.prank(creator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        devLock.createTimeLock{value: FEE}(address(token), AMOUNT, unlockAt);

        vm.warp(unlockAt);
        vm.prank(creator);
        assertEq(devLock.claim(lockId), AMOUNT, "a pause never traps locked tokens");
    }

    /// @dev Invariant (spec 17): claims can never exceed the amount that was locked.
    function testFuzz_claimNeverExceedsLockedAmount(uint256 amount, uint32 cliffOffset, uint32 rampLength, uint32 jump)
        public
    {
        amount = bound(amount, 1e6, 1e30);
        uint64 cliffAt = uint64(block.timestamp + bound(cliffOffset, 0, 365 days));
        uint64 unlockAt = cliffAt + uint64(bound(rampLength, 1, 730 days));

        _fund(token, creator, amount, address(devLock));
        vm.prank(creator);
        uint256 lockId = devLock.createVesting{value: FEE}(
            address(token), amount, cliffAt, unlockAt, LootingDevLock.DevLockCadence.Day
        );

        vm.warp(block.timestamp + bound(jump, 1, 2_000 days));
        assertLe(devLock.vestedAmount(lockId), amount);

        uint256 claimable = devLock.claimableAmount(lockId);
        if (claimable > 0) {
            vm.prank(creator);
            devLock.claim(lockId);
            assertLe(token.balanceOf(creator), amount);
        }
    }
}
