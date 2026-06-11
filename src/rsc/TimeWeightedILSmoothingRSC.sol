// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";

contract TimeWeightedILSmoothingRSC is AbstractReactive {
    uint256 public immutable ORIGIN_CHAIN_ID;
    uint256 public immutable DESTINATION_CHAIN_ID;
    address public immutable HOOK;
    bytes32 public immutable POOL_ID_FILTER;
    uint256 public immutable SETTLEMENT_TOPIC0;
    uint64 public immutable CALLBACK_GAS_LIMIT;
    address public immutable CALLBACK_SENDER;

    bool public subscriptionConfigured;

    event SubscriptionConfigured(
        uint256 indexed originChainId, address indexed hook, uint256 indexed topic0, bytes32 poolIdFilter, bool success
    );
    event SettlementCallbackQueued(
        uint256 indexed destinationChainId,
        address indexed hook,
        bytes32 indexed positionKey,
        address recipient,
        uint160 exitSqrtPriceX96
    );

    constructor(
        address service_,
        uint256 originChainId_,
        uint256 destinationChainId_,
        address hook_,
        bytes32 poolIdFilter_,
        uint256 settlementTopic0_,
        uint64 callbackGasLimit_,
        address callbackSender_
    ) {
        service = ISystemContract(payable(service_));
        ORIGIN_CHAIN_ID = originChainId_;
        DESTINATION_CHAIN_ID = destinationChainId_;
        HOOK = hook_;
        POOL_ID_FILTER = poolIdFilter_;
        SETTLEMENT_TOPIC0 = settlementTopic0_;
        CALLBACK_GAS_LIMIT = callbackGasLimit_ == 0 ? 1_000_000 : callbackGasLimit_;
        CALLBACK_SENDER = callbackSender_ == address(0) ? msg.sender : callbackSender_;

        if (!vm) {
            _configureSubscription();
        }
    }

    function configureSubscription() external returns (bool success) {
        success = _configureSubscription();
    }

    function react(LogRecord calldata log) external vmOnly {
        if (log.chain_id != ORIGIN_CHAIN_ID) return;
        if (log._contract != HOOK) return;
        if (log.topic_0 != SETTLEMENT_TOPIC0) return;
        if (POOL_ID_FILTER != bytes32(0) && bytes32(log.topic_1) != POOL_ID_FILTER) return;

        bytes32 positionKey = bytes32(log.topic_2);
        address recipient = address(uint160(log.topic_3));
        (uint160 exitSqrtPriceX96, uint256 deadline) = abi.decode(log.data, (uint160, uint256));
        if (deadline != 0 && block.timestamp > deadline) return;

        bytes memory payload = abi.encodeWithSignature(
            "settlePositionFromReactive(address,bytes32,address,uint160)",
            CALLBACK_SENDER,
            positionKey,
            recipient,
            exitSqrtPriceX96
        );

        emit SettlementCallbackQueued(DESTINATION_CHAIN_ID, HOOK, positionKey, recipient, exitSqrtPriceX96);
        emit Callback(DESTINATION_CHAIN_ID, HOOK, CALLBACK_GAS_LIMIT, payload);
    }

    function _configureSubscription() internal returns (bool success) {
        uint256 topic1 = POOL_ID_FILTER == bytes32(0) ? REACTIVE_IGNORE : uint256(POOL_ID_FILTER);
        (success,) = address(service)
            .call(
                abi.encodeWithSelector(
                    service.subscribe.selector,
                    ORIGIN_CHAIN_ID,
                    HOOK,
                    SETTLEMENT_TOPIC0,
                    topic1,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                )
            );
        subscriptionConfigured = success;
        emit SubscriptionConfigured(ORIGIN_CHAIN_ID, HOOK, SETTLEMENT_TOPIC0, POOL_ID_FILTER, success);
    }
}
