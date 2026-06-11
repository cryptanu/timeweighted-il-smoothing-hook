// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ITimeWeightedILSmoothingHook} from "../interfaces/ITimeWeightedILSmoothingHook.sol";
import {TimeWeightedILSmoothingHook} from "../hooks/TimeWeightedILSmoothingHook.sol";

contract DemoTimeWeightedILSmoothingHook is TimeWeightedILSmoothingHook {
    constructor(
        IPoolManager manager,
        address initialOwner,
        address reserveToken,
        address morphoAdapter,
        ITimeWeightedILSmoothingHook.TierConfig memory config
    ) TimeWeightedILSmoothingHook(manager, initialOwner, reserveToken, morphoAdapter, config) {}

    function validateHookAddress(BaseHook) internal pure override {}
}
