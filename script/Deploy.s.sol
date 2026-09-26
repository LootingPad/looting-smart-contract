// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {LootingDevLock} from "../src/LootingDevLock.sol";
import {LootingLaunchRegistry} from "../src/LootingLaunchRegistry.sol";
import {LootingStakingFactory} from "../src/LootingStakingFactory.sol";
import {LootingStakingVault} from "../src/LootingStakingVault.sol";

/// @notice Deploys the four LOOTING contracts in the §61.2 order and writes
///         `deployments/<chainId>.json` for the backend and the frontend to read.
/// @dev Post-deploy wiring that needs addresses which do not exist yet (LOOTING token, buyback
///      adapter, price floor) is left to the admin multisig; see README.
contract Deploy is Script {
    /// @notice Flat ETH fee per Dev Lock and per staking vault create, split 50/50 ops/buyback.
    uint256 public constant FEE = 0.003 ether;

    function run() external {
        address admin = vm.envAddress("ADMIN");
        address keeper = vm.envAddress("KEEPER");
        address devLockOps = vm.envAddress("DEVLOCK_OPS_WALLET");
        address stakingOps = vm.envAddress("STAKING_OPS_WALLET");

        vm.startBroadcast();

        LootingLaunchRegistry registry = new LootingLaunchRegistry(admin, keeper);
        LootingDevLock devLock = new LootingDevLock(admin, keeper, devLockOps, FEE, registry);
        LootingStakingVault vaultImpl = new LootingStakingVault();
        LootingStakingFactory factory =
            new LootingStakingFactory(admin, keeper, stakingOps, FEE, registry, address(vaultImpl));

        vm.stopBroadcast();

        _write(registry, devLock, vaultImpl, factory, admin, keeper, devLockOps, stakingOps);
    }

    function _write(
        LootingLaunchRegistry registry,
        LootingDevLock devLock,
        LootingStakingVault vaultImpl,
        LootingStakingFactory factory,
        address admin,
        address keeper,
        address devLockOps,
        address stakingOps
    ) private {
        string memory json = "deployment";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeUint(json, "deployBlock", block.number);
        vm.serializeUint(json, "feeWei", FEE);
        vm.serializeAddress(json, "admin", admin);
        vm.serializeAddress(json, "keeper", keeper);
        vm.serializeAddress(json, "devLockOpsWallet", devLockOps);
        vm.serializeAddress(json, "stakingOpsWallet", stakingOps);
        vm.serializeAddress(json, "launchRegistry", address(registry));
        vm.serializeAddress(json, "devLock", address(devLock));
        vm.serializeAddress(json, "stakingVaultImplementation", address(vaultImpl));
        string memory out = vm.serializeAddress(json, "stakingFactory", address(factory));

        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(out, path);

        console2.log("LootingLaunchRegistry", address(registry));
        console2.log("LootingDevLock       ", address(devLock));
        console2.log("StakingVault impl    ", address(vaultImpl));
        console2.log("LootingStakingFactory", address(factory));
        console2.log("written to           ", path);
    }
}
