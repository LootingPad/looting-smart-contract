// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILootingBuybackAdapter} from "../../src/FeeSplitter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Stand-in for the LOOTING buyback adapter. `rate` is LOOTING minted per 1 ETH, so a test
///         can simulate a good route, a bad route, or one that lies about its output.
contract MockBuybackAdapter is ILootingBuybackAdapter {
    uint256 public rate;
    uint256 public overstateBy;

    constructor(uint256 rate_) {
        rate = rate_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    /// @notice Makes the adapter report more output than it actually delivers.
    function setOverstateBy(uint256 amount) external {
        overstateBy = amount;
    }

    function swapExactETHForTokens(uint256, address token, address to, uint256)
        external
        payable
        returns (uint256 amountOut)
    {
        amountOut = (msg.value * rate) / 1 ether;
        MockERC20(token).mint(to, amountOut);
        return amountOut + overstateBy;
    }
}

/// @notice Reverts on plain ETH transfers, to prove a stuck ops wallet cannot block a create.
contract RejectEth {
    receive() external payable {
        revert("no eth");
    }
}
