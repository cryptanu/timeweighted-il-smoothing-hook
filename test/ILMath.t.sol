// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ILMath} from "../src/libraries/ILMath.sol";

contract ILMathHarness {
    function computeILBps(uint160 entryPrice, uint160 exitPrice) external pure returns (uint256) {
        return ILMath.computeILBps(entryPrice, exitPrice);
    }
}

contract ILMathTest is Test {
    uint160 internal constant Q96 = 79228162514264337593543950336;
    uint160 internal constant SQRT_2_X96 = 112045541949572279837463876454;
    uint160 internal constant INV_SQRT_2_X96 = 56022770974786139918731938227;

    function testComputeILNoPriceChange() external pure {
        assertEq(ILMath.computeILBps(Q96, Q96), 0);
    }

    function testComputeILRejectsZeroPrice() external {
        ILMathHarness harness = new ILMathHarness();

        vm.expectRevert(ILMath.InvalidPrice.selector);
        harness.computeILBps(0, Q96);

        vm.expectRevert(ILMath.InvalidPrice.selector);
        harness.computeILBps(Q96, 0);
    }

    function testComputeIL2xPriceIncrease() external pure {
        assertApproxEqAbs(ILMath.computeILBps(Q96, SQRT_2_X96), 572, 1);
    }

    function testComputeIL50PctDrop() external pure {
        assertApproxEqAbs(ILMath.computeILBps(Q96, INV_SQRT_2_X96), 572, 1);
    }

    function testComputeIL4xPriceIncrease() external pure {
        assertApproxEqAbs(ILMath.computeILBps(Q96, Q96 * 2), 2_000, 1);
    }

    function testSymmetry() external pure {
        assertApproxEqAbs(ILMath.computeILBps(Q96, SQRT_2_X96), ILMath.computeILBps(Q96, INV_SQRT_2_X96), 1);
    }

    function testFuzzILBounded(uint160 entry, uint160 exit) external pure {
        entry = uint160(bound(entry, Q96 / 1_000, Q96 * 1_000));
        exit = uint160(bound(exit, Q96 / 1_000, Q96 * 1_000));
        assertLe(ILMath.computeILBps(entry, exit), 10_000);
    }
}
