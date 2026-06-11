// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMorphoBlue} from "../../src/interfaces/IMorphoBlue.sol";
import {IERC20Minimal} from "../../src/interfaces/IERC20Minimal.sol";

contract MockMorpho is IMorphoBlue {
    mapping(address => uint256) public supplied;

    function supply(MarketParams memory marketParams, uint256 assets, uint256, address onBehalf, bytes memory)
        external
        returns (uint256 assetsSupplied, uint256 sharesSupplied)
    {
        _safeTransferFrom(marketParams.loanToken, msg.sender, address(this), assets);
        supplied[onBehalf] += assets;
        return (assets, assets);
    }

    function withdraw(MarketParams memory marketParams, uint256 assets, uint256, address onBehalf, address receiver)
        external
        returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn)
    {
        uint256 available = supplied[onBehalf];
        uint256 amount = assets > available ? available : assets;
        supplied[onBehalf] -= amount;
        _safeTransfer(marketParams.loanToken, receiver, amount);
        return (amount, amount);
    }

    function donateYield(address token, uint256 amount) external {
        _safeTransferFrom(token, msg.sender, address(this), amount);
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
error TransferFailed();

