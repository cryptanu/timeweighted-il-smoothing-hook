# Build Prompt

You are building `TimeWeightedILSmoothing`, a production-quality Uniswap v4 hook for UHI9.

Before coding, read the local context:

1. `README.md`
2. `spec.md`
3. `context/README.md`
4. `context/uniswap-docs/docs`
5. `context/uhi-workshops/workshops`
6. `context/reactive-network/documentation`
7. `context/reactive-network/reactive-smart-contract-demos`
8. `context/reactive-network/reactive-lib`

Then build the hook to completion:

- Main hook: `src/hooks/TimeWeightedILSmoothingHook.sol`
- Libraries: `src/libraries/ILMath.sol`, `src/libraries/TenureLib.sol`
- Interfaces: `src/interfaces/ITimeWeightedILSmoothingHook.sol`, `src/interfaces/IMorphoBlue.sol`
- Adapter: `src/adapters/MorphoAdapter.sol`
- Tests:
  - unit tests for IL math and tenure tiers
  - integration tests for add/swap/remove lifecycle
  - fuzz tests for IL bounds, reserve solvency, and payout caps
  - mock Morpho tests
  - fork-test scaffolding for Sepolia, Base Sepolia, and Unichain Sepolia
- Scripts:
  - deployment script that mines a hook address with correct permission flags
  - full end-to-end demo script with labeled phases and clickable explorer URLs
  - runbook script that can use already deployed testnet addresses
- Frontend:
  - judge/user interface showing reserve state, LP positions, tenure tier, estimated IL, simulated payout, and demo status
  - no landing page; first screen is the working dashboard

Security requirements:

- Never enable `beforeSwapReturnDelta`, `afterSwapReturnDelta`, `afterAddLiquidityReturnDelta`, or `afterRemoveLiquidityReturnDelta` unless the implementation settles PoolManager deltas correctly.
- `beforeRemoveLiquidity` must not trap LP funds if reserve payout is unavailable.
- All external token transfers must use return-value checked safe transfers.
- Morpho calls must be isolated behind an adapter and fully mocked in tests.
- Payouts must always satisfy `totalPayouts <= reserve.totalBalanceBefore`.
- Reserve balance and total shares must never underflow.

Demo requirements:

- Compressed tiers: 1 hour, 6 hours, 12 hours.
- Show LP A in a lower tier and LP B in a higher tier.
- Move price, withdraw both LPs, and print `ILSmoothed` values.
- Print labeled transaction URL lines for deployment, reserve funding, simulated swaps, LP A withdrawal, LP B withdrawal, and final state.
- Reactive automation is included: prove the three layers separately in tests and scripts: origin event, Lasna/RVM reaction, destination callback. Do not claim relay success unless all three tx classes are observed.

Production target:

- `forge build` passes with no warnings.
- `forge test` passes.
- `forge test --fuzz-runs 10000` passes.
- Frontend builds successfully.
