// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {ITimeWeightedILSmoothingHook} from "../interfaces/ITimeWeightedILSmoothingHook.sol";
import {ILMath} from "../libraries/ILMath.sol";

contract TimeWeightedILSmoothingHook is BaseHook, ITimeWeightedILSmoothingHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    uint256 public constant BPS = 10_000;
    uint256 public constant DEFAULT_MORPHO_DEPOSIT_THRESHOLD = 0.05 ether;

    address public immutable reserveToken;
    address public immutable morphoAdapter;
    address public owner;
    address public callbackProxy;
    address public reactiveSender;

    TierConfig public tierConfig;
    ReserveState public reserve;

    mapping(bytes32 positionKey => PositionState) public positions;

    error OnlyOwner();
    error InvalidConfig();
    error InvalidAmount();
    error InvalidPosition();
    error ReactiveNotConfigured();
    error NotReactiveCallback();
    error InvalidReactiveSender();
    error TransferFailed();

    constructor(
        IPoolManager manager,
        address initialOwner,
        address reserveToken_,
        address morphoAdapter_,
        TierConfig memory config
    ) BaseHook(manager) {
        _validateConfig(config);
        owner = initialOwner == address(0) ? msg.sender : initialOwner;
        reserveToken = reserveToken_;
        morphoAdapter = morphoAdapter_;
        tierConfig = config;
    }

    function productionTierConfig() public pure returns (TierConfig memory) {
        return TierConfig({
            tier0Duration: 7 days,
            tier1Duration: 30 days,
            tier2Duration: 90 days,
            tier0Factor: 0,
            tier1Factor: 2_500,
            tier2Factor: 5_000,
            tier3Factor: 7_500,
            reserveFeeShare: 500
        });
    }

    function demoTierConfig() public pure returns (TierConfig memory) {
        return TierConfig({
            tier0Duration: 1 hours,
            tier1Duration: 6 hours,
            tier2Duration: 12 hours,
            tier0Factor: 0,
            tier1Factor: 2_500,
            tier2Factor: 5_000,
            tier3Factor: 7_500,
            reserveFeeShare: 500
        });
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function setTierConfig(TierConfig calldata newConfig) external {
        if (msg.sender != owner) revert OnlyOwner();
        _validateConfig(newConfig);
        tierConfig = newConfig;
        emit TierConfigUpdated(newConfig);
    }

    function configureReactive(address callbackProxy_, address reactiveSender_) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (callbackProxy_ == address(0) || reactiveSender_ == address(0)) revert InvalidConfig();
        callbackProxy = callbackProxy_;
        reactiveSender = reactiveSender_;
        emit ReactiveConfigUpdated(callbackProxy_, reactiveSender_);
    }

    function positionKey(address lp, int24 tickLower, int24 tickUpper, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(lp, tickLower, tickUpper, salt));
    }

    function fundReserve(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        _safeTransferFrom(reserveToken, msg.sender, address(this), amount);
        reserve.totalBalance += amount;
        emit ReserveFunded(bytes32(0), amount, reserve.totalBalance);
    }

    function recordPositionForDemo(
        address lp,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        uint160 entryPrice,
        uint128 liquidityAmount,
        uint256 depositAmount0,
        uint256 depositAmount1
    ) external returns (bytes32 key) {
        key = _recordPosition(
            lp, tickLower, tickUpper, salt, entryPrice, liquidityAmount, depositAmount0, depositAmount1, block.timestamp
        );
    }

    function recordPositionForDemoAt(
        address lp,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        uint160 entryPrice,
        uint128 liquidityAmount,
        uint256 depositAmount0,
        uint256 depositAmount1,
        uint256 entryTimestamp
    ) external returns (bytes32 key) {
        if (msg.sender != owner) revert OnlyOwner();
        key = _recordPosition(
            lp, tickLower, tickUpper, salt, entryPrice, liquidityAmount, depositAmount0, depositAmount1, entryTimestamp
        );
    }

    function settlePositionForDemo(bytes32 key, uint160 exitPrice) external returns (uint256 payout) {
        PositionState storage pos = positions[key];
        if (!pos.active) revert InvalidPosition();
        payout = _settlePosition(key, msg.sender, pos, exitPrice);
    }

    function settlePositionForDemoTo(bytes32 key, address receiver, uint160 exitPrice)
        external
        returns (uint256 payout)
    {
        if (msg.sender != owner) revert OnlyOwner();
        PositionState storage pos = positions[key];
        if (!pos.active) revert InvalidPosition();
        payout = _settlePosition(key, receiver, pos, exitPrice);
    }

    function requestReactiveSettlement(
        bytes32 poolId,
        bytes32 key,
        address recipient,
        uint160 exitPrice,
        uint256 deadline
    ) external {
        if (callbackProxy == address(0) || reactiveSender == address(0)) {
            revert ReactiveNotConfigured();
        }
        PositionState storage pos = positions[key];
        if (!pos.active || recipient == address(0) || exitPrice == 0) revert InvalidPosition();
        emit ReactiveSettlementRequested(poolId, key, recipient, exitPrice, deadline);
    }

    function settlePositionFromReactive(address sender, bytes32 key, address recipient, uint160 exitPrice)
        external
        returns (uint256 payout)
    {
        if (msg.sender != callbackProxy) revert NotReactiveCallback();
        if (sender != reactiveSender) revert InvalidReactiveSender();
        PositionState storage pos = positions[key];
        if (!pos.active || recipient == address(0) || exitPrice == 0) revert InvalidPosition();
        payout = _settlePosition(key, recipient, pos, exitPrice);
        emit ReactiveSettlementExecuted(sender, key, recipient, payout);
    }

    function computeSmoothingFactor(bytes32 key) external view returns (uint256) {
        PositionState memory pos = positions[key];
        if (!pos.active) return 0;
        return _computeSmoothingFactor(pos.entryTimestamp);
    }

    function previewPayout(bytes32 key, uint160 exitSqrtPriceX96)
        external
        view
        returns (uint256 totalIL, uint256 requestedPayout, uint256 actualPayout, uint256 smoothingFactor)
    {
        PositionState memory pos = positions[key];
        if (!pos.active) return (0, 0, 0, 0);
        totalIL = ILMath.computeIL(pos.entryPrice, exitSqrtPriceX96, pos.depositAmount0, pos.depositAmount1);
        smoothingFactor = _computeSmoothingFactor(pos.entryTimestamp);
        requestedPayout = FullMath.mulDiv(totalIL, smoothingFactor, BPS);
        uint256 entitlement = reserve.totalShares == 0
            ? 0
            : FullMath.mulDiv(reserve.totalBalance, pos.reserveShares, reserve.totalShares);
        actualPayout = _min(requestedPayout, entitlement);
    }

    function rebalanceMorpho(uint256 amount) external {
        if (morphoAdapter == address(0) || amount == 0) return;
        uint256 idle = _idleReserve();
        if (idle < amount || amount < DEFAULT_MORPHO_DEPOSIT_THRESHOLD) revert InvalidAmount();
        _safeApprove(reserveToken, morphoAdapter, amount);
        (bool ok, bytes memory data) = morphoAdapter.call(abi.encodeWithSignature("deposit(uint256)", amount));
        if (!ok) revert TransferFailed();
        uint256 supplied = data.length == 0 ? amount : abi.decode(data, (uint256));
        reserve.morphoDeposited += supplied;
        reserve.lastMorphoSync = block.timestamp;
        emit MorphoDeposited(supplied, reserve.morphoDeposited);
    }

    function syncMorphoYield(uint256 observedMorphoBalance) external {
        if (observedMorphoBalance > reserve.morphoDeposited) {
            uint256 yield = observedMorphoBalance - reserve.morphoDeposited;
            reserve.accruedYield += yield;
            reserve.totalBalance += yield;
        }
        reserve.morphoDeposited = observedMorphoBalance;
        reserve.lastMorphoSync = block.timestamp;
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        if (params.liquidityDelta <= 0) {
            return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
        }

        address lp = sender;
        bytes32 salt = params.salt;
        if (hookData.length >= 32) lp = abi.decode(hookData, (address));

        uint160 sqrtPriceX96 = _currentSqrtPrice(key.toId());
        _recordPosition(
            lp,
            params.tickLower,
            params.tickUpper,
            salt,
            sqrtPriceX96,
            uint128(uint256(int256(params.liquidityDelta))),
            _abs(delta.amount0()),
            _abs(delta.amount1()),
            block.timestamp
        );

        return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        address lp = sender;
        if (hookData.length >= 32) lp = abi.decode(hookData, (address));

        bytes32 keyHash = positionKey(lp, params.tickLower, params.tickUpper, params.salt);
        PositionState storage pos = positions[keyHash];
        if (pos.active) {
            _settlePosition(keyHash, lp, pos, _currentSqrtPrice(key.toId()));
        }
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        uint256 feeBase = _abs(delta.amount0()) + _abs(delta.amount1());
        uint256 contribution = FullMath.mulDiv(feeBase, tierConfig.reserveFeeShare, BPS);
        if (contribution > 0) {
            reserve.totalBalance += contribution;
            emit ReserveFunded(PoolId.unwrap(key.toId()), contribution, reserve.totalBalance);
        }
        return (BaseHook.afterSwap.selector, 0);
    }

    function _recordPosition(
        address lp,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        uint160 entryPrice,
        uint128 liquidityAmount,
        uint256 depositAmount0,
        uint256 depositAmount1,
        uint256 entryTimestamp
    ) internal returns (bytes32 key) {
        if (lp == address(0) || entryPrice == 0 || liquidityAmount == 0) {
            revert InvalidPosition();
        }
        key = positionKey(lp, tickLower, tickUpper, salt);

        uint256 shares = _mintReserveShares(depositAmount0 == 0 ? 1 : depositAmount0);
        positions[key] = PositionState({
            entryTimestamp: entryTimestamp,
            entryPrice: entryPrice,
            liquidityAmount: liquidityAmount,
            depositAmount0: depositAmount0,
            depositAmount1: depositAmount1,
            reserveShares: shares,
            tickLower: tickLower,
            tickUpper: tickUpper,
            salt: salt,
            active: true
        });

        emit LiquidityDeposited(lp, key, entryPrice, entryTimestamp, shares);
    }

    function _settlePosition(bytes32 key, address lp, PositionState storage pos, uint160 exitPrice)
        internal
        returns (uint256 payout)
    {
        uint256 totalIL = ILMath.computeIL(pos.entryPrice, exitPrice, pos.depositAmount0, pos.depositAmount1);
        uint256 smoothingFactor = _computeSmoothingFactor(pos.entryTimestamp);
        uint256 requestedPayout = FullMath.mulDiv(totalIL, smoothingFactor, BPS);
        uint256 entitlement = reserve.totalShares == 0
            ? 0
            : FullMath.mulDiv(reserve.totalBalance, pos.reserveShares, reserve.totalShares);
        payout = _min(requestedPayout, entitlement);

        uint256 idle = _idleReserve();
        if (payout > idle) _withdrawFromMorpho(payout - idle);

        uint256 balanceBefore = IERC20Minimal(reserveToken).balanceOf(address(this));
        payout = _min(payout, balanceBefore);
        if (payout > 0) {
            reserve.totalBalance -= payout;
            _safeTransfer(reserveToken, lp, payout);
        }

        if (reserve.totalShares >= pos.reserveShares) reserve.totalShares -= pos.reserveShares;
        else reserve.totalShares = 0;

        emit ILSmoothed(lp, key, totalIL, payout, smoothingFactor);
        delete positions[key];
    }

    function _mintReserveShares(uint256 depositAmount0) internal returns (uint256 shares) {
        if (reserve.totalShares == 0 || reserve.totalBalance == 0) shares = depositAmount0;
        else shares = FullMath.mulDiv(depositAmount0, reserve.totalShares, reserve.totalBalance);
        if (shares == 0) shares = 1;
        reserve.totalShares += shares;
    }

    function _withdrawFromMorpho(uint256 amount) internal {
        if (morphoAdapter == address(0) || amount == 0 || reserve.morphoDeposited == 0) return;
        uint256 toWithdraw = _min(amount, reserve.morphoDeposited);
        (bool ok, bytes memory data) =
            morphoAdapter.call(abi.encodeWithSignature("withdraw(uint256,address)", toWithdraw, address(this)));
        if (ok) {
            uint256 withdrawn = data.length == 0 ? toWithdraw : abi.decode(data, (uint256));
            reserve.morphoDeposited = withdrawn >= reserve.morphoDeposited ? 0 : reserve.morphoDeposited - withdrawn;
            emit MorphoWithdrawn(withdrawn, reserve.morphoDeposited);
        }
    }

    function _currentSqrtPrice(PoolId poolId) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
    }

    function _computeSmoothingFactor(uint256 entryTimestamp) internal view returns (uint256) {
        // forge-lint: disable-next-line(block-timestamp)
        uint256 tenure = block.timestamp <= entryTimestamp ? 0 : block.timestamp - entryTimestamp;
        if (tenure <= tierConfig.tier0Duration) return tierConfig.tier0Factor;
        if (tenure <= tierConfig.tier1Duration) return tierConfig.tier1Factor;
        if (tenure <= tierConfig.tier2Duration) return tierConfig.tier2Factor;
        return tierConfig.tier3Factor;
    }

    function _idleReserve() internal view returns (uint256) {
        if (reserve.totalBalance <= reserve.morphoDeposited) return 0;
        return reserve.totalBalance - reserve.morphoDeposited;
    }

    function _validateConfig(TierConfig memory config) internal pure {
        if (config.tier0Duration >= config.tier1Duration) revert InvalidConfig();
        if (config.tier1Duration >= config.tier2Duration) revert InvalidConfig();
        if (config.tier3Factor > BPS || config.reserveFeeShare > BPS) revert InvalidConfig();
    }

    function _abs(int128 value) internal pure returns (uint256) {
        return uint256(uint128(value < 0 ? -value : value));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.approve.selector, spender, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
