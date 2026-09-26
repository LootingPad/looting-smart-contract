// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {LootingLaunchRegistry} from "../src/LootingLaunchRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Registration gates and the reward split invariant (spec 6, 17).
contract LootingLaunchRegistryTest is Base {
    function _config(address token_, uint16 creatorBps, uint16 luckyBoxBps, uint16 totalBps)
        internal
        returns (LootingLaunchRegistry.LaunchRewardConfig memory)
    {
        return LootingLaunchRegistry.LaunchRewardConfig({
            token: token_,
            curve: makeAddr("curve"),
            creator: creator,
            creatorFeeRouter: makeAddr("router"),
            creatorBps: creatorBps,
            luckyBoxBps: luckyBoxBps,
            totalCreatorFeeBps: totalBps,
            holderShareEnabled: true,
            quoteAsset: address(0),
            launchedAt: uint64(block.timestamp),
            phase: LootingLaunchRegistry.Phase.Curve,
            rewardsEnabled: true,
            configHash: keccak256("config")
        });
    }

    function test_registerStoresConfig() public view {
        LootingLaunchRegistry.LaunchRewardConfig memory config = registry.configOf(address(token));

        assertTrue(registry.isLaunch(address(token)));
        assertEq(registry.creatorOf(address(token)), creator);
        assertEq(config.creatorBps, 5_000);
        assertEq(config.luckyBoxBps, 5_000);
        assertEq(registry.launchCount(), 1);
    }

    function test_registerIsRegistrarOnly() public {
        MockERC20 other = new MockERC20("Other", "OTH");

        vm.prank(bob);
        vm.expectRevert();
        registry.register(_config(address(other), 5_000, 5_000, 10_000));
    }

    function test_registerRejectsDuplicates() public {
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(LootingLaunchRegistry.AlreadyRegistered.selector, address(token)));
        registry.register(_config(address(token), 5_000, 5_000, 10_000));
    }

    function test_registerEnforcesSplitSumsToTotal() public {
        MockERC20 other = new MockERC20("Other", "OTH");

        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(LootingLaunchRegistry.FeeSplitMismatch.selector, 4_000, 5_000, 10_000));
        registry.register(_config(address(other), 4_000, 5_000, 10_000));
    }

    /// @dev The audit fix: a split adding up to more than 100% must not be registrable.
    function test_registerRejectsTotalAboveOneHundredPercent() public {
        MockERC20 other = new MockERC20("Other", "OTH");

        vm.prank(registrar);
        vm.expectRevert(
            abi.encodeWithSelector(LootingLaunchRegistry.FeeBpsAboveOneHundredPercent.selector, uint16(12_000))
        );
        registry.register(_config(address(other), 6_000, 6_000, 12_000));
    }

    function test_setPhaseUpdatesConfig() public {
        vm.prank(registrar);
        registry.setPhase(address(token), LootingLaunchRegistry.Phase.Graduated);

        assertEq(uint8(registry.configOf(address(token)).phase), uint8(LootingLaunchRegistry.Phase.Graduated));
    }

    function test_pauseAndResumeRewardProgram() public {
        vm.prank(admin);
        registry.pauseRewardProgram(address(token), "pons-fee-recipient-changed");
        assertFalse(registry.configOf(address(token)).rewardsEnabled);

        vm.prank(admin);
        registry.resumeRewardProgram(address(token));
        assertTrue(registry.configOf(address(token)).rewardsEnabled);
    }

    function test_unregisteredReadsRevert() public {
        address stranger = makeAddr("stranger");

        assertFalse(registry.isLaunch(stranger));
        vm.expectRevert(abi.encodeWithSelector(LootingLaunchRegistry.NotRegistered.selector, stranger));
        registry.creatorOf(stranger);
    }

    /// @dev The audit fix: pagination must not overflow or read out of bounds.
    function test_launchesPaginationIsSafe() public {
        for (uint256 i = 0; i < 5; ++i) {
            MockERC20 extra = new MockERC20("Extra", "EXT");
            _registerLaunch(address(extra), creator);
        }

        assertEq(registry.launches(0, 3).length, 3);
        assertEq(registry.launches(4, 100).length, 2, "limit is clamped to what remains");
        assertEq(registry.launches(6, 10).length, 0, "offset past the end returns empty");
        assertEq(registry.launches(0, type(uint256).max).length, 6, "no overflow on a huge limit");
    }
}
