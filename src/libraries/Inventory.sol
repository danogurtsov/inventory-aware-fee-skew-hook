// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title Inventory
/// @notice Turns a pool's current price into a signed **inventory imbalance** in `[-1, +1]` (WAD),
///         measured against a target token composition. This is the hook's core signal, and the
///         reason the design can react without lag: inventory is the pool's *current state*, read
///         directly from the tick, not an estimate of past volatility or price direction.
/// @dev The imbalance is the token0 share of the position's value relative to a target share, mapped
///      onto `[-1, +1]`:
///        - `+1e18` == the position is entirely token0 (price at/below the lower tick),
///        -  `0`    == the position sits at its target composition,
///        - `-1e18` == the position is entirely token1 (price at/above the upper tick).
///      A single concentrated range `[tickLower, tickUpper]` models the LP; the composition is
///      liquidity-independent (a ratio), so a fixed nominal liquidity is used to evaluate it.
library Inventory {
    error InvalidRange();
    error InvalidTarget();

    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q96 = 1 << 96;
    uint128 internal constant NOMINAL_L = 1e18; // cancels in the value ratio; any positive value works

    /// @param tickLower        Lower bound of the LP range.
    /// @param tickUpper        Upper bound of the LP range.
    /// @param targetToken0Wad  Target token0 share of position value (WAD), exclusive of 0 and 1e18.
    struct Config {
        int24 tickLower;
        int24 tickUpper;
        uint256 targetToken0Wad;
    }

    /// @notice Revert unless the config is a valid range with an interior target.
    function validate(Config memory c) internal pure {
        if (c.tickLower >= c.tickUpper) revert InvalidRange();
        if (c.targetToken0Wad == 0 || c.targetToken0Wad >= WAD) revert InvalidTarget();
    }

    /// @notice Signed inventory imbalance in `[-1e18, +1e18]` for a pool at `currentTick`.
    /// @dev `> 0` means the position holds an excess of token0 versus target (the LP is "long
    ///      token0" and wants to sell it down); `< 0` means an excess of token1. Monotonically
    ///      decreasing in price, and exactly `0` at the target composition.
    function imbalanceWad(int24 currentTick, Config memory c) internal pure returns (int256) {
        // Clamp to the range: outside it the position is single-sided and the imbalance saturates.
        int24 t = currentTick;
        if (t < c.tickLower) t = c.tickLower;
        if (t > c.tickUpper) t = c.tickUpper;

        uint160 sqrtP = TickMath.getSqrtPriceAtTick(t);
        uint160 sqrtL = TickMath.getSqrtPriceAtTick(c.tickLower);
        uint160 sqrtU = TickMath.getSqrtPriceAtTick(c.tickUpper);

        uint256 amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtU, NOMINAL_L, false);
        uint256 amount1 = SqrtPriceMath.getAmount1Delta(sqrtL, sqrtP, NOMINAL_L, false);

        // Value both legs in token1 at the current price, then take token0's value share.
        uint256 priceWad = _priceWad(sqrtP);
        uint256 value0 = FullMath.mulDiv(amount0, priceWad, WAD);
        uint256 total = value0 + amount1;
        if (total == 0) return 0;
        uint256 f0Wad = FullMath.mulDiv(value0, WAD, total); // token0 value share, [0, 1e18]

        // Map the share onto [-1, +1] around the target, saturating at the range ends.
        if (f0Wad >= c.targetToken0Wad) {
            uint256 num = f0Wad - c.targetToken0Wad;
            uint256 den = WAD - c.targetToken0Wad;
            // safe: num <= den <= WAD, so the result is <= 1e18, well within int256.
            // forge-lint: disable-next-line(unsafe-typecast)
            return int256(FullMath.mulDiv(num, WAD, den));
        } else {
            uint256 num = c.targetToken0Wad - f0Wad;
            uint256 den = c.targetToken0Wad;
            // safe: num <= den, so the magnitude is <= 1e18, well within int256.
            // forge-lint: disable-next-line(unsafe-typecast)
            return -int256(FullMath.mulDiv(num, WAD, den));
        }
    }

    /// @dev Price (token1 per token0, WAD) from a sqrt price.
    function _priceWad(uint160 sqrtPX96) private pure returns (uint256) {
        uint256 priceX96 = FullMath.mulDiv(sqrtPX96, sqrtPX96, Q96);
        return FullMath.mulDiv(priceX96, WAD, Q96);
    }
}
