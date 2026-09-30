// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {LootingLaunchRouter} from "../src/pons-adapter/LootingLaunchRouter.sol";

/// @notice Deploys the one-confirm launch router (Pons launchFee + LOOTING 0.00035 in one tx).
/// @dev Requires `LOOTING_REWARD_ROUTER` — forced as Pons creatorFeeRecipient on every launch.
contract DeployLaunchRouter is Script {
    uint256 public constant LOOTING_LAUNCH_FEE = 0.00035 ether;

    function run() external {
        address admin = vm.envAddress("ADMIN");
        address pauser = vm.envOr("PAUSER", admin);
        address ponsFactory = vm.envAddress("PONS_V2_FACTORY");
        address feeWallet = vm.envAddress("LAUNCH_FEE_WALLET");
        address rewardRouter = vm.envAddress("LOOTING_REWARD_ROUTER");

        vm.startBroadcast();
        LootingLaunchRouter router =
            new LootingLaunchRouter(admin, pauser, ponsFactory, feeWallet, rewardRouter, LOOTING_LAUNCH_FEE);
        vm.stopBroadcast();

        console2.log("LootingLaunchRouter", address(router));
        console2.log("ponsFactory        ", ponsFactory);
        console2.log("feeWallet          ", feeWallet);
        console2.log("rewardRouter       ", rewardRouter);
        console2.log("lootingFeeWei      ", LOOTING_LAUNCH_FEE);
    }
}
