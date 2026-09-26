// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {Base} from "./Base.t.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {LootingDevLock} from "../src/LootingDevLock.sol";
import {MockBuybackAdapter, RejectEth} from "./mocks/MockBuybackAdapter.sol";

/// @notice Fee split math, the ops pull path, the buyback guardrails and the fee timelock (spec 36).
contract FeeSplitterTest is Base {
    MockBuybackAdapter internal adapter;

    function setUp() public override {
        super.setUp();
        adapter = new MockBuybackAdapter(1_000 ether);

        vm.startPrank(admin);
        devLock.setLootingToken(address(looting));
        devLock.setBuybackRecipient(buybackRecipient);
        devLock.setMinLootingPerEth(900 ether);
        devLock.setBuybackRouter(address(adapter), true);
        vm.stopPrank();
    }

    function _createLock() internal {
        _fund(token, creator, 1_000e18, address(devLock));
        vm.prank(creator);
        devLock.createTimeLock{value: FEE}(address(token), 1_000e18, uint64(block.timestamp + 30 days));
    }

    function test_feeSplitsFiftyFifty() public {
        _createLock();

        assertEq(devLock.opsAccrued(), FEE / 2, "ops half");
        assertEq(devLock.buybackAccrued(), FEE / 2, "buyback half");
        assertEq(address(devLock).balance, FEE, "no ETH leaves at create");
    }

    function test_overpayIsRefunded() public {
        _fund(token, creator, 1_000e18, address(devLock));
        uint256 before = creator.balance;

        vm.prank(creator);
        devLock.createTimeLock{value: 1 ether}(address(token), 1_000e18, uint64(block.timestamp + 30 days));

        assertEq(creator.balance, before - FEE, "only the fee is kept");
    }

    function test_revertsWhenFeeUnderpaid() public {
        _fund(token, creator, 1_000e18, address(devLock));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.FeeTooLow.selector, FEE - 1, FEE));
        devLock.createTimeLock{value: FEE - 1}(address(token), 1_000e18, uint64(block.timestamp + 30 days));
    }

    function test_withdrawOpsIsPermissionlessAndGoesToFixedWallet() public {
        _createLock();

        vm.prank(bob);
        devLock.withdrawOps();

        assertEq(devLockOps.balance, FEE / 2, "ops wallet paid");
        assertEq(devLock.opsAccrued(), 0);
        assertEq(devLock.opsPaid(), FEE / 2);
    }

    /// @dev The audit fix: a wallet that rejects ETH must not be able to brick creates.
    function test_stuckOpsWalletDoesNotBlockCreate() public {
        address stuck = address(new RejectEth());
        vm.prank(admin);
        devLock.setOpsWallet(stuck);

        _createLock();
        assertEq(devLock.opsAccrued(), FEE / 2, "create still succeeded");

        vm.expectRevert(FeeSplitter.EthTransferFailed.selector);
        devLock.withdrawOps();
    }

    function test_buybackSendsLootingToFixedRecipient() public {
        _createLock();
        uint256 ethIn = devLock.buybackAccrued();

        vm.prank(keeper);
        uint256 out = devLock.buyback(address(adapter), ethIn, 0, block.timestamp);

        assertEq(out, (ethIn * 1_000 ether) / 1 ether, "output measured from balance");
        assertEq(looting.balanceOf(buybackRecipient), out, "recipient is fixed, not keeper-chosen");
        assertEq(devLock.buybackAccrued(), 0);
    }

    /// @dev The audit fix: the price floor bounds what a compromised keeper can give away.
    function test_buybackRevertsBelowPriceFloor() public {
        _createLock();
        adapter.setRate(800 ether);
        uint256 ethIn = devLock.buybackAccrued();
        uint256 floorOut = (ethIn * 900 ether) / 1 ether;
        uint256 actualOut = (ethIn * 800 ether) / 1 ether;

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.InsufficientOutput.selector, actualOut, floorOut));
        devLock.buyback(address(adapter), ethIn, 0, block.timestamp);
    }

    /// @dev The audit fix: output is measured, so an adapter overstating its return is caught.
    function test_buybackRevertsWhenAdapterOverstatesOutput() public {
        _createLock();
        adapter.setOverstateBy(1_000_000 ether);
        uint256 ethIn = devLock.buybackAccrued();
        uint256 minOut = (ethIn * 1_100 ether) / 1 ether;
        uint256 actualOut = (ethIn * 1_000 ether) / 1 ether;

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.InsufficientOutput.selector, actualOut, minOut));
        devLock.buyback(address(adapter), ethIn, minOut, block.timestamp);
    }

    function test_buybackRejectsUnknownAdapter() public {
        _createLock();
        address rogue = address(new MockBuybackAdapter(1_000 ether));
        uint256 accrued = devLock.buybackAccrued();

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.RouterNotAllowed.selector, rogue));
        devLock.buyback(rogue, accrued, 0, block.timestamp);
    }

    function test_buybackCannotSpendOpsHalf() public {
        _createLock();
        uint256 accrued = devLock.buybackAccrued();

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.AmountExceedsAccrued.selector, accrued + 1, accrued));
        devLock.buyback(address(adapter), accrued + 1, 0, block.timestamp);
    }

    function test_buybackIsKeeperOnly() public {
        _createLock();
        uint256 accrued = devLock.buybackAccrued();
        bytes32 keeperRole = devLock.KEEPER_ROLE();

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, keeperRole)
        );
        devLock.buyback(address(adapter), accrued, 0, block.timestamp);
    }

    /// @dev The audit fix: an increase waits out the timelock so an in-flight create keeps its quote.
    function test_feeIncreaseIsTimelocked() public {
        vm.prank(admin);
        devLock.setFee(0.01 ether);
        assertEq(devLock.fee(), FEE, "not applied yet");

        vm.expectRevert(
            abi.encodeWithSelector(
                FeeSplitter.FeeTimelockPending.selector, uint64(block.timestamp + 1 days), block.timestamp
            )
        );
        devLock.applyFee();

        vm.warp(block.timestamp + 1 days);
        devLock.applyFee();
        assertEq(devLock.fee(), 0.01 ether);
    }

    function test_feeDecreaseIsImmediate() public {
        vm.prank(admin);
        devLock.setFee(0.001 ether);
        assertEq(devLock.fee(), 0.001 ether);
    }

    function test_feeCannotExceedCap() public {
        uint256 cap = devLock.MAX_FEE();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.FeeAboveCap.selector, cap + 1, cap));
        devLock.setFee(cap + 1);
    }

    /// @dev The audit fix: force-sent ETH is recoverable and is never mistaken for fee revenue.
    function test_sweepUntrackedEthLeavesAccountedFeesAlone() public {
        _createLock();
        vm.deal(address(devLock), address(devLock).balance + 5 ether);

        vm.prank(admin);
        uint256 swept = devLock.sweepUntrackedEth();

        assertEq(swept, 5 ether, "only the untracked surplus");
        assertEq(devLock.opsAccrued() + devLock.buybackAccrued(), FEE);
        assertEq(address(devLock).balance, FEE, "accounted fees intact");
    }

    /// @dev Invariant (spec 17): ETH held always covers everything the contract still owes.
    function testFuzz_ethBalanceCoversAccruals(uint8 creates) public {
        vm.assume(creates > 0 && creates < 20);

        for (uint256 i = 0; i < creates; ++i) {
            _fund(token, creator, 1_000e18, address(devLock));
            vm.prank(creator);
            devLock.createTimeLock{value: FEE}(address(token), 1_000e18, uint64(block.timestamp + 30 days));
        }

        assertGe(address(devLock).balance, devLock.opsAccrued() + devLock.buybackAccrued());
    }
}
