// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";
import {IMorphoBlue} from "../src/interfaces/IMorphoBlue.sol";
import {IERC20Minimal} from "../src/interfaces/IERC20Minimal.sol";
import {ITimeWeightedILSmoothingHook} from "../src/interfaces/ITimeWeightedILSmoothingHook.sol";
import {MorphoAdapter} from "../src/adapters/MorphoAdapter.sol";
import {TimeWeightedILSmoothingHook} from "../src/hooks/TimeWeightedILSmoothingHook.sol";
import {DemoERC20} from "../src/test/DemoERC20.sol";

contract DeployTimeWeightedILSmoothing is Script {
    address internal constant FOUNDRY_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (TimeWeightedILSmoothingHook hook, MorphoAdapter adapter) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address poolManager = _poolManagerForChain();
        address reserveToken = vm.envOr("RESERVE_TOKEN", address(0));
        address morpho = vm.envOr("MORPHO_BLUE", address(0));
        address deployer = vm.addr(privateKey);

        IMorphoBlue.MarketParams memory market = IMorphoBlue.MarketParams({
            loanToken: reserveToken,
            collateralToken: vm.envOr("MORPHO_COLLATERAL_TOKEN", address(0)),
            oracle: vm.envOr("MORPHO_ORACLE", address(0)),
            irm: vm.envOr("MORPHO_IRM", address(0)),
            lltv: vm.envOr("MORPHO_LLTV", uint256(0))
        });

        ITimeWeightedILSmoothingHook.TierConfig memory config = _config();

        vm.startBroadcast(privateKey);
        if (reserveToken == address(0)) {
            DemoERC20 demoToken = new DemoERC20("TimeWeighted Demo USD", "twUSD", 18);
            demoToken.mint(deployer, 1_000_000 ether);
            reserveToken = address(demoToken);
            console2.log("deployed demo reserve token", reserveToken);
        }

        if (reserveToken != address(0) && morpho != address(0)) {
            adapter = new MorphoAdapter(
                // slither-disable-next-line arbitrary-send-erc20
                // forge script deployment; reserve token is operator supplied.
                IERC20Minimal(reserveToken),
                IMorphoBlue(morpho),
                market
            );
        }

        uint160 flags =
            uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs =
            abi.encode(IPoolManager(poolManager), deployer, reserveToken, address(adapter), config);
        (address expectedHook, bytes32 salt) = HookMiner.find(
            FOUNDRY_CREATE2_DEPLOYER, flags, type(TimeWeightedILSmoothingHook).creationCode, constructorArgs
        );

        hook = new TimeWeightedILSmoothingHook{salt: salt}(
            IPoolManager(poolManager), deployer, reserveToken, address(adapter), config
        );
        vm.stopBroadcast();

        require(address(hook) == expectedHook, "hook address mismatch");

        console2.log("TimeWeightedILSmoothing deployment");
        console2.log("chainId", block.chainid);
        console2.log("poolManager", poolManager);
        console2.log("reserveToken", reserveToken);
        console2.log("morphoAdapter", address(adapter));
        console2.log("hook", address(hook));
        console2.log("salt");
        console2.logBytes32(salt);
        console2.log("explorer", _explorerAddress(address(hook)));
    }

    function _config() internal view returns (ITimeWeightedILSmoothingHook.TierConfig memory) {
        bool demo = vm.envOr("DEMO_TIERS", true);
        if (demo) {
            return ITimeWeightedILSmoothingHook.TierConfig(1 hours, 6 hours, 12 hours, 0, 2_500, 5_000, 7_500, 500);
        }
        return ITimeWeightedILSmoothingHook.TierConfig(7 days, 30 days, 90 days, 0, 2_500, 5_000, 7_500, 500);
    }

    function _poolManagerForChain() internal view returns (address) {
        if (block.chainid == 11155111) return vm.envAddress("ETH_SEPOLIA_POOL_MANAGER");
        if (block.chainid == 84532) return vm.envAddress("BASE_SEPOLIA_POOL_MANAGER");
        if (block.chainid == 1301) return vm.envAddress("UNICHAIN_SEPOLIA_POOL_MANAGER");
        return vm.envAddress("POOL_MANAGER");
    }

    function _explorerAddress(address target) internal view returns (string memory) {
        if (block.chainid == 11155111) {
            return string.concat("https://sepolia.etherscan.io/address/", vm.toString(target));
        }
        if (block.chainid == 84532) return string.concat("https://sepolia.basescan.org/address/", vm.toString(target));
        if (block.chainid == 1301) return string.concat("https://sepolia.uniscan.xyz/address/", vm.toString(target));
        return vm.toString(target);
    }
}
