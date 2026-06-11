// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

contract InitializeTimeWeightedPool is Script {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant Q96 = 79228162514264337593543950336;

    function run() external returns (bytes32 poolId) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address poolManager = _poolManagerForChain();
        address hook = vm.envAddress("TIMEWEIGHTED_HOOK");
        address token = vm.envAddress("TIMEWEIGHTED_TOKEN");
        uint24 fee = uint24(vm.envOr("TIMEWEIGHTED_POOL_FEE", uint256(3000)));
        int24 tickSpacing = int24(int256(vm.envOr("TIMEWEIGHTED_TICK_SPACING", uint256(60))));
        uint160 sqrtPriceX96 = uint160(vm.envOr("TIMEWEIGHTED_INITIAL_SQRT_PRICE_X96", uint256(Q96)));

        require(poolManager != address(0), "pool manager missing");
        require(hook != address(0), "hook missing");
        require(token != address(0), "token missing");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });
        poolId = PoolId.unwrap(key.toId());

        console2.log("== Initialize TimeWeighted v4 demo pool ==");
        console2.log("poolManager", poolManager);
        console2.log("hook", hook);
        console2.log("currency0 native", address(0));
        console2.log("currency1 token", token);
        console2.log("fee", fee);
        console2.log("tickSpacing", tickSpacing);
        console2.log("sqrtPriceX96", sqrtPriceX96);
        console2.log("poolId");
        console2.logBytes32(poolId);

        vm.startBroadcast(privateKey);
        int24 tick = IPoolManager(poolManager).initialize(key, sqrtPriceX96);
        vm.stopBroadcast();

        console2.log("initialTick", tick);
        console2.log("initialize tx: inspect broadcast/InitializeTimeWeightedPool.s.sol/<chain>/run-latest.json");
    }

    function _poolManagerForChain() internal view returns (address) {
        if (block.chainid == 11155111) return vm.envAddress("ETH_SEPOLIA_POOL_MANAGER");
        if (block.chainid == 84532) return vm.envAddress("BASE_SEPOLIA_POOL_MANAGER");
        if (block.chainid == 1301) return vm.envAddress("UNICHAIN_SEPOLIA_POOL_MANAGER");
        return vm.envAddress("POOL_MANAGER");
    }
}
