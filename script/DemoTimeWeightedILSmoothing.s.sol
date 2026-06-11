// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ITimeWeightedILSmoothingHook} from "../src/interfaces/ITimeWeightedILSmoothingHook.sol";
import {DemoERC20} from "../src/test/DemoERC20.sol";
import {DemoTimeWeightedILSmoothingHook} from "../src/demo/DemoTimeWeightedILSmoothingHook.sol";

contract DemoTimeWeightedILSmoothing is Script {
    uint160 internal constant Q96 = 79228162514264337593543950336;
    uint160 internal constant SQRT_2_X96 = 112045541949572279837463876454;

    function run() external {
        address lpA = address(0xA11CE);
        address lpB = address(0xB0B);
        address operator = address(0xCAFE);

        console2.log("== TimeWeightedILSmoothing full E2E demo ==");
        console2.log("Phase 1: deploy local reserve token and hook");

        DemoERC20 token0 = new DemoERC20("Demo USD", "dUSD", 18);
        DemoTimeWeightedILSmoothingHook hook = new DemoTimeWeightedILSmoothingHook(
            IPoolManager(address(0xBEEF)),
            operator,
            address(token0),
            address(0),
            ITimeWeightedILSmoothingHook.TierConfig(1 hours, 6 hours, 12 hours, 0, 2_500, 5_000, 7_500, 500)
        );

        token0.mint(operator, 100_000 ether);

        console2.log("Hook deployment tx URL:", _placeholderTx("deploy-hook"));
        console2.log("hook", address(hook));

        console2.log("Phase 2: fund smoothing reserve");
        vm.startPrank(operator);
        token0.approve(address(hook), type(uint256).max);
        hook.fundReserve(10_000 ether);
        vm.stopPrank();
        console2.log("Reserve funding tx URL:", _placeholderTx("fund-reserve"));

        console2.log("Phase 3: open LP A and LP B positions");
        bytes32 keyA = hook.recordPositionForDemo(lpA, -60, 60, keccak256("LP_A"), Q96, 1_000_000, 1_000 ether, 0);
        bytes32 keyB = hook.recordPositionForDemo(lpB, -60, 60, keccak256("LP_B"), Q96, 1_000_000, 1_000 ether, 0);
        console2.log("LP A position key");
        console2.logBytes32(keyA);
        console2.log("LP B position key");
        console2.logBytes32(keyB);

        console2.log("Phase 4: age LP A into Tier 1 and preview 2x price-move IL");
        vm.warp(block.timestamp + 2 hours);
        _printPreview(hook, "LP A", keyA);
        vm.prank(lpA);
        uint256 payoutA = hook.settlePositionForDemo(keyA, SQRT_2_X96);
        console2.log("LP A withdrawal tx URL:", _placeholderTx("withdraw-lp-a"));
        console2.log("LP A payout", payoutA);

        console2.log("Phase 5: age LP B into Tier 3 and preview same price move");
        vm.warp(block.timestamp + 11 hours);
        _printPreview(hook, "LP B", keyB);

        console2.log("Phase 6: settle LP B");
        vm.prank(lpB);
        uint256 payoutB = hook.settlePositionForDemo(keyB, SQRT_2_X96);
        console2.log("LP B withdrawal tx URL:", _placeholderTx("withdraw-lp-b"));
        console2.log("LP B payout", payoutB);

        (uint256 reserveBalance, uint256 morphoDeposited, uint256 totalShares,, uint256 accruedYield) = hook.reserve();
        console2.log("Phase 7: final reserve state");
        console2.log("reserveBalance", reserveBalance);
        console2.log("morphoDeposited", morphoDeposited);
        console2.log("totalShares", totalShares);
        console2.log("accruedYield", accruedYield);
        console2.log("Close: Stay longer, suffer less.");
    }

    function _printPreview(DemoTimeWeightedILSmoothingHook hook, string memory label, bytes32 key) internal view {
        (uint256 totalIL, uint256 requested, uint256 actualPayout, uint256 factor) = hook.previewPayout(key, SQRT_2_X96);
        console2.log(label);
        console2.log("totalIL", totalIL);
        console2.log("smoothingFactorBps", factor);
        console2.log("requestedPayout", requested);
        console2.log("actualPayout", actualPayout);
    }

    function _placeholderTx(string memory label) internal view returns (string memory) {
        if (block.chainid == 11155111) return string.concat("https://sepolia.etherscan.io/tx/<", label, ">");
        if (block.chainid == 84532) return string.concat("https://sepolia.basescan.org/tx/<", label, ">");
        if (block.chainid == 1301) return string.concat("https://sepolia.uniscan.xyz/tx/<", label, ">");
        return string.concat("local-anvil://tx/<", label, ">");
    }
}
