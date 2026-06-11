// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {DemoTimeWeightedILSmoothingHook} from "../../src/demo/DemoTimeWeightedILSmoothingHook.sol";
import {ITimeWeightedILSmoothingHook} from "../../src/interfaces/ITimeWeightedILSmoothingHook.sol";

contract TestableTimeWeightedILSmoothingHook is DemoTimeWeightedILSmoothingHook {
    constructor(
        IPoolManager manager,
        address reserveToken,
        address morphoAdapter,
        ITimeWeightedILSmoothingHook.TierConfig memory config
    ) DemoTimeWeightedILSmoothingHook(manager, msg.sender, reserveToken, morphoAdapter, config) {}

    function exposedAfterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta) {
        return _afterAddLiquidity(sender, key, params, delta, BalanceDelta.wrap(0), hookData);
    }

    function exposedBeforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        return _beforeRemoveLiquidity(sender, key, params, hookData);
    }

    function exposedAfterSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128) {
        return _afterSwap(address(this), key, params, delta, hookData);
    }

    function exposedSetReserveState(ITimeWeightedILSmoothingHook.ReserveState memory state) external {
        reserve = state;
    }

    function exposedWithdrawFromMorpho(uint256 amount) external {
        _withdrawFromMorpho(amount);
    }
}
