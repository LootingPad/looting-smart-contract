// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {LootingLaunchRegistry} from "../src/LootingLaunchRegistry.sol";
import {LootingLuckyBoxEthModule} from "../src/LootingLuckyBoxEthModule.sol";
import {LootingRewardRouter} from "../src/LootingRewardRouter.sol";

contract LootingLuckyBoxEthModuleTest is Test {
    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal pauser = makeAddr("pauser");
    address internal registrar = makeAddr("registrar");
    address internal burnWallet = makeAddr("burnWallet");
    address internal creator = makeAddr("creator");
    address internal winner = makeAddr("winner");
    address internal pons = makeAddr("pons");

    LootingLaunchRegistry internal registry;
    LootingRewardRouter internal rewardRouter;
    LootingLuckyBoxEthModule internal module;
    address internal token;

    function setUp() public {
        registry = new LootingLaunchRegistry(admin, registrar);
        rewardRouter = new LootingRewardRouter(admin, keeper, pauser, address(registry), burnWallet);
        module = new LootingLuckyBoxEthModule(admin, keeper, address(rewardRouter));

        vm.prank(admin);
        rewardRouter.setLuckyBoxModule(address(module));

        token = makeAddr("token");
        LootingLaunchRegistry.LaunchRewardConfig memory config = LootingLaunchRegistry.LaunchRewardConfig({
            token: token,
            curve: makeAddr("curve"),
            creator: creator,
            creatorFeeRouter: address(rewardRouter),
            creatorBps: 5_000,
            luckyBoxBps: 5_000,
            totalCreatorFeeBps: 10_000,
            holderShareEnabled: false,
            quoteAsset: address(0),
            launchedAt: uint64(block.timestamp),
            phase: LootingLaunchRegistry.Phase.Curve,
            rewardsEnabled: true,
            configHash: keccak256("config")
        });
        vm.prank(registrar);
        registry.register(config);

        vm.deal(pons, 10 ether);
        vm.prank(pons);
        (bool ok,) = address(rewardRouter).call{value: 1 ether}("");
        assertTrue(ok);
        rewardRouter.allocate(token, 1 ether);
        // box reward accrued = 0.4 ether
    }

    function test_keeperCreditsAndWinnerClaims() public {
        bytes32 boxId = keccak256("box-1");
        vm.prank(keeper);
        module.creditEthPrize(token, winner, 0.1 ether, boxId);

        assertEq(module.pendingEth(winner, token), 0.1 ether);

        uint256 before = winner.balance;
        vm.prank(winner);
        uint256 paid = module.claimEthPrize(token);
        assertEq(paid, 0.1 ether);
        assertEq(winner.balance, before + 0.1 ether);
        assertEq(module.pendingEth(winner, token), 0);
    }

    function test_nonKeeperCannotCredit() public {
        vm.prank(winner);
        vm.expectRevert();
        module.creditEthPrize(token, winner, 0.1 ether, bytes32(0));
    }
}
