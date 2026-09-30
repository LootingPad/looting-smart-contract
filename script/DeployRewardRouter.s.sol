// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {LootingLaunchRegistry} from "../src/LootingLaunchRegistry.sol";
import {LootingLuckyBoxEthModule} from "../src/LootingLuckyBoxEthModule.sol";
import {LootingRewardRouter} from "../src/LootingRewardRouter.sol";

/// @notice Deploys LootingRewardRouter + interim ETH lucky-box module against an existing registry.
contract DeployRewardRouter is Script {
    function run() external {
        address admin = vm.envAddress("ADMIN");
        address keeper = vm.envOr("KEEPER", admin);
        address pauser = vm.envOr("PAUSER", admin);
        address registry = vm.envAddress("LAUNCH_REGISTRY");
        address burnWallet = vm.envAddress("BURN_WALLET");
        address ponsFeeEscrow = vm.envOr("PONS_FEE_ESCROW", address(0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e));

        vm.startBroadcast();
        LootingRewardRouter router = new LootingRewardRouter(admin, keeper, pauser, registry, burnWallet);
        LootingLuckyBoxEthModule boxModule = new LootingLuckyBoxEthModule(admin, keeper, address(router));
        router.setLuckyBoxModule(address(boxModule));
        router.setPonsFeeEscrow(ponsFeeEscrow);
        vm.stopBroadcast();

        console2.log("LootingRewardRouter      ", address(router));
        console2.log("LootingLuckyBoxEthModule ", address(boxModule));
        console2.log("ponsFeeEscrow            ", ponsFeeEscrow);
        console2.log("registry                 ", registry);
        console2.log("burnWallet               ", burnWallet);
    }
}
