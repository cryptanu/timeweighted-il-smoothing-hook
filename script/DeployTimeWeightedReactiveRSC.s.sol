// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TimeWeightedILSmoothingRSC} from "../src/rsc/TimeWeightedILSmoothingRSC.sol";

contract DeployTimeWeightedReactiveRSC is Script {
    uint256 internal constant REACTIVE_SETTLEMENT_TOPIC0 =
        uint256(keccak256("ReactiveSettlementRequested(bytes32,bytes32,address,uint160,uint256)"));

    function run() external returns (TimeWeightedILSmoothingRSC rsc) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address hook = vm.envAddress("TIMEWEIGHTED_HOOK");
        bytes32 poolId = vm.envOr("TIMEWEIGHTED_POOL_ID", bytes32(0));
        uint256 originChainId = vm.envOr("TIMEWEIGHTED_ORIGIN_CHAIN_ID", uint256(1301));
        uint256 destinationChainId = vm.envOr("TIMEWEIGHTED_DESTINATION_CHAIN_ID", uint256(1301));
        address systemContract =
            vm.envOr("REACTIVE_LASNA_SYSTEM_CONTRACT", address(0x0000000000000000000000000000000000fffFfF));
        uint64 callbackGasLimit = uint64(vm.envOr("TIMEWEIGHTED_CALLBACK_GAS_LIMIT", uint256(1_000_000)));
        address reactiveSender = vm.envAddress("TIMEWEIGHTED_RVM_SENDER");

        require(hook != address(0), "TIMEWEIGHTED_HOOK missing");
        require(poolId != bytes32(0), "TIMEWEIGHTED_POOL_ID missing");
        require(reactiveSender != address(0), "TIMEWEIGHTED_RVM_SENDER missing");

        console2.log("== TimeWeightedILSmoothing Lasna RSC deploy ==");
        console2.log("Reactive RPC should be legacy Lasna: https://lasna-rpc.rnk.dev/");
        console2.log("originChainId", originChainId);
        console2.log("destinationChainId", destinationChainId);
        console2.log("hook", hook);
        console2.log("systemContract", systemContract);
        console2.log("callbackGasLimit", callbackGasLimit);
        console2.log("reactiveSender/RVM identity", reactiveSender);
        console2.log("poolId");
        console2.logBytes32(poolId);
        console2.log("settlement topic0");
        console2.logBytes32(bytes32(REACTIVE_SETTLEMENT_TOPIC0));

        vm.startBroadcast(privateKey);
        rsc = new TimeWeightedILSmoothingRSC(
            systemContract,
            originChainId,
            destinationChainId,
            hook,
            poolId,
            REACTIVE_SETTLEMENT_TOPIC0,
            callbackGasLimit,
            reactiveSender
        );
        vm.stopBroadcast();

        console2.log("RSC", address(rsc));
        console2.log("subscriptionConfigured", rsc.subscriptionConfigured());
        console2.log("deploy tx: inspect broadcast/DeployTimeWeightedReactiveRSC.s.sol/5318007/run-latest.json");
    }
}
