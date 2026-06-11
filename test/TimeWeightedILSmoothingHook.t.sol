// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IMorphoBlue} from "../src/interfaces/IMorphoBlue.sol";
import {IERC20Minimal} from "../src/interfaces/IERC20Minimal.sol";
import {ITimeWeightedILSmoothingHook} from "../src/interfaces/ITimeWeightedILSmoothingHook.sol";
import {MorphoAdapter} from "../src/adapters/MorphoAdapter.sol";
import {DemoERC20} from "../src/test/DemoERC20.sol";
import {MockMorpho} from "./helpers/MockMorpho.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {TenureLib} from "../src/libraries/TenureLib.sol";
import {TimeWeightedILSmoothingRSC} from "../src/rsc/TimeWeightedILSmoothingRSC.sol";
import {TimeWeightedILSmoothingHook} from "../src/hooks/TimeWeightedILSmoothingHook.sol";
import {TestableTimeWeightedILSmoothingHook} from "./helpers/TestableTimeWeightedILSmoothingHook.sol";

contract MockPoolManager {
    bytes32 internal slot0;

    function setSlot0(uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) external {
        slot0 = bytes32(
            uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160) | (uint256(protocolFee) << 184)
                | (uint256(lpFee) << 208)
        );
    }

    function extsload(bytes32) external view returns (bytes32) {
        return slot0;
    }

    function extsload(bytes32, uint256 nSlots) external view returns (bytes32[] memory values) {
        values = new bytes32[](nSlots);
        if (nSlots > 0) values[0] = slot0;
    }
}

contract MockSystemContract {
    event Subscribe(
        address indexed subscriber,
        uint256 indexed chainId,
        address indexed origin,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    );

    function subscribe(uint256 chainId, address origin, uint256 topic0, uint256 topic1, uint256 topic2, uint256 topic3)
        external
    {
        emit Subscribe(msg.sender, chainId, origin, topic0, topic1, topic2, topic3);
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

contract RevertingSystemContract {
    fallback() external payable {
        revert("subscribe failed");
    }
}

contract MockReactiveCallbackProxy {
    function forward(address target, bytes calldata payload) external returns (bytes memory result) {
        (bool ok, bytes memory data) = target.call(payload);
        if (!ok) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
        return data;
    }
}

contract ConfigurableToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public approveOk = true;
    bool public transferOk = true;
    bool public transferFromOk = true;

    function setReturnValues(bool approveOk_, bool transferOk_, bool transferFromOk_) external {
        approveOk = approveOk_;
        transferOk = transferOk_;
        transferFromOk = transferFromOk_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (!approveOk) return false;
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (!transferOk) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (!transferFromOk) return false;
        if (from != msg.sender) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract NoReturnAdapter {
    function deposit(uint256) external {}
    function withdraw(uint256, address) external {}
}

contract RevertingAdapter {
    function deposit(uint256) external pure {
        revert("deposit failed");
    }

    function withdraw(uint256, address) external pure {
        revert("withdraw failed");
    }
}

contract TenureHarness {
    function validate(TenureLib.TierConfig memory config) external pure {
        TenureLib.validate(config);
    }

    function factor(TenureLib.TierConfig memory config, uint256 entryTimestamp, uint256 nowTimestamp)
        external
        pure
        returns (uint256)
    {
        return TenureLib.factor(config, entryTimestamp, nowTimestamp);
    }
}

contract TimeWeightedILSmoothingHookTest is Test {
    uint160 internal constant Q96 = 79228162514264337593543950336;
    uint160 internal constant SQRT_2_X96 = 112045541949572279837463876454;
    uint256 internal constant REACTIVE_SETTLEMENT_TOPIC0 =
        uint256(keccak256("ReactiveSettlementRequested(bytes32,bytes32,address,uint160,uint256)"));

    address internal lpA = address(0xA11CE);
    address internal lpB = address(0xB0B);
    address internal rvmSender = address(0x1234);

    DemoERC20 internal token0;
    MockMorpho internal morpho;
    MorphoAdapter internal adapter;
    TestableTimeWeightedILSmoothingHook internal hook;
    MockReactiveCallbackProxy internal callbackProxy;
    MockPoolManager internal mockPoolManager;

    function setUp() external {
        token0 = new DemoERC20("Demo USD", "dUSD", 18);
        morpho = new MockMorpho();
        IMorphoBlue.MarketParams memory market =
            IMorphoBlue.MarketParams(address(token0), address(0), address(0), address(0), 0);
        adapter = new MorphoAdapter(IERC20Minimal(address(token0)), morpho, market);
        mockPoolManager = new MockPoolManager();
        mockPoolManager.setSlot0(Q96, 0, 0, 3_000);
        hook = new TestableTimeWeightedILSmoothingHook(
            IPoolManager(address(mockPoolManager)), address(token0), address(adapter), _demoConfig()
        );

        token0.mint(address(this), 1_000_000 ether);
        token0.approve(address(hook), type(uint256).max);
        hook.fundReserve(10_000 ether);
        callbackProxy = new MockReactiveCallbackProxy();
    }

    function testStaticConfigsAndPermissions() external view {
        ITimeWeightedILSmoothingHook.TierConfig memory prod = hook.productionTierConfig();
        ITimeWeightedILSmoothingHook.TierConfig memory demo = hook.demoTierConfig();
        assertEq(prod.tier0Duration, 7 days);
        assertEq(demo.tier0Duration, 1 hours);
        assertEq(demo.reserveFeeShare, 500);
        assertTrue(hook.getHookPermissions().afterAddLiquidity);
        assertTrue(hook.getHookPermissions().beforeRemoveLiquidity);
        assertTrue(hook.getHookPermissions().afterSwap);
        assertFalse(hook.getHookPermissions().beforeSwapReturnDelta);
    }

    function testOnlyOwnerAndConfigGuards() external {
        vm.prank(lpA);
        vm.expectRevert(TimeWeightedILSmoothingHook.OnlyOwner.selector);
        hook.setTierConfig(_demoConfig());

        ITimeWeightedILSmoothingHook.TierConfig memory invalid = _demoConfig();
        invalid.tier0Duration = invalid.tier1Duration;
        vm.expectRevert(TimeWeightedILSmoothingHook.InvalidConfig.selector);
        hook.setTierConfig(invalid);

        invalid = _demoConfig();
        invalid.tier1Duration = invalid.tier2Duration;
        vm.expectRevert(TimeWeightedILSmoothingHook.InvalidConfig.selector);
        hook.setTierConfig(invalid);

        invalid = _demoConfig();
        invalid.reserveFeeShare = 10_001;
        vm.expectRevert(TimeWeightedILSmoothingHook.InvalidConfig.selector);
        hook.setTierConfig(invalid);

        vm.prank(lpA);
        vm.expectRevert(TimeWeightedILSmoothingHook.OnlyOwner.selector);
        hook.configureReactive(address(callbackProxy), rvmSender);

        vm.expectRevert(TimeWeightedILSmoothingHook.InvalidConfig.selector);
        hook.configureReactive(address(0), rvmSender);

        ITimeWeightedILSmoothingHook.TierConfig memory replacement = _demoConfig();
        replacement.reserveFeeShare = 250;
        hook.setTierConfig(replacement);
        (,,,,,,, uint256 reserveFeeShare) = hook.tierConfig();
        assertEq(reserveFeeShare, 250);
    }

    function testConstructorUsesMsgSenderWhenInitialOwnerZero() external {
        TestableTimeWeightedILSmoothingHook ownedByDeployer = new TestableTimeWeightedILSmoothingHook(
            IPoolManager(address(mockPoolManager)), address(token0), address(adapter), _demoConfig()
        );
        assertEq(ownedByDeployer.owner(), address(this));
    }

    function testFullLifecycleTier0PaysNothing() external {
        bytes32 key = _record(lpA, 100 ether);
        vm.warp(block.timestamp + 30 minutes);

        (uint256 totalIL,, uint256 actualPayout, uint256 factor) = hook.previewPayout(key, SQRT_2_X96);
        assertGt(totalIL, 0);
        assertEq(factor, 0);
        assertEq(actualPayout, 0);

        vm.prank(lpA);
        uint256 paid = hook.settlePositionForDemo(key, SQRT_2_X96);
        assertEq(paid, 0);
    }

    function testFullLifecycleTier1Pays25Percent() external {
        bytes32 key = _record(lpA, 1_000 ether);
        vm.warp(block.timestamp + 2 hours);

        (uint256 totalIL, uint256 requested, uint256 actualPayout, uint256 factor) = hook.previewPayout(key, SQRT_2_X96);
        assertEq(factor, 2_500);
        assertApproxEqAbs(requested, totalIL / 4, 2);
        assertEq(actualPayout, requested);

        uint256 beforeBalance = token0.balanceOf(lpA);
        vm.prank(lpA);
        uint256 paid = hook.settlePositionForDemo(key, SQRT_2_X96);
        assertEq(paid, actualPayout);
        assertEq(token0.balanceOf(lpA) - beforeBalance, actualPayout);
    }

    function testFullLifecycleTier3Pays75Percent() external {
        bytes32 key = _record(lpA, 1_000 ether);
        vm.warp(block.timestamp + 13 hours);

        (uint256 totalIL, uint256 requested, uint256 actualPayout, uint256 factor) = hook.previewPayout(key, SQRT_2_X96);
        assertEq(factor, 7_500);
        assertApproxEqAbs(requested, (totalIL * 75) / 100, 3);
        assertEq(actualPayout, requested);
    }

    function testReserveSolvencyProtectionCapsPayout() external {
        bytes32 key = _record(lpA, 1_000_000 ether);
        vm.warp(block.timestamp + 13 hours);

        (,, uint256 actualPayout,) = hook.previewPayout(key, SQRT_2_X96);
        assertLe(actualPayout, 10_000 ether);

        vm.prank(lpA);
        uint256 paid = hook.settlePositionForDemo(key, SQRT_2_X96);
        assertEq(paid, actualPayout);
    }

    function testMultipleLPsProportionalShares() external {
        TestableTimeWeightedILSmoothingHook freshHook = new TestableTimeWeightedILSmoothingHook(
            IPoolManager(address(0xBEEF)), address(token0), address(adapter), _demoConfig()
        );
        bytes32 keyA = freshHook.recordPositionForDemo(lpA, -60, 60, keccak256("fresh-a"), Q96, 1_000_000, 100 ether, 0);
        bytes32 keyB = freshHook.recordPositionForDemo(lpB, -60, 60, keccak256("fresh-b"), Q96, 1_000_000, 50 ether, 0);

        (,,,,, uint256 sharesA,,,,) = freshHook.positions(keyA);
        (,,,,, uint256 sharesB,,,,) = freshHook.positions(keyB);
        assertEq(sharesA, 2 * sharesB);
    }

    function testOwnerRecordedPositionAndDirectedSettlement() external {
        vm.prank(lpA);
        vm.expectRevert(TimeWeightedILSmoothingHook.OnlyOwner.selector);
        hook.recordPositionForDemoAt(lpA, -60, 60, keccak256("not-owner"), Q96, 1_000_000, 1 ether, 0, block.timestamp);

        bytes32 key = hook.recordPositionForDemoAt(
            lpA, -60, 60, keccak256("owner-recorded"), Q96, 1_000_000, 1_000 ether, 0, block.timestamp
        );

        vm.warp(block.timestamp + 13 hours);
        assertEq(hook.computeSmoothingFactor(key), 7_500);

        (,, uint256 expectedPayout,) = hook.previewPayout(key, SQRT_2_X96);
        uint256 beforeBalance = token0.balanceOf(lpB);
        uint256 paid = hook.settlePositionForDemoTo(key, lpB, SQRT_2_X96);
        assertEq(paid, expectedPayout);
        assertEq(token0.balanceOf(lpB) - beforeBalance, expectedPayout);

        bytes32 ownerOnlyKey =
            hook.recordPositionForDemo(lpA, -60, 60, keccak256("owner-only-settle"), Q96, 1_000_000, 1 ether, 0);
        vm.prank(lpA);
        vm.expectRevert(TimeWeightedILSmoothingHook.OnlyOwner.selector);
        hook.settlePositionForDemoTo(ownerOnlyKey, lpB, SQRT_2_X96);

        vm.expectRevert(TimeWeightedILSmoothingHook.InvalidPosition.selector);
        hook.settlePositionForDemoTo(key, lpB, SQRT_2_X96);
    }

    function testReserveShareBranches() external {
        TestableTimeWeightedILSmoothingHook freshHook = new TestableTimeWeightedILSmoothingHook(
            IPoolManager(address(0xBEEF)), address(token0), address(adapter), _demoConfig()
        );
        token0.approve(address(freshHook), type(uint256).max);

        bytes32 keyA = freshHook.recordPositionForDemo(lpA, -60, 60, keccak256("share-a"), Q96, 1_000_000, 1 ether, 0);
        freshHook.fundReserve(100 ether);
        bytes32 keyB = freshHook.recordPositionForDemo(lpB, -60, 60, keccak256("share-b"), Q96, 1_000_000, 1 ether, 0);

        (,,,,, uint256 sharesA,,,,) = freshHook.positions(keyA);
        (,,,,, uint256 sharesB,,,,) = freshHook.positions(keyB);
        assertGt(sharesA, sharesB);

        ITimeWeightedILSmoothingHook.ReserveState memory forcedReserve =
            ITimeWeightedILSmoothingHook.ReserveState(100 ether, 0, 1, block.timestamp, 0);
        freshHook.exposedSetReserveState(forcedReserve);

        vm.warp(block.timestamp + 13 hours);
        vm.prank(lpA);
        freshHook.settlePositionForDemo(keyA, SQRT_2_X96);
        (,, uint256 totalShares,,) = freshHook.reserve();
        assertEq(totalShares, 0);
    }

    function testZeroShareAndMorphoNoOpBranches() external {
        TestableTimeWeightedILSmoothingHook freshHook = new TestableTimeWeightedILSmoothingHook(
            IPoolManager(address(mockPoolManager)), address(token0), address(adapter), _demoConfig()
        );
        freshHook.exposedSetReserveState(ITimeWeightedILSmoothingHook.ReserveState(100 ether, 0, 1, 0, 0));
        bytes32 key = freshHook.recordPositionForDemo(lpA, -60, 60, keccak256("zero-share"), Q96, 1_000_000, 1, 0);
        (,,,,, uint256 shares,,,,) = freshHook.positions(key);
        assertEq(shares, 1);

        freshHook.exposedWithdrawFromMorpho(0);
        freshHook.exposedSetReserveState(ITimeWeightedILSmoothingHook.ReserveState(100 ether, 0, 1, 0, 0));
        freshHook.exposedWithdrawFromMorpho(1 ether);

        TestableTimeWeightedILSmoothingHook noAdapterHook = new TestableTimeWeightedILSmoothingHook(
            IPoolManager(address(mockPoolManager)), address(token0), address(0), _demoConfig()
        );
        noAdapterHook.rebalanceMorpho(1 ether);
        noAdapterHook.rebalanceMorpho(0);
        noAdapterHook.exposedSetReserveState(ITimeWeightedILSmoothingHook.ReserveState(1 ether, 1 ether, 1 ether, 0, 0));
        noAdapterHook.exposedWithdrawFromMorpho(1 ether);
    }

    function testMorphoDepositAndWithdrawOnPayout() external {
        hook.rebalanceMorpho(9_900 ether);
        (uint256 totalBalance, uint256 morphoDeposited,,,) = hook.reserve();
        assertEq(totalBalance, 10_000 ether);
        assertEq(morphoDeposited, 9_900 ether);

        bytes32 key = _record(lpA, 10_000 ether);
        vm.warp(block.timestamp + 13 hours);

        vm.prank(lpA);
        hook.settlePositionForDemo(key, SQRT_2_X96);
        (, uint256 afterMorphoDeposited,,,) = hook.reserve();
        assertLt(afterMorphoDeposited, morphoDeposited);
    }

    function testFundReserveRejectsZeroAmount() external {
        vm.expectRevert(TimeWeightedILSmoothingHook.InvalidAmount.selector);
        hook.fundReserve(0);
    }

    function testAdapterAndTokenFailureBranches() external {
        ConfigurableToken badToken = new ConfigurableToken();
        IMorphoBlue.MarketParams memory market =
            IMorphoBlue.MarketParams(address(badToken), address(0), address(0), address(0), 0);
        MorphoAdapter badAdapter = new MorphoAdapter(IERC20Minimal(address(badToken)), morpho, market);

        vm.expectRevert(MorphoAdapter.InvalidAmount.selector);
        badAdapter.deposit(0);
        vm.expectRevert(MorphoAdapter.InvalidAmount.selector);
        badAdapter.withdraw(0, address(this));

        badToken.mint(address(this), 10 ether);
        badToken.approve(address(badAdapter), type(uint256).max);
        badToken.setReturnValues(true, true, false);
        vm.expectRevert(MorphoAdapter.TransferFailed.selector);
        badAdapter.deposit(1 ether);

        badToken.setReturnValues(false, true, true);
        vm.expectRevert(MorphoAdapter.TransferFailed.selector);
        badAdapter.deposit(1 ether);

        TestableTimeWeightedILSmoothingHook badTransferFromHook = new TestableTimeWeightedILSmoothingHook(
            IPoolManager(address(mockPoolManager)), address(badToken), address(adapter), _demoConfig()
        );
        badToken.setReturnValues(true, true, false);
        vm.expectRevert(TimeWeightedILSmoothingHook.TransferFailed.selector);
        badTransferFromHook.fundReserve(1 ether);

        TestableTimeWeightedILSmoothingHook badApproveHook = new TestableTimeWeightedILSmoothingHook(
            IPoolManager(address(mockPoolManager)), address(badToken), address(adapter), _demoConfig()
        );
        badApproveHook.exposedSetReserveState(ITimeWeightedILSmoothingHook.ReserveState(1 ether, 0, 1, 0, 0));
        badToken.setReturnValues(false, true, true);
        vm.expectRevert(TimeWeightedILSmoothingHook.TransferFailed.selector);
        badApproveHook.rebalanceMorpho(1 ether);

        TestableTimeWeightedILSmoothingHook badTransferHook = new TestableTimeWeightedILSmoothingHook(
            IPoolManager(address(mockPoolManager)), address(badToken), address(adapter), _demoConfig()
        );
        badToken.mint(address(badTransferHook), 100 ether);
        badTransferHook.exposedSetReserveState(ITimeWeightedILSmoothingHook.ReserveState(100 ether, 0, 100 ether, 0, 0));
        bytes32 key =
            badTransferHook.recordPositionForDemo(lpA, -60, 60, keccak256("bad-transfer"), Q96, 1_000_000, 1 ether, 0);
        vm.warp(block.timestamp + 13 hours);
        badToken.setReturnValues(true, false, true);
        vm.prank(lpA);
        vm.expectRevert(TimeWeightedILSmoothingHook.TransferFailed.selector);
        badTransferHook.settlePositionForDemo(key, SQRT_2_X96);
    }

    function testMorphoAdapterNoReturnAndRevertBranches() external {
        TestableTimeWeightedILSmoothingHook noReturnHook = new TestableTimeWeightedILSmoothingHook(
            IPoolManager(address(mockPoolManager)), address(token0), address(new NoReturnAdapter()), _demoConfig()
        );
        token0.approve(address(noReturnHook), type(uint256).max);
        noReturnHook.fundReserve(100 ether);
        noReturnHook.rebalanceMorpho(1 ether);
        (, uint256 morphoDeposited,,,) = noReturnHook.reserve();
        assertEq(morphoDeposited, 1 ether);

        bytes32 key =
            noReturnHook.recordPositionForDemo(lpA, -60, 60, keccak256("no-return"), Q96, 1_000_000, 100 ether, 0);
        noReturnHook.exposedSetReserveState(
            ITimeWeightedILSmoothingHook.ReserveState(1 ether, 1 ether, 100 ether, 0, 0)
        );
        token0.mint(address(noReturnHook), 100 ether);
        vm.warp(block.timestamp + 13 hours);
        vm.prank(lpA);
        noReturnHook.settlePositionForDemo(key, SQRT_2_X96);
        (, morphoDeposited,,,) = noReturnHook.reserve();
        assertEq(morphoDeposited, 0);

        TestableTimeWeightedILSmoothingHook revertingDepositHook = new TestableTimeWeightedILSmoothingHook(
            IPoolManager(address(mockPoolManager)), address(token0), address(new RevertingAdapter()), _demoConfig()
        );
        token0.approve(address(revertingDepositHook), type(uint256).max);
        revertingDepositHook.fundReserve(100 ether);
        vm.expectRevert(TimeWeightedILSmoothingHook.TransferFailed.selector);
        revertingDepositHook.rebalanceMorpho(1 ether);

        TestableTimeWeightedILSmoothingHook revertingWithdrawHook = new TestableTimeWeightedILSmoothingHook(
            IPoolManager(address(mockPoolManager)), address(token0), address(new RevertingAdapter()), _demoConfig()
        );
        token0.approve(address(revertingWithdrawHook), type(uint256).max);
        revertingWithdrawHook.fundReserve(100 ether);
        bytes32 revertingKey = revertingWithdrawHook.recordPositionForDemo(
            lpB, -60, 60, keccak256("reverting-withdraw"), Q96, 1_000_000, 100 ether, 0
        );
        revertingWithdrawHook.exposedSetReserveState(
            ITimeWeightedILSmoothingHook.ReserveState(1 ether, 1 ether, 100 ether, 0, 0)
        );
        token0.mint(address(revertingWithdrawHook), 100 ether);
        vm.prank(lpB);
        revertingWithdrawHook.settlePositionForDemo(revertingKey, SQRT_2_X96);
        (, morphoDeposited,,,) = revertingWithdrawHook.reserve();
        assertEq(morphoDeposited, 1 ether);
    }

    function testPositionAndSettlementInvalidPaths() external {
        bytes32 missing = keccak256("missing");
        assertEq(hook.computeSmoothingFactor(missing), 0);
        (uint256 totalIL, uint256 requested, uint256 actualPayout, uint256 factor) =
            hook.previewPayout(missing, SQRT_2_X96);
        assertEq(totalIL, 0);
        assertEq(requested, 0);
        assertEq(actualPayout, 0);
        assertEq(factor, 0);

        vm.expectRevert(TimeWeightedILSmoothingHook.InvalidPosition.selector);
        hook.settlePositionForDemo(missing, SQRT_2_X96);

        vm.expectRevert(TimeWeightedILSmoothingHook.InvalidPosition.selector);
        hook.recordPositionForDemo(address(0), -60, 60, keccak256("bad"), Q96, 1, 1 ether, 0);

        vm.expectRevert(TimeWeightedILSmoothingHook.InvalidPosition.selector);
        hook.recordPositionForDemo(lpA, -60, 60, keccak256("bad-price"), 0, 1, 1 ether, 0);

        vm.expectRevert(TimeWeightedILSmoothingHook.InvalidPosition.selector);
        hook.recordPositionForDemo(lpA, -60, 60, keccak256("bad-liq"), Q96, 0, 1 ether, 0);
    }

    function testReactiveRequestGuards() external {
        bytes32 key = _record(lpA, 1_000 ether);
        vm.expectRevert(TimeWeightedILSmoothingHook.ReactiveNotConfigured.selector);
        hook.requestReactiveSettlement(bytes32(0), key, lpA, SQRT_2_X96, block.timestamp + 1);

        hook.configureReactive(address(callbackProxy), rvmSender);

        vm.expectRevert(TimeWeightedILSmoothingHook.InvalidPosition.selector);
        hook.requestReactiveSettlement(bytes32(0), key, address(0), SQRT_2_X96, block.timestamp + 1);

        vm.expectRevert(TimeWeightedILSmoothingHook.InvalidPosition.selector);
        hook.requestReactiveSettlement(bytes32(0), key, lpA, 0, block.timestamp + 1);

        bytes memory payload = abi.encodeWithSignature(
            "settlePositionFromReactive(address,bytes32,address,uint160)", rvmSender, key, address(0), SQRT_2_X96
        );
        vm.expectRevert(TimeWeightedILSmoothingHook.InvalidPosition.selector);
        callbackProxy.forward(address(hook), payload);
    }

    function testHookCallbackHarnesses() external {
        PoolKey memory key = _poolKey();
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1_000_000, salt: keccak256("cb")});

        hook.exposedAfterAddLiquidity(
            address(0xCAFE), key, params, toBalanceDelta(-100 ether, -5 ether), abi.encode(lpB)
        );
        bytes32 posKey = hook.positionKey(lpB, -60, 60, keccak256("cb"));
        (,,,,,,,,, bool active) = hook.positions(posKey);
        assertTrue(active);

        hook.exposedAfterSwap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: Q96}),
            toBalanceDelta(-1 ether, 2 ether),
            ""
        );
        (uint256 reserveBalance,,,,) = hook.reserve();
        assertGt(reserveBalance, 10_000 ether);

        mockPoolManager.setSlot0(SQRT_2_X96, 0, 0, 3_000);
        vm.warp(block.timestamp + 13 hours);
        hook.exposedBeforeRemoveLiquidity(address(0xCAFE), key, params, abi.encode(lpB));
        (,,,,,,,,, bool activeAfter) = hook.positions(posKey);
        assertFalse(activeAfter);

        ModifyLiquidityParams memory zeroParams = params;
        zeroParams.liquidityDelta = 0;
        hook.exposedAfterAddLiquidity(address(0xCAFE), key, zeroParams, toBalanceDelta(0, 0), "");
    }

    function testSyncYieldAndIdleReserveBranches() external {
        hook.syncMorphoYield(1 ether);
        (uint256 reserveBalance, uint256 morphoDeposited,,, uint256 accruedYield) = hook.reserve();
        assertEq(morphoDeposited, 1 ether);
        assertEq(accruedYield, 1 ether);
        assertEq(reserveBalance, 10_001 ether);

        hook.rebalanceMorpho(10_000 ether);
        (reserveBalance, morphoDeposited,,,) = hook.reserve();
        assertEq(reserveBalance, 10_001 ether);
        assertGt(morphoDeposited, 1 ether);

        vm.expectRevert(TimeWeightedILSmoothingHook.InvalidAmount.selector);
        hook.rebalanceMorpho(1);

        hook.syncMorphoYield(1);
        (, morphoDeposited,,,) = hook.reserve();
        assertEq(morphoDeposited, 1);
    }

    function testFuzzPayoutNeverExceedsReserve(uint128 deposit, uint64 tenure) external {
        deposit = uint128(bound(deposit, 1 ether, 1_000_000 ether));
        tenure = uint64(bound(tenure, 0, 30 days));

        bytes32 key = _record(lpA, deposit);
        vm.warp(block.timestamp + tenure);
        (uint256 reserveBefore,,,,) = hook.reserve();

        vm.prank(lpA);
        uint256 paid = hook.settlePositionForDemo(key, SQRT_2_X96);
        assertLe(paid, reserveBefore);
    }

    function testReactiveSettlementThroughConfiguredProxy() external {
        bytes32 poolId = keccak256("real-uniswap-v4-pool-id");
        bytes32 key = _record(lpA, 1_000 ether);
        vm.warp(block.timestamp + 13 hours);
        hook.configureReactive(address(callbackProxy), rvmSender);

        hook.requestReactiveSettlement(poolId, key, lpA, SQRT_2_X96, block.timestamp + 1 hours);
        (,, uint256 expectedPayout,) = hook.previewPayout(key, SQRT_2_X96);

        bytes memory payload = abi.encodeWithSignature(
            "settlePositionFromReactive(address,bytes32,address,uint160)", rvmSender, key, lpA, SQRT_2_X96
        );
        bytes memory result = callbackProxy.forward(address(hook), payload);
        uint256 paid = abi.decode(result, (uint256));
        assertEq(paid, expectedPayout);
        (,,,,,,,,, bool active) = hook.positions(key);
        assertFalse(active);
    }

    function testReactiveSettlementRejectsWrongProxy() external {
        bytes32 key = _record(lpA, 1_000 ether);
        vm.warp(block.timestamp + 13 hours);
        hook.configureReactive(address(callbackProxy), rvmSender);

        vm.expectRevert(TimeWeightedILSmoothingHook.NotReactiveCallback.selector);
        hook.settlePositionFromReactive(rvmSender, key, lpA, SQRT_2_X96);
    }

    function testReactiveSettlementRejectsWrongRvmSender() external {
        bytes32 key = _record(lpA, 1_000 ether);
        vm.warp(block.timestamp + 13 hours);
        hook.configureReactive(address(callbackProxy), rvmSender);

        bytes memory payload = abi.encodeWithSignature(
            "settlePositionFromReactive(address,bytes32,address,uint160)", address(0xBAD), key, lpA, SQRT_2_X96
        );
        vm.expectRevert(TimeWeightedILSmoothingHook.InvalidReactiveSender.selector);
        callbackProxy.forward(address(hook), payload);
    }

    function testRscQueuesCallbackForConfiguredPoolId() external {
        bytes32 poolId = keccak256("real-uniswap-v4-pool-id");
        bytes32 key = _record(lpA, 1_000 ether);
        TimeWeightedILSmoothingRSC rsc = new TimeWeightedILSmoothingRSC(
            address(0x0000000000000000000000000000000000fffFfF),
            block.chainid,
            block.chainid,
            address(hook),
            poolId,
            REACTIVE_SETTLEMENT_TOPIC0,
            1_000_000,
            rvmSender
        );

        IReactive.LogRecord memory record = IReactive.LogRecord({
            chain_id: block.chainid,
            _contract: address(hook),
            topic_0: REACTIVE_SETTLEMENT_TOPIC0,
            topic_1: uint256(poolId),
            topic_2: uint256(key),
            topic_3: uint256(uint160(lpA)),
            data: abi.encode(SQRT_2_X96, block.timestamp + 1 hours),
            block_number: block.number,
            op_code: 0,
            block_hash: uint256(blockhash(block.number - 1)),
            tx_hash: uint256(keccak256("origin-tx")),
            log_index: 0
        });

        vm.recordLogs();
        record.topic_1 = uint256(keccak256("wrong-pool"));
        rsc.react(record);
        assertEq(vm.getRecordedLogs().length, 0);

        vm.recordLogs();
        record.topic_1 = uint256(poolId);
        rsc.react(record);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 callbackTopic = keccak256("Callback(uint256,address,uint64,bytes)");
        bytes memory expectedPayload = abi.encodeWithSignature(
            "settlePositionFromReactive(address,bytes32,address,uint160)", rvmSender, key, lpA, SQRT_2_X96
        );
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == callbackTopic) {
                bytes memory payload = abi.decode(logs[i].data, (bytes));
                assertEq(payload, expectedPayload);
                found = true;
            }
        }
        assertTrue(found);
    }

    function testRscConfigureAndIgnoreBranches() external {
        TimeWeightedILSmoothingRSC rsc = new TimeWeightedILSmoothingRSC(
            address(0x0000000000000000000000000000000000fffFfF),
            block.chainid,
            block.chainid,
            address(hook),
            bytes32(0),
            REACTIVE_SETTLEMENT_TOPIC0,
            0,
            address(0)
        );
        assertEq(rsc.CALLBACK_GAS_LIMIT(), 1_000_000);
        assertEq(rsc.CALLBACK_SENDER(), address(this));
        assertTrue(rsc.configureSubscription());

        TimeWeightedILSmoothingRSC failingRsc = new TimeWeightedILSmoothingRSC(
            address(new RevertingSystemContract()),
            block.chainid,
            block.chainid,
            address(hook),
            bytes32(0),
            REACTIVE_SETTLEMENT_TOPIC0,
            0,
            address(0)
        );
        assertFalse(failingRsc.configureSubscription());

        IReactive.LogRecord memory record =
            _logRecord(address(hook), REACTIVE_SETTLEMENT_TOPIC0, bytes32(0), bytes32("rsc"), lpA, block.timestamp + 1);

        vm.recordLogs();
        record.chain_id = block.chainid + 1;
        rsc.react(record);
        assertEq(vm.getRecordedLogs().length, 0);

        vm.recordLogs();
        record.chain_id = block.chainid;
        record._contract = address(0xBAD);
        rsc.react(record);
        assertEq(vm.getRecordedLogs().length, 0);

        vm.recordLogs();
        record._contract = address(hook);
        record.topic_0 = uint256(keccak256("Wrong()"));
        rsc.react(record);
        assertEq(vm.getRecordedLogs().length, 0);

        vm.recordLogs();
        record.topic_0 = REACTIVE_SETTLEMENT_TOPIC0;
        vm.warp(100);
        record.data = abi.encode(SQRT_2_X96, uint256(99));
        rsc.react(record);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testRscConstructorConfiguresWhenSystemContractExists() external {
        address system = address(0x0000000000000000000000000000000000fffFfF);
        MockSystemContract mockSystem = new MockSystemContract();
        vm.etch(system, address(mockSystem).code);

        TimeWeightedILSmoothingRSC rsc = new TimeWeightedILSmoothingRSC(
            system,
            block.chainid,
            block.chainid,
            address(hook),
            keccak256("pool"),
            REACTIVE_SETTLEMENT_TOPIC0,
            1,
            rvmSender
        );
        assertTrue(rsc.subscriptionConfigured());
    }

    function testTenureValidateHarness() external {
        TenureHarness harness = new TenureHarness();
        TenureLib.TierConfig memory config = TenureLib.TierConfig(1, 2, 3, 0, 1, 2, 3, 4);
        harness.validate(config);

        config.tier0Duration = 2;
        vm.expectRevert(TenureLib.InvalidTierConfig.selector);
        harness.validate(config);

        config = TenureLib.TierConfig(1, 2, 2, 0, 1, 2, 3, 4);
        vm.expectRevert(TenureLib.InvalidTierConfig.selector);
        harness.validate(config);

        config = TenureLib.TierConfig(1, 2, 3, 0, 1, 2, 10_001, 4);
        vm.expectRevert(TenureLib.InvalidTierConfig.selector);
        harness.validate(config);
    }

    function _record(address lp, uint256 depositAmount0) internal returns (bytes32) {
        return hook.recordPositionForDemo(
            lp, -60, 60, keccak256(abi.encode(lp, depositAmount0)), Q96, 1_000_000, depositAmount0, 0
        );
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token0)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _logRecord(
        address origin,
        uint256 topic0,
        bytes32 poolId,
        bytes32 positionKey_,
        address recipient,
        uint256 deadline
    ) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: block.chainid,
            _contract: origin,
            topic_0: topic0,
            topic_1: uint256(poolId),
            topic_2: uint256(positionKey_),
            topic_3: uint256(uint160(recipient)),
            data: abi.encode(SQRT_2_X96, deadline),
            block_number: block.number,
            op_code: 0,
            block_hash: uint256(blockhash(block.number - 1)),
            tx_hash: uint256(keccak256("origin-tx")),
            log_index: 0
        });
    }

    function _demoConfig() internal pure returns (ITimeWeightedILSmoothingHook.TierConfig memory) {
        return ITimeWeightedILSmoothingHook.TierConfig({
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
}
