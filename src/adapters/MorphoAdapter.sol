// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {IMorphoBlue} from "../interfaces/IMorphoBlue.sol";

contract MorphoAdapter {
    IERC20Minimal public immutable asset;
    IMorphoBlue public immutable morpho;
    IMorphoBlue.MarketParams public marketParams;

    uint256 public deposited;

    error TransferFailed();
    error InvalidAmount();

    constructor(IERC20Minimal asset_, IMorphoBlue morpho_, IMorphoBlue.MarketParams memory marketParams_) {
        asset = asset_;
        morpho = morpho_;
        marketParams = marketParams_;
    }

    function deposit(uint256 amount) external returns (uint256 assetsSupplied) {
        if (amount == 0) revert InvalidAmount();
        _safeTransferFrom(address(asset), msg.sender, address(this), amount);
        _safeApprove(address(asset), address(morpho), amount);
        (assetsSupplied,) = morpho.supply(marketParams, amount, 0, address(this), "");
        deposited += assetsSupplied;
    }

    function withdraw(uint256 amount, address receiver) external returns (uint256 assetsWithdrawn) {
        if (amount == 0) revert InvalidAmount();
        (assetsWithdrawn,) = morpho.withdraw(marketParams, amount, 0, address(this), receiver);
        deposited = assetsWithdrawn >= deposited ? 0 : deposited - assetsWithdrawn;
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.approve.selector, spender, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}

