// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Minimal} from "../src/interfaces/IERC20Minimal.sol";
import {TimeWeightedILSmoothingHook} from "../src/hooks/TimeWeightedILSmoothingHook.sol";

contract TestnetE2ETimeWeighted is Script {
    uint160 internal constant Q96 = 79228162514264337593543950336;
    uint160 internal constant SQRT_2_X96 = 112045541949572279837463876454;

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address actor = vm.addr(privateKey);
        TimeWeightedILSmoothingHook hook = TimeWeightedILSmoothingHook(vm.envAddress("TIMEWEIGHTED_HOOK"));
        IERC20Minimal token = IERC20Minimal(vm.envAddress("TIMEWEIGHTED_TOKEN"));

        console2.log("== TimeWeightedILSmoothing deployed testnet E2E ==");
        console2.log("Phase 1: approve hook to pull demo reserve token");
        vm.startBroadcast(privateKey);
        token.approve(address(hook), type(uint256).max);
        console2.log("approve tx:", _txPlaceholder("approve"));

        console2.log("Phase 2: fund smoothing reserve with 10,000 token0");
        hook.fundReserve(10_000 ether);
        console2.log("fundReserve tx:", _txPlaceholder("fund-reserve"));

        console2.log("Phase 3: record LP A as Tier 1 and LP B as Tier 3 historical positions");
        bytes32 keyA = hook.recordPositionForDemoAt(
            actor,
            -60,
            60,
            keccak256(abi.encode("testnet-lp-a", block.chainid, block.number)),
            Q96,
            1_000_000,
            1_000 ether,
            0,
            block.timestamp - 2 hours
        );
        console2.log("record LP A tx:", _txPlaceholder("record-lp-a"));
        bytes32 keyB = hook.recordPositionForDemoAt(
            actor,
            -60,
            60,
            keccak256(abi.encode("testnet-lp-b", block.chainid, block.number)),
            Q96,
            1_000_000,
            1_000 ether,
            0,
            block.timestamp - 13 hours
        );
        console2.log("record LP B tx:", _txPlaceholder("record-lp-b"));

        console2.log("Phase 4: preview same 2x price move for both LPs");
        _printPreview(hook, "LP A", keyA);
        _printPreview(hook, "LP B", keyB);

        console2.log("Phase 5: settle LP A and LP B");
        hook.settlePositionForDemoTo(keyA, actor, SQRT_2_X96);
        console2.log("settle LP A tx:", _txPlaceholder("settle-lp-a"));
        hook.settlePositionForDemoTo(keyB, actor, SQRT_2_X96);
        console2.log("settle LP B tx:", _txPlaceholder("settle-lp-b"));
        vm.stopBroadcast();

        (uint256 reserveBalance, uint256 morphoDeposited, uint256 totalShares,, uint256 accruedYield) = hook.reserve();
        console2.log("Phase 6: final reserve state");
        console2.log("reserveBalance", reserveBalance);
        console2.log("morphoDeposited", morphoDeposited);
        console2.log("totalShares", totalShares);
        console2.log("accruedYield", accruedYield);
        console2.log("Use broadcast/TestnetE2ETimeWeighted.s.sol/<chain>/run-latest.json for exact tx hashes.");
    }

    function _printPreview(TimeWeightedILSmoothingHook hook, string memory label, bytes32 key) internal view {
        (uint256 totalIL, uint256 requested, uint256 actualPayout, uint256 factor) = hook.previewPayout(key, SQRT_2_X96);
        console2.log(label);
        console2.log("totalIL", totalIL);
        console2.log("smoothingFactorBps", factor);
        console2.log("requestedPayout", requested);
        console2.log("actualPayout", actualPayout);
    }

    function _txPlaceholder(string memory label) internal view returns (string memory) {
        if (block.chainid == 11155111) return string.concat("https://sepolia.etherscan.io/tx/<", label, ">");
        if (block.chainid == 84532) return string.concat("https://sepolia.basescan.org/tx/<", label, ">");
        if (block.chainid == 1301) return string.concat("https://sepolia.uniscan.xyz/tx/<", label, ">");
        return string.concat("tx:<", label, ">");
    }
}

