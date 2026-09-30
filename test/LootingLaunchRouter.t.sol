// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";

import {IPonsV2Factory, LootingLaunchRouter} from "../src/pons-adapter/LootingLaunchRouter.sol";
import {MockPonsV2Factory} from "./mocks/MockPonsV2Factory.sol";

contract LootingLaunchRouterTest is Test {
    uint256 internal constant LOOTING_FEE = 0.00035 ether;
    uint256 internal constant PONS_FEE = 0.0005 ether;

    address internal admin = makeAddr("admin");
    address internal pauser = makeAddr("pauser");
    address internal feeWallet = makeAddr("feeWallet");
    address internal rewardRouter = makeAddr("rewardRouter");
    address internal creator = makeAddr("creator");

    MockPonsV2Factory internal pons;
    LootingLaunchRouter internal router;

    function setUp() public {
        pons = new MockPonsV2Factory();
        router = new LootingLaunchRouter(admin, pauser, address(pons), feeWallet, rewardRouter, LOOTING_FEE);
        vm.deal(creator, 10 ether);
    }

    function _params() internal pure returns (IPonsV2Factory.TokenParams memory p) {
        p.name = "Tesla";
        p.symbol = "TESLA";
        p.logo = "ipfs://x";
        p.description = "desc";
        p.creatorFeeRecipient = address(0);
        p.creatorTaxBps = 100;
        p.buybackEnabled = true; // overwritten to false by router
        p.expectedEconomics = bytes32(uint256(1));
        p.salt = bytes32(uint256(2));
    }

    function test_oneTxPaysLootingFeeAndLaunches() public {
        uint256 feeBefore = feeWallet.balance;
        uint256 creatorBefore = creator.balance;

        vm.prank(creator);
        (address token, address curve) = router.launch{value: PONS_FEE + LOOTING_FEE}(_params(), 0, address(0));

        assertTrue(token != address(0));
        assertTrue(curve != address(0));
        assertEq(feeWallet.balance, feeBefore + LOOTING_FEE);
        assertEq(creator.balance, creatorBefore - PONS_FEE - LOOTING_FEE);
        assertEq(pons.lastDeployer(), address(router), "Pons deployer is the router");
        assertEq(pons.lastCreatorFeeRecipient(), rewardRouter, "tax recipient is RewardRouter");
        assertEq(pons.lastBuybackEnabled(), false, "buyback forced off for sweep path");
        assertEq(pons.lastCreatorTaxBps(), 100);
        assertEq(router.feesCollected(), LOOTING_FEE);
    }

    function test_overpayIsRefunded() public {
        uint256 before = creator.balance;
        vm.prank(creator);
        router.launch{value: 1 ether}(_params(), 0, address(0));
        assertEq(creator.balance, before - PONS_FEE - LOOTING_FEE);
        assertEq(address(router).balance, 0);
    }

    function test_revertsWhenUnderpaid() public {
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(LootingLaunchRouter.FeeTooLow.selector, PONS_FEE, PONS_FEE + LOOTING_FEE)
        );
        router.launch{value: PONS_FEE}(_params(), 0, address(0));
    }

    function test_setFeeWalletOnlyAdmin() public {
        address next = makeAddr("nextFee");
        bytes32 adminRole = router.DEFAULT_ADMIN_ROLE();
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, creator, adminRole)
        );
        router.setFeeWallet(next);

        vm.prank(admin);
        router.setFeeWallet(next);
        assertEq(router.feeWallet(), next);
    }

    function test_setRewardRouterOnlyAdmin() public {
        address next = makeAddr("nextReward");
        vm.prank(admin);
        router.setRewardRouter(next);
        assertEq(router.rewardRouter(), next);
    }

    function test_pauseBlocksLaunch() public {
        vm.prank(pauser);
        router.pause();

        vm.prank(creator);
        vm.expectRevert();
        router.launch{value: PONS_FEE + LOOTING_FEE}(_params(), 0, address(0));
    }
}
