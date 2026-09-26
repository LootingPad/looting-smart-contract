// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title LootingLaunchRegistry
/// @notice The record of which tokens were launched through LOOTING, plus the reward split each
///         launch was created with. Dev Lock and the staking factory use it as their gate, so an
///         unregistered ERC-20 can never be locked or vaulted (spec 61.7).
/// @dev Written by the backend after a launch transaction finalizes (spec 24 step 6, 29).
contract LootingLaunchRegistry is AccessControl {
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");

    enum Phase {
        Curve,
        Graduated
    }

    /// @notice Per-launch reward allocation, snapshotted at launch (spec 6).
    struct LaunchRewardConfig {
        address token;
        address curve;
        address creator;
        address creatorFeeRouter;
        uint16 creatorBps;
        uint16 luckyBoxBps;
        uint16 totalCreatorFeeBps;
        bool holderShareEnabled;
        address quoteAsset;
        uint64 launchedAt;
        Phase phase;
        bool rewardsEnabled;
        bytes32 configHash;
    }

    mapping(address token => LaunchRewardConfig) private _configs;
    address[] private _tokens;

    event LaunchRegistered(address indexed token, address indexed creator);
    event RewardSplitConfigured(address indexed token, uint16 creatorBps, uint16 luckyBoxBps);
    event LaunchPhaseUpdated(address indexed token, Phase phase);
    event RewardProgramPaused(address indexed token, bytes32 reason);
    event RewardProgramResumed(address indexed token);

    error AlreadyRegistered(address token);
    error NotRegistered(address token);
    error ZeroAddress();
    /// @dev Enforces `creatorBps + luckyBoxBps == totalCreatorFeeBps` (spec 17).
    error FeeSplitMismatch(uint16 creatorBps, uint16 luckyBoxBps, uint16 totalCreatorFeeBps);
    error FeeBpsAboveOneHundredPercent(uint16 totalCreatorFeeBps);

    constructor(address admin, address registrar) {
        if (admin == address(0) || registrar == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTRAR_ROLE, registrar);
    }

    function register(LaunchRewardConfig calldata config) external onlyRole(REGISTRAR_ROLE) {
        if (config.token == address(0) || config.creator == address(0)) revert ZeroAddress();
        if (_configs[config.token].token != address(0)) revert AlreadyRegistered(config.token);
        if (config.creatorBps + config.luckyBoxBps != config.totalCreatorFeeBps) {
            revert FeeSplitMismatch(config.creatorBps, config.luckyBoxBps, config.totalCreatorFeeBps);
        }
        if (config.totalCreatorFeeBps > 10_000) revert FeeBpsAboveOneHundredPercent(config.totalCreatorFeeBps);

        _configs[config.token] = config;
        _tokens.push(config.token);

        emit LaunchRegistered(config.token, config.creator);
        emit RewardSplitConfigured(config.token, config.creatorBps, config.luckyBoxBps);
    }

    function setPhase(address token, Phase phase) external onlyRole(REGISTRAR_ROLE) {
        _requireRegistered(token);
        _configs[token].phase = phase;
        emit LaunchPhaseUpdated(token, phase);
    }

    /// @notice Freezes the reward program for one launch, used when the Pons fee recipient stops
    ///         pointing at LOOTING (spec 33).
    function pauseRewardProgram(address token, bytes32 reason) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireRegistered(token);
        _configs[token].rewardsEnabled = false;
        emit RewardProgramPaused(token, reason);
    }

    function resumeRewardProgram(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireRegistered(token);
        _configs[token].rewardsEnabled = true;
        emit RewardProgramResumed(token);
    }

    function isLaunch(address token) external view returns (bool) {
        return _configs[token].token != address(0);
    }

    function creatorOf(address token) external view returns (address) {
        _requireRegistered(token);
        return _configs[token].creator;
    }

    function configOf(address token) external view returns (LaunchRewardConfig memory) {
        _requireRegistered(token);
        return _configs[token];
    }

    function launchCount() external view returns (uint256) {
        return _tokens.length;
    }

    /// @notice Paginated token list so an off-chain indexer or a TVL adapter can enumerate every
    ///         launch straight from chain state.
    function launches(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 total = _tokens.length;
        if (offset >= total) return new address[](0);
        uint256 remaining = total - offset;
        uint256 end = offset + (limit < remaining ? limit : remaining);
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = _tokens[i];
        }
    }

    function _requireRegistered(address token) private view {
        if (_configs[token].token == address(0)) revert NotRegistered(token);
    }
}
