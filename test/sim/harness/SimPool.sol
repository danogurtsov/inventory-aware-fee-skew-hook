// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title SimPool
/// @notice A fast, self-contained constant-liquidity AMM used by the simulation, driven by the
///         *real* Uniswap v4 swap math (`SwapMath.computeSwapStep`). Within a single active range the
///         liquidity `L` is constant — exactly the v4 model between initialized ticks — so a single
///         `computeSwapStep` is one faithful swap. Using the real curve math (not a re-derived toy)
///         keeps the economics credible, while avoiding the PoolManager's gas cost so Monte Carlo over
///         many seeds is cheap and runs long before any hook exists.
/// @dev Stateful only in `sqrtPriceX96`. It executes swaps and reports amounts/fee; the caller
///      (SimBase) accumulates inventory, fees and LP value. All fees are in *input* token, as in v4.
contract SimPool {
    uint160 public sqrtPriceX96;
    uint128 public immutable liquidity;

    constructor(uint160 startSqrtPriceX96, uint128 liquidity_) {
        sqrtPriceX96 = startSqrtPriceX96;
        liquidity = liquidity_;
    }

    /// @notice Current tick (floor) of the pool price.
    function tick() external view returns (int24) {
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    /// @notice Move the pool price to `targetSqrtPriceX96` at `feePips`, capped by that target.
    /// @dev The rational-arb primitive: the arb pushes price only to the no-arb band edge (the
    ///      caller passes that edge as the target), never past it. Returns the swap it performed.
    /// @return zeroForOne True if the pool sold token0 (price fell).
    /// @return amountIn   Input into the curve (excludes fee), in the input token.
    /// @return amountOut  Output to the trader, in the output token.
    /// @return feeAmount  LP fee taken from the input token.
    function swapToPrice(uint160 targetSqrtPriceX96, uint24 feePips)
        external
        returns (bool zeroForOne, uint256 amountIn, uint256 amountOut, uint256 feeAmount)
    {
        zeroForOne = sqrtPriceX96 >= targetSqrtPriceX96;
        if (sqrtPriceX96 == targetSqrtPriceX96) return (zeroForOne, 0, 0, 0);
        // safe: `_HUGE` (1e36) is far below 2**255; the price target binds before the amount does.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 amountRemaining = -int256(_HUGE);
        uint160 next;
        (next, amountIn, amountOut, feeAmount) =
            SwapMath.computeSwapStep(sqrtPriceX96, targetSqrtPriceX96, liquidity, amountRemaining, feePips);
        sqrtPriceX96 = next;
    }

    /// @notice Exact-input swap of `amountIn` (token0 if `zeroForOne`, else token1) at `feePips`,
    ///         with no price limit. Used by retail flow.
    /// @return usedIn    Input consumed into the curve (excludes fee).
    /// @return amountOut Output to the trader.
    /// @return feeAmount LP fee taken from the input token.
    function swapExactIn(bool zeroForOne, uint256 amountIn, uint24 feePips)
        external
        returns (uint256 usedIn, uint256 amountOut, uint256 feeAmount)
    {
        if (amountIn == 0) return (0, 0, 0);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        // safe: retail `amountIn` in these sims is bounded well under 2**255.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 amountRemaining = -int256(amountIn);
        uint160 next;
        (next, usedIn, amountOut, feeAmount) =
            SwapMath.computeSwapStep(sqrtPriceX96, limit, liquidity, amountRemaining, feePips);
        sqrtPriceX96 = next;
    }

    // A cap far above any single-step input in these sims; the price target binds first.
    uint256 internal constant _HUGE = 1e36;
}
