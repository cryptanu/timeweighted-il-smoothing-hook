# Time-Weighted IL Smoothing Hook Specification

## Summary

`TimeWeightedILSmoothingHook` is a standalone Uniswap v4 hook that smooths impermanent loss for long-tenured LPs. It records LP position entry state on add-liquidity, funds a token0 smoothing reserve from swap activity and direct deposits, invests idle reserve funds through a Morpho adapter, and pays a capped reimbursement before liquidity removal. The hook can also be wired to Reactive Network for automated settlement: an origin `ReactiveSettlementRequested` event is processed by a Lasna RSC, which calls back through the destination chain callback proxy.

## Goals

- Reward LP tenure without token emissions.
- Preserve withdrawals even when reserve capacity is low.
- Keep reserve accounting solvent at all times.
- Make the hackathon demo easy to understand: two LPs, same price move, different tenure, different IL payout.

## Non-Goals

- Exact concentrated-liquidity IL in v1.
- Reactive settlement is optional, but the repo includes a production-style Lasna RSC and scripts that prove origin event, RVM reaction, and destination callback separately.
- Reserve debt, leverage, or guaranteed coverage.
- Upgradeable governance.

## Core Formula

```text
totalIL = ILMath.computeIL(entryPrice, exitPrice, depositAmount0, depositAmount1)
smoothingFactor = TenureLib.computeFactor(entryTimestamp, block.timestamp, tierConfig)
requestedPayout = totalIL * smoothingFactor / 10_000
actualPayout = min(requestedPayout, reserveBalance * reserveShares / totalShares)
```

## Position State

```solidity
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
```

Positions are keyed as `keccak256(abi.encodePacked(lp, tickLower, tickUpper, salt))`.

## Reserve State

```solidity
struct ReserveState {
    uint256 totalBalance;
    uint256 morphoDeposited;
    uint256 totalShares;
    uint256 lastMorphoSync;
    uint256 accruedYield;
}
```

`totalBalance` includes idle hook funds plus Morpho-deposited principal and synced yield.

## Tier Config

```solidity
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
```

Production defaults are 7 days, 30 days, 90 days, 0%, 25%, 50%, 75%, and a 5% reserve fee share. Demo deployments compress durations to hours.

## Hook Permissions

```solidity
beforeInitialize: false
afterInitialize: false
beforeAddLiquidity: false
afterAddLiquidity: true
beforeRemoveLiquidity: true
afterRemoveLiquidity: false
beforeSwap: false
afterSwap: true
beforeDonate: false
afterDonate: false
beforeSwapReturnDelta: false
afterSwapReturnDelta: false
afterAddLiquidityReturnDelta: false
afterRemoveLiquidityReturnDelta: false
```

Security note: `beforeRemoveLiquidity` is high-risk because it runs before withdrawals. The implementation must never revert a valid withdrawal solely because reserve payout is unavailable.

## Lifecycle

### Add Liquidity

1. Decode optional `hookData` for LP identity and deposit accounting.
2. Read current pool price.
3. Compute position key.
4. Mint ERC-4626-style reserve shares proportional to deposit token0 value.
5. Store entry timestamp, price, liquidity, amounts, tick range, and salt.
6. Emit `LiquidityDeposited`.

### Swap

1. Observe the swap balance delta.
2. Compute reserve contribution as `feeBase * reserveFeeShare / 10_000`.
3. Increase reserve accounting.
4. Deposit idle funds to Morpho only when above threshold.
5. Emit `ReserveFunded`.

### Remove Liquidity

1. Load active position.
2. Read current price.
3. Compute full-range IL approximation.
4. Compute tenure smoothing factor.
5. Cap payout to LP reserve entitlement and total reserve balance.
6. Withdraw from Morpho if idle funds are insufficient.
7. Transfer token0 payout.
8. Burn reserve shares and delete position.
9. Emit `ILSmoothed`.

## Morpho

The hook uses `MorphoAdapter` to isolate Morpho Blue calls. Unit tests use `MockMorpho`, while live deployments can point the adapter to a real Morpho Blue market. The adapter is intentionally simple: supply token0, withdraw token0, sync observed balance, and report accrued yield back into reserve accounting.

## Test Plan

- IL math known values and symmetry.
- Tenure tier boundary tests.
- Reserve share proportionality.
- Tier 0, Tier 1, Tier 2, and Tier 3 withdrawal flows.
- Reserve solvency cap.
- Morpho deposit threshold and withdrawal-on-payout.
- Multi-LP proportional reserve entitlement.
- Fuzz tests for IL bounds and no-negative-reserve invariants.
- Scripted full-flow demo with labeled transaction URLs for live broadcasts.

## Risk Disclosure

- LPs still bear IL not covered by their tier or reserve entitlement.
- Reserve depletion never creates debt; it only lowers realized payouts.
- Morpho smart-contract risk is borne by the smoothing reserve.
- Full-range IL is approximate for concentrated positions and can overpay relative to exact concentrated IL.
