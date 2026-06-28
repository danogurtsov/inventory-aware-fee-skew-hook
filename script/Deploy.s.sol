// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {InventoryAwareFeeSkewHook} from "../src/InventoryAwareFeeSkewHook.sol";
import {Inventory} from "../src/libraries/Inventory.sol";
import {SkewCurve} from "../src/libraries/SkewCurve.sol";

/// @notice Mines a hook address whose low bits encode the permission set (afterInitialize |
///         beforeSwap) and deploys via the canonical CREATE2 deployer.
/// @dev Set POOL_MANAGER (and optionally HOOK_OWNER) in the environment before running. The default
///      curve is an ETH/USDC-style symmetric anchor (0.30% base, 0.01% floor, 1.00% cap) skewed by
///      inventory over a wide range with a 50/50 target.
contract Deploy is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (InventoryAwareFeeSkewHook hook) {
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address owner = vm.envOr("HOOK_OWNER", msg.sender);

        Inventory.Config memory invConfig =
            Inventory.Config({tickLower: -60_000, tickUpper: 60_000, targetToken0Wad: 0.5e18});
        SkewCurve.Params memory skewParams =
            SkewCurve.Params({baseFee: 3000, minFee: 100, maxFee: 10_000, slope: 5000, volSlope: 0});

        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        bytes memory args = abi.encode(poolManager, owner, invConfig, skewParams);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(InventoryAwareFeeSkewHook).creationCode, args);

        vm.startBroadcast();
        hook = new InventoryAwareFeeSkewHook{salt: salt}(poolManager, owner, invConfig, skewParams);
        vm.stopBroadcast();

        require(address(hook) == expected, "hook address mismatch");
        console2.log("InventoryAwareFeeSkewHook deployed:", address(hook));
    }
}
