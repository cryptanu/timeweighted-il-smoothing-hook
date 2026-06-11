// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TenureLib} from "../src/libraries/TenureLib.sol";

contract TenureLibTest is Test {
    TenureLib.TierConfig internal config = TenureLib.TierConfig({
        tier0Duration: 7 days,
        tier1Duration: 30 days,
        tier2Duration: 90 days,
        tier0Factor: 0,
        tier1Factor: 2_500,
        tier2Factor: 5_000,
        tier3Factor: 7_500,
        reserveFeeShare: 500
    });

    function testTier0() external view {
        assertEq(TenureLib.factor(config, 100, 100 + 3 days), 0);
    }

    function testFutureEntryTimestampFallsBackToTier0() external view {
        assertEq(TenureLib.factor(config, 200, 100), 0);
    }

    function testTier1Lower() external view {
        assertEq(TenureLib.factor(config, 100, 100 + 7 days + 1), 2_500);
    }

    function testTier1Upper() external view {
        assertEq(TenureLib.factor(config, 100, 100 + 29 days), 2_500);
    }

    function testTier2Lower() external view {
        assertEq(TenureLib.factor(config, 100, 100 + 30 days + 1), 5_000);
    }

    function testTier3() external view {
        assertEq(TenureLib.factor(config, 100, 100 + 91 days), 7_500);
    }

    function testTierBoundaryExact7d() external view {
        assertEq(TenureLib.factor(config, 100, 100 + 7 days), 0);
    }
}
