// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {LootingDevLock} from "../src/LootingDevLock.sol";
import {LootingLaunchRegistry} from "../src/LootingLaunchRegistry.sol";
import {LootingStakingFactory} from "../src/LootingStakingFactory.sol";
import {LootingStakingVault} from "../src/LootingStakingVault.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Shared deployment for every suite, mirroring the §61.2 deploy order.
abstract contract Base is Test {
    uint256 internal constant FEE = 0.003 ether;

    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal registrar = makeAddr("registrar");
    address internal devLockOps = makeAddr("devLockOps");
    address internal stakingOps = makeAddr("stakingOps");
    address internal buybackRecipient = makeAddr("buybackRecipient");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    LootingLaunchRegistry internal registry;
    LootingDevLock internal devLock;
    LootingStakingFactory internal factory;
    LootingStakingVault internal vaultImpl;

    MockERC20 internal token;
    MockERC20 internal looting;

    function setUp() public virtual {
        registry = new LootingLaunchRegistry(admin, registrar);
        devLock = new LootingDevLock(admin, keeper, devLockOps, FEE, registry);
        vaultImpl = new LootingStakingVault();
        factory = new LootingStakingFactory(admin, keeper, stakingOps, FEE, registry, address(vaultImpl));

        token = new MockERC20("Launch Coin", "LC");
        looting = new MockERC20("LOOTING", "LOOT");

        _registerLaunch(address(token), creator);

        vm.deal(creator, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _registerLaunch(address token_, address creator_) internal {
        LootingLaunchRegistry.LaunchRewardConfig memory config = LootingLaunchRegistry.LaunchRewardConfig({
            token: token_,
            curve: makeAddr("curve"),
            creator: creator_,
            creatorFeeRouter: makeAddr("router"),
            creatorBps: 5_000,
            luckyBoxBps: 5_000,
            totalCreatorFeeBps: 10_000,
            holderShareEnabled: true,
            quoteAsset: address(0),
            launchedAt: uint64(block.timestamp),
            phase: LootingLaunchRegistry.Phase.Curve,
            rewardsEnabled: true,
            configHash: keccak256("config")
        });

        vm.prank(registrar);
        registry.register(config);
    }

    function _fund(MockERC20 token_, address to, uint256 amount, address spender) internal {
        token_.mint(to, amount);
        vm.prank(to);
        token_.approve(spender, amount);
    }

    function _aprs(uint16 flex, uint16 thirty, uint16 ninety) internal pure returns (uint16[3] memory aprBps) {
        aprBps[0] = flex;
        aprBps[1] = thirty;
        aprBps[2] = ninety;
    }
}
