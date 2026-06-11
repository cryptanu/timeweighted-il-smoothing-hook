// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

library ILMath {
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant BPS = 10_000;

    error InvalidPrice();

    function computeILBps(uint160 entryPrice, uint160 exitPrice) internal pure returns (uint256 ilBps) {
        if (entryPrice == 0 || exitPrice == 0) revert InvalidPrice();

        uint256 sqrtRatioX96 = FullMath.mulDiv(uint256(exitPrice), Q96, uint256(entryPrice));
        uint256 priceRatioX96 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, Q96);
        uint256 denominator = Q96 + priceRatioX96;
        uint256 numerator = 2 * sqrtRatioX96;

        if (numerator >= denominator) return 0;
        ilBps = FullMath.mulDiv(denominator - numerator, BPS, denominator);
    }

    function computeIL(uint160 entryPrice, uint160 exitPrice, uint256 depositAmount0, uint256 depositAmount1)
        internal
        pure
        returns (uint256 ilInToken0)
    {
        uint256 ilBps = computeILBps(entryPrice, exitPrice);
        uint256 priceEntryX96 = FullMath.mulDiv(uint256(entryPrice), uint256(entryPrice), Q96);
        uint256 token1ValueInToken0 = FullMath.mulDiv(depositAmount1, priceEntryX96, Q96);
        uint256 depositValueInToken0 = depositAmount0 + token1ValueInToken0;
        ilInToken0 = FullMath.mulDiv(depositValueInToken0, ilBps, BPS);
    }
}
