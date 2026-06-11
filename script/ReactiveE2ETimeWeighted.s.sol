// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Minimal} from "../src/interfaces/IERC20Minimal.sol";
import {TimeWeightedILSmoothingHook} from "../src/hooks/TimeWeightedILSmoothingHook.sol";

contract ReactiveE2ETimeWeighted is Script {
    uint160 internal constant Q96 = 79228162514264337593543950336;
    uint160 internal constant SQRT_2_X96 = 112045541949572279837463876454;
    uint256 internal constant REACTIVE_SETTLEMENT_TOPIC0 =
        uint256(keccak256("ReactiveSettlementRequested(bytes32,bytes32,address,uint160,uint256)"));

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address actor = vm.addr(privateKey);
        TimeWeightedILSmoothingHook hook = TimeWeightedILSmoothingHook(vm.envAddress("TIMEWEIGHTED_HOOK"));
        IERC20Minimal token = IERC20Minimal(vm.envAddress("TIMEWEIGHTED_TOKEN"));
        bytes32 poolId = vm.envBytes32("TIMEWEIGHTED_POOL_ID");
        address callbackProxy = vm.envAddress("TIMEWEIGHTED_CALLBACK_PROXY");
        address reactiveSender = vm.envAddress("TIMEWEIGHTED_RVM_SENDER");
        address rsc = vm.envOr("TIMEWEIGHTED_RSC", address(0));

        require(address(hook) != address(0), "TIMEWEIGHTED_HOOK missing");
        require(address(token) != address(0), "TIMEWEIGHTED_TOKEN missing");
        require(poolId != bytes32(0), "TIMEWEIGHTED_POOL_ID missing");
        require(callbackProxy != address(0), "TIMEWEIGHTED_CALLBACK_PROXY missing");
        require(reactiveSender != address(0), "TIMEWEIGHTED_RVM_SENDER missing");

        console2.log("== TimeWeightedILSmoothing Reactive E2E origin phase ==");
        console2.log("This script emits the live origin event Reactive watches and wires destination auth.");
        console2.log("It does not claim relay success until a Lasna RVM tx and destination callback tx are observed.");
        console2.log("actor", actor);
        console2.log("hook", address(hook));
        console2.log("token", address(token));
        console2.log("callbackProxy", callbackProxy);
        console2.log("reactiveSender/RVM identity", reactiveSender);
        console2.log("rsc", rsc);
        console2.log("poolId");
        console2.logBytes32(poolId);
        console2.log("settlement topic0");
        console2.logBytes32(bytes32(REACTIVE_SETTLEMENT_TOPIC0));

        vm.startBroadcast(privateKey);
        console2.log("Phase 1: configure hook Reactive auth");
        hook.configureReactive(callbackProxy, reactiveSender);
        console2.log("configureReactive tx:", _txPlaceholder("configure-reactive"));

        console2.log("Phase 2: ensure reserve has funds for payout");
        token.approve(address(hook), type(uint256).max);
        hook.fundReserve(10_000 ether);
        console2.log("fundReserve tx:", _txPlaceholder("fund-reserve"));

        console2.log("Phase 3: record a historical Tier 3 LP position for demo settlement");
        bytes32 key = hook.recordPositionForDemoAt(
            actor,
            -60,
            60,
            keccak256(abi.encode("reactive-e2e", block.chainid, block.number, actor)),
            Q96,
            1_000_000,
            1_000 ether,
            0,
            block.timestamp - 13 hours
        );
        console2.log("recordPosition tx:", _txPlaceholder("record-position"));
        console2.log("positionKey");
        console2.logBytes32(key);

        console2.log("Phase 4: emit pool-scoped ReactiveSettlementRequested");
        hook.requestReactiveSettlement(poolId, key, actor, SQRT_2_X96, block.timestamp + 1 days);
        console2.log("origin settlement request tx:", _txPlaceholder("reactive-settlement-request"));
        vm.stopBroadcast();

        (uint256 totalIL, uint256 requested, uint256 actualPayout, uint256 factor) = hook.previewPayout(key, SQRT_2_X96);
        console2.log("Phase 5: expected destination callback payload");
        console2.log(
            "function settlePositionFromReactive(address sender, bytes32 key, address recipient, uint160 exitPrice)"
        );
        console2.log("sender/RVM", reactiveSender);
        console2.log("recipient", actor);
        console2.log("exitSqrtPriceX96", SQRT_2_X96);
        console2.log("expectedTotalIL", totalIL);
        console2.log("smoothingFactorBps", factor);
        console2.log("requestedPayout", requested);
        console2.log("expectedActualPayout", actualPayout);

        console2.log("Phase 6: relay proof checklist");
        console2.log("1. Lasna RVM tx processes the origin event and emits Callback.");
        console2.log("2. Destination callback proxy calls hook.settlePositionFromReactive.");
        console2.log("3. Destination receipt emits ILSmoothed and ReactiveSettlementExecuted.");
        console2.log("Broadcast tx hashes are in broadcast/ReactiveE2ETimeWeighted.s.sol/<chain>/run-latest.json.");
    }

    function _txPlaceholder(string memory label) internal view returns (string memory) {
        if (block.chainid == 11155111) return string.concat("https://sepolia.etherscan.io/tx/<", label, ">");
        if (block.chainid == 84532) return string.concat("https://sepolia.basescan.org/tx/<", label, ">");
        if (block.chainid == 1301) return string.concat("https://sepolia.uniscan.xyz/tx/<", label, ">");
        return string.concat("tx:<", label, ">");
    }
}
