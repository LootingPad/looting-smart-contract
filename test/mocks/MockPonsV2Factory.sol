// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPonsV2Factory} from "../../src/pons-adapter/LootingLaunchRouter.sol";

/// @dev Minimal Pons factory stub for router unit tests.
contract MockPonsV2Factory is IPonsV2Factory {
    uint256 public override launchFee = 0.0005 ether;
    address public lastDeployer;
    address public lastCreatorFeeRecipient;
    uint16 public lastCreatorTaxBps;
    bool public lastBuybackEnabled;
    uint256 public launchCount;

    function setLaunchFee(uint256 next) external {
        launchFee = next;
    }

    function launchToken(TokenParams calldata params, uint256, address)
        external
        payable
        override
        returns (address token, address curve)
    {
        return _launch(params);
    }

    function launchToken(TokenParams calldata params, uint256, address, address[] calldata)
        external
        payable
        override
        returns (address token, address curve)
    {
        return _launch(params);
    }

    function _launch(TokenParams calldata params) private returns (address token, address curve) {
        require(msg.value >= launchFee, "fee");
        lastDeployer = msg.sender;
        lastCreatorFeeRecipient = params.creatorFeeRecipient;
        lastCreatorTaxBps = params.creatorTaxBps;
        lastBuybackEnabled = params.buybackEnabled;
        launchCount += 1;
        token = address(uint160(0xBEEF0000 + launchCount));
        curve = address(uint160(0xCAFE0000 + launchCount));
        uint256 refund = msg.value - launchFee;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "refund");
        }
    }
}
