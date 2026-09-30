// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";

import {LootingLaunchRegistry} from "../src/LootingLaunchRegistry.sol";
import {LootingRewardRouter} from "../src/LootingRewardRouter.sol";

contract MockLuckyBoxModule {
    LootingRewardRouter public immutable router;

    constructor(LootingRewardRouter router_) {
        router = router_;
    }

    receive() external payable {}

    function pull(address token, uint256 amount) external {
        router.pullLuckyBoxReward(token, amount);
    }
}

contract MockPonsFeeEscrow {
    mapping(address => uint256) public balanceOf;

    event Credited(address indexed recipient, uint256 amount);

    receive() external payable {}

    function credit(address recipient) external payable {
        balanceOf[recipient] += msg.value;
        emit Credited(recipient, msg.value);
    }

    function claim() external {
        uint256 amount = balanceOf[msg.sender];
        require(amount > 0, "nothing");
        balanceOf[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "pay fail");
    }
}

contract MockPonsBondingCurve {
    MockPonsFeeEscrow public immutable escrow;
    address public immutable recipient;
    uint256 public creatorTaxBalance;
    uint256 public quoteFeeBalance;
    uint256 public lastMinBuyback;
    address public lastSweeper;

    constructor(MockPonsFeeEscrow escrow_, address recipient_) {
        escrow = escrow_;
        recipient = recipient_;
    }

    receive() external payable {}

    function accrue(uint256 tax, uint256 quoteFee) external payable {
        creatorTaxBalance += tax;
        quoteFeeBalance += quoteFee;
    }

    function sweepFees(uint256 minBuybackTokensOut) external {
        lastSweeper = msg.sender;
        lastMinBuyback = minBuybackTokensOut;
        require(msg.sender == recipient, "not recipient");
        uint256 amount = creatorTaxBalance + quoteFeeBalance;
        creatorTaxBalance = 0;
        quoteFeeBalance = 0;
        if (amount > 0) {
            escrow.credit{value: amount}(recipient);
        }
    }
}

contract LootingRewardRouterTest is Test {
    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal pauser = makeAddr("pauser");
    address internal registrar = makeAddr("registrar");
    address internal burnWallet = makeAddr("burnWallet");
    address internal creator = makeAddr("creator");
    address internal ponsCurve = makeAddr("ponsCurve");

    LootingLaunchRegistry internal registry;
    LootingRewardRouter internal rewardRouter;
    MockLuckyBoxModule internal boxModule;
    MockPonsFeeEscrow internal feeEscrow;
    address internal token;

    function setUp() public {
        registry = new LootingLaunchRegistry(admin, registrar);
        rewardRouter = new LootingRewardRouter(admin, keeper, pauser, address(registry), burnWallet);
        boxModule = new MockLuckyBoxModule(rewardRouter);
        feeEscrow = new MockPonsFeeEscrow();

        vm.prank(admin);
        rewardRouter.setLuckyBoxModule(address(boxModule));
        vm.prank(admin);
        rewardRouter.setPonsFeeEscrow(address(feeEscrow));

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

        vm.deal(ponsCurve, 100 ether);
        vm.deal(creator, 1 ether);
    }

    function test_receiveAndAllocateSplitsCreatorBoxAndBurn() public {
        // 1 ETH tax → 0.5 creator, 0.5 box gross → box: 0.1 burn + 0.4 reward
        vm.prank(ponsCurve);
        (bool ok,) = address(rewardRouter).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(rewardRouter.unallocatedEth(), 1 ether);

        rewardRouter.allocate(token, 1 ether);

        assertEq(rewardRouter.unallocatedEth(), 0);
        assertEq(rewardRouter.creatorAccrued(token), 0.5 ether);
        assertEq(rewardRouter.luckyBoxRewardAccrued(token), 0.4 ether);
        assertEq(rewardRouter.burnBudgetAccrued(), 0.1 ether);
    }

    function test_claimCreatorPaysRegistryCreator() public {
        vm.prank(ponsCurve);
        (bool ok,) = address(rewardRouter).call{value: 1 ether}("");
        assertTrue(ok);
        rewardRouter.allocate(token, 1 ether);

        uint256 before = creator.balance;
        vm.prank(creator);
        uint256 paid = rewardRouter.claimCreator(token);
        assertEq(paid, 0.5 ether);
        assertEq(creator.balance, before + 0.5 ether);
        assertEq(rewardRouter.creatorClaimable(token), 0);

        vm.expectRevert();
        rewardRouter.claimCreator(token);
    }

    function test_pullLuckyBoxOnlyModule() public {
        vm.prank(ponsCurve);
        (bool ok,) = address(rewardRouter).call{value: 1 ether}("");
        assertTrue(ok);
        rewardRouter.allocate(token, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(LootingRewardRouter.NotLuckyBoxModule.selector, address(this)));
        rewardRouter.pullLuckyBoxReward(token, 0.1 ether);

        uint256 moduleBefore = address(boxModule).balance;
        boxModule.pull(token, 0.4 ether);
        assertEq(address(boxModule).balance, moduleBefore + 0.4 ether);
        assertEq(rewardRouter.luckyBoxClaimable(token), 0);
    }

    function test_withdrawBurnBudgetToFixedWallet() public {
        vm.prank(ponsCurve);
        (bool ok,) = address(rewardRouter).call{value: 1 ether}("");
        assertTrue(ok);
        rewardRouter.allocate(token, 1 ether);

        uint256 before = burnWallet.balance;
        rewardRouter.withdrawBurnBudget(0.1 ether);
        assertEq(burnWallet.balance, before + 0.1 ether);
        assertEq(rewardRouter.burnBudgetClaimable(), 0);
    }

    function test_allocateRevertsWhenPausedRewards() public {
        vm.prank(admin);
        registry.pauseRewardProgram(token, bytes32("test"));

        vm.prank(ponsCurve);
        (bool ok,) = address(rewardRouter).call{value: 1 ether}("");
        assertTrue(ok);

        vm.expectRevert(abi.encodeWithSelector(LootingRewardRouter.RewardsPaused.selector, token));
        rewardRouter.allocate(token, 1 ether);
    }

    function test_noRescueStyleAdminDrain() public {
        // Sanity: admin cannot redirect creator funds; claim always pays registry.creator.
        vm.prank(ponsCurve);
        (bool ok,) = address(rewardRouter).call{value: 1 ether}("");
        assertTrue(ok);
        rewardRouter.allocate(token, 1 ether);

        address stranger = makeAddr("stranger");
        uint256 strangerBefore = stranger.balance;
        vm.prank(stranger);
        rewardRouter.claimCreator(token);
        assertEq(stranger.balance, strangerBefore, "stranger got nothing");
        assertEq(rewardRouter.creatorClaimable(token), 0);
        // Funds went to creator even when stranger called claim.
        assertGt(creator.balance, 1 ether);
    }

    function test_harvestPonsFeesThenAllocate() public {
        vm.deal(address(this), 1 ether);
        feeEscrow.credit{value: 0.25 ether}(address(rewardRouter));
        assertEq(rewardRouter.ponsEscrowClaimable(), 0.25 ether);

        uint256 harvested = rewardRouter.harvestPonsFees();
        assertEq(harvested, 0.25 ether);
        assertEq(rewardRouter.unallocatedEth(), 0.25 ether);
        assertEq(rewardRouter.ponsEscrowClaimable(), 0);

        rewardRouter.allocate(token, 0.25 ether);
        assertEq(rewardRouter.creatorAccrued(token), 0.125 ether);
        assertEq(rewardRouter.luckyBoxRewardAccrued(token), 0.1 ether);
        assertEq(rewardRouter.burnBudgetAccrued(), 0.025 ether);
    }

    function test_harvestRevertsWhenEmpty() public {
        vm.expectRevert(LootingRewardRouter.NothingToHarvest.selector);
        rewardRouter.harvestPonsFees();
    }

    function test_sweepPonsCurveFeesThenHarvestAllocate() public {
        MockPonsBondingCurve curve = new MockPonsBondingCurve(feeEscrow, address(rewardRouter));
        vm.deal(address(this), 1 ether);
        curve.accrue{value: 0.2 ether}(0.15 ether, 0.05 ether);
        assertEq(curve.creatorTaxBalance(), 0.15 ether);

        // Anyone can trigger; curve sees msg.sender = RewardRouter.
        rewardRouter.sweepPonsCurveFees(address(curve), 0);
        assertEq(curve.lastSweeper(), address(rewardRouter));
        assertEq(curve.creatorTaxBalance(), 0);
        assertEq(rewardRouter.ponsEscrowClaimable(), 0.2 ether);

        uint256 harvested = rewardRouter.harvestPonsFees();
        assertEq(harvested, 0.2 ether);
        assertEq(rewardRouter.unallocatedEth(), 0.2 ether);

        rewardRouter.allocate(token, 0.2 ether);
        assertEq(rewardRouter.creatorAccrued(token), 0.1 ether);
        assertEq(rewardRouter.luckyBoxRewardAccrued(token), 0.08 ether);
        assertEq(rewardRouter.burnBudgetAccrued(), 0.02 ether);
    }
}
