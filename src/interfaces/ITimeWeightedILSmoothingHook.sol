// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ITimeWeightedILSmoothingHook {
    struct PositionState {
        uint256 entryTimestamp;
        uint160 entryPrice;
        uint128 liquidityAmount;
        uint256 depositAmount0;
        uint256 depositAmount1;
        uint256 reserveShares;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
        bool active;
    }

    struct ReserveState {
        uint256 totalBalance;
        uint256 morphoDeposited;
        uint256 totalShares;
        uint256 lastMorphoSync;
        uint256 accruedYield;
    }

    struct TierConfig {
        uint256 tier0Duration;
        uint256 tier1Duration;
        uint256 tier2Duration;
        uint256 tier0Factor;
        uint256 tier1Factor;
        uint256 tier2Factor;
        uint256 tier3Factor;
        uint256 reserveFeeShare;
    }

    event LiquidityDeposited(
        address indexed lp, bytes32 indexed positionKey, uint160 entryPrice, uint256 timestamp, uint256 reserveShares
    );
    event ReserveFunded(bytes32 indexed poolId, uint256 contribution, uint256 newReserveBalance);
    event ILSmoothed(
        address indexed lp, bytes32 indexed positionKey, uint256 totalIL, uint256 reservePayout, uint256 smoothingFactor
    );
    event MorphoDeposited(uint256 amount, uint256 totalMorphoBalance);
    event MorphoWithdrawn(uint256 amount, uint256 remainingMorphoBalance);
    event TierConfigUpdated(TierConfig newConfig);
    event ReactiveConfigUpdated(address indexed callbackProxy, address indexed reactiveSender);
    event ReactiveSettlementRequested(
        bytes32 indexed poolId,
        bytes32 indexed positionKey,
        address indexed recipient,
        uint160 exitSqrtPriceX96,
        uint256 deadline
    );
    event ReactiveSettlementExecuted(
        address indexed reactiveSender, bytes32 indexed positionKey, address indexed recipient, uint256 reservePayout
    );

    function computeSmoothingFactor(bytes32 positionKey) external view returns (uint256);
    function previewPayout(bytes32 positionKey, uint160 exitSqrtPriceX96)
        external
        view
        returns (uint256 totalIL, uint256 requestedPayout, uint256 actualPayout, uint256 smoothingFactor);
}
