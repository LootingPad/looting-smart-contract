// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {LootingRewardRouter} from "./LootingRewardRouter.sol";

/// @title LootingLuckyBoxEthModule
/// @notice Interim prize payer: pulls ETH from RewardRouter and sends it to the winner.
/// @dev Auto-swap to rolled prize assets comes later. Keeper credits a claim; winner pulls to self
///      (destination is always msg.sender — AGENTS.md).
contract LootingLuckyBoxEthModule is AccessControl, ReentrancyGuard {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    LootingRewardRouter public immutable rewardRouter;

    /// @notice ETH credited per winner (from a specific launch's box pool).
    mapping(address winner => mapping(address token => uint256)) public pendingEth;

    event PrizeCredited(address indexed token, address indexed winner, uint256 amount, bytes32 indexed boxId);
    event PrizeClaimed(address indexed token, address indexed winner, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error NothingToClaim();
    error EthTransferFailed();

    constructor(address admin, address keeper, address rewardRouter_) {
        if (admin == address(0) || keeper == address(0) || rewardRouter_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, keeper);
        rewardRouter = LootingRewardRouter(payable(rewardRouter_));
    }

    receive() external payable {}

    /// @notice Keeper pulls `amount` from the launch box pool and credits `winner` (claimable by them).
    function creditEthPrize(address token, address winner, uint256 amount, bytes32 boxId)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
    {
        if (token == address(0) || winner == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        rewardRouter.pullLuckyBoxReward(token, amount);
        pendingEth[winner][token] += amount;
        emit PrizeCredited(token, winner, amount, boxId);
    }

    /// @notice Winner claims credited ETH for a launch. Pays msg.sender only.
    function claimEthPrize(address token) external nonReentrant returns (uint256 amount) {
        amount = pendingEth[msg.sender][token];
        if (amount == 0) revert NothingToClaim();
        pendingEth[msg.sender][token] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit PrizeClaimed(token, msg.sender, amount);
    }
}
