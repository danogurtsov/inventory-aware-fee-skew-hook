// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {InventoryAwareFeeSkewHook} from "../../src/InventoryAwareFeeSkewHook.sol";
import {Inventory} from "../../src/libraries/Inventory.sol";
import {SkewCurve} from "../../src/libraries/SkewCurve.sol";

/// @notice Wires the hook to a real v4 PoolManager and checks the core promise end-to-end: at a
///         skewed inventory the fee is genuinely different per direction (surcharge the worsening
///         side, discount the rebalancing side), and it is symmetric when the pool sits at target.
contract InventoryAwareFeeSkewHookTest is Test, Deployers {
    InventoryAwareFeeSkewHook internal hook;

    Inventory.Config internal invCfg =
        Inventory.Config({tickLower: -1000, tickUpper: 1000, targetToken0Wad: 0.5e18});
    SkewCurve.Params internal skew =
        SkewCurve.Params({baseFee: 3000, minFee: 100, maxFee: 10_000, slope: 5000, volSlope: 0});

    function _deployHook() internal {
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        bytes memory args = abi.encode(manager, invCfg, skew);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(InventoryAwareFeeSkewHook).creationCode, args);
        hook = new InventoryAwareFeeSkewHook{salt: salt}(manager, invCfg, skew);
        assertEq(address(hook), expected, "mined address mismatch");
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        _deployHook();
    }

    function _initAtTick(int24 tick) internal {
        (key,) = initPoolAndAddLiquidity(
            currency0,
            currency1,
            IHooks(address(hook)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            TickMath.getSqrtPriceAtTick(tick)
        );
    }

    function test_symmetricAtTargetCenter() public {
        _initAtTick(0); // at the 50/50 target -> no skew
        assertEq(hook.currentFee(key, true), skew.baseFee, "symmetric at center (zeroForOne)");
        assertEq(hook.currentFee(key, false), skew.baseFee, "symmetric at center (oneForZero)");
    }

    function test_feeIsAsymmetricWhenSkewed() public {
        _initAtTick(500); // price above center -> excess token1 (imbalance < 0)

        assertLt(hook.currentImbalance(key), int256(0), "excess token1 at a high price");

        // Excess token1: adding token1 (oneForZero) worsens -> surcharge; removing it (zeroForOne)
        // rebalances -> discount.
        uint24 rebalancing = hook.currentFee(key, true);
        uint24 worsening = hook.currentFee(key, false);
        assertLt(rebalancing, skew.baseFee, "rebalancing side discounted");
        assertGt(worsening, skew.baseFee, "worsening side surcharged");
        assertTrue(rebalancing != worsening, "fee differs by direction");
    }

    function test_boundsHoldAtExtremeSkew() public {
        _initAtTick(-900); // near the lower edge -> heavy excess token0
        uint24 z = hook.currentFee(key, true);
        uint24 o = hook.currentFee(key, false);
        assertGe(z, skew.minFee);
        assertLe(z, skew.maxFee);
        assertGe(o, skew.minFee);
        assertLe(o, skew.maxFee);
    }

    function test_initializeRequiresDynamicFee() public {
        vm.expectRevert();
        initPool(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0));
    }
}
