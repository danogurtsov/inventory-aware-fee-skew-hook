// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {InventoryAwareFeeSkewHook} from "../../src/InventoryAwareFeeSkewHook.sol";
import {Inventory} from "../../src/libraries/Inventory.sol";
import {SkewCurve} from "../../src/libraries/SkewCurve.sol";

/// @dev Drives random swaps, retunes and pause toggles against the live pool. Swaps are not wrapped
///      in try/catch: if the hook ever reverts a swap a vanilla pool would accept, the campaign
///      fails — which is exactly the "never breaks a swap" guarantee. The handler is the hook owner,
///      so it can also retune the curve and pause within valid bounds.
contract Handler is Test {
    InventoryAwareFeeSkewHook internal hook;
    PoolSwapTest internal swapRouter;
    PoolKey internal key;

    constructor(InventoryAwareFeeSkewHook hook_, PoolSwapTest router_, PoolKey memory key_) {
        hook = hook_;
        swapRouter = router_;
        key = key_;
    }

    function swap(uint256 amount, bool zeroForOne) external {
        amount = bound(amount, 1e15, 1e20); // small vs the pool's wide, deep liquidity
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        // safe: amount is bounded to [1e15, 1e20], well within int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 specified = -int256(amount);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: specified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function retune(uint256 seed) external {
        uint24 maxFee = uint24(bound(seed, 1000, 100_000));
        uint24 baseFee = uint24(bound(uint256(keccak256(abi.encode(seed, 1))), 1, maxFee));
        uint24 minFee = uint24(bound(uint256(keccak256(abi.encode(seed, 2))), 0, baseFee));
        uint256 slope = bound(uint256(keccak256(abi.encode(seed, 3))), 0, 1_000_000);
        hook.setSkewParams(
            SkewCurve.Params({baseFee: baseFee, minFee: minFee, maxFee: maxFee, slope: slope, volSlope: 0})
        );
    }

    function togglePause() external {
        if (hook.paused()) hook.unpause();
        else hook.pause();
    }
}

/// @notice Safety backbone for the hook before it is plugged into the simulation: over random swaps,
///         retunes and pause toggles, the fee stays within `[minFee, maxFee]` for both directions,
///         pausing is always symmetric, and no swap the pool would accept ever reverts.
contract HookInvariantsTest is Test, Deployers {
    InventoryAwareFeeSkewHook internal hook;
    Handler internal handler;

    Inventory.Config internal invCfg =
        Inventory.Config({tickLower: -60_000, tickUpper: 60_000, targetToken0Wad: 0.5e18});
    SkewCurve.Params internal skew =
        SkewCurve.Params({baseFee: 3000, minFee: 100, maxFee: 10_000, slope: 5000, volSlope: 0});

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Handler is the owner, so it can retune/pause during the campaign.
        handler = Handler(address(0));
        address predictedOwner = _predictHandler();

        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        bytes memory args = abi.encode(manager, predictedOwner, invCfg, skew);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(InventoryAwareFeeSkewHook).creationCode, args);
        hook = new InventoryAwareFeeSkewHook{salt: salt}(manager, predictedOwner, invCfg, skew);
        assertEq(address(hook), expected);

        // Init a dynamic-fee pool and add wide, deep liquidity so swaps never exhaust it.
        (key,) = initPool(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 1e24, salt: 0}),
            ""
        );

        handler = new Handler(hook, swapRouter, key);
        require(address(handler) == predictedOwner, "owner prediction mismatch");

        // Fund the handler and approve the swap router.
        MockERC20(Currency.unwrap(currency0)).mint(address(handler), 1e30);
        MockERC20(Currency.unwrap(currency1)).mint(address(handler), 1e30);
        vm.startPrank(address(handler));
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        targetContract(address(handler));
    }

    /// @dev The handler is deployed after the hook (it needs the hook address), so its address is the
    ///      next CREATE from this contract *after* the hook's CREATE2. Foundry's nonce for `this`
    ///      advances by 1 per CREATE; predict it so the hook can be owned by the handler.
    function _predictHandler() internal view returns (address) {
        return vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
    }

    /// @notice The fee is always within the configured bounds, for both swap directions.
    function invariant_feeWithinBounds() public view {
        SkewCurve.Params memory p = hook.skewParams();
        uint24 z = hook.currentFee(key, true);
        uint24 o = hook.currentFee(key, false);
        assertGe(z, p.minFee);
        assertLe(z, p.maxFee);
        assertGe(o, p.minFee);
        assertLe(o, p.maxFee);
    }

    /// @notice When paused, the fee is symmetric (both directions equal the base fee).
    function invariant_pausedIsSymmetric() public view {
        if (!hook.paused()) return;
        assertEq(hook.currentFee(key, true), hook.currentFee(key, false));
    }
}
