// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

/// @title Metrics
/// @notice Pure statistics used to turn a run's raw accumulators into the objective figures. Kept
///         separate so the definitions are testable in isolation and reused unchanged across every
///         baseline and the skew mechanism. Raw token figures are meaningless on their own, so every
///         verdict is expressed in **basis points of LP capital** and **annualized** on a 12-second
///         block clock — directly comparable to the market-making literature.
library Metrics {
    /// @dev Ethereum blocks per year at 12s: 365 * 24 * 3600 / 12.
    uint256 internal constant BLOCKS_PER_YEAR = 2_628_000;

    /// @notice Population variance of a signed series from its count, sum and sum-of-squares.
    /// @dev `var = E[x^2] - E[x]^2`, computed in integer arithmetic (a comparison metric, not a
    ///      high-precision statistic). Clamped at zero so rounding can never produce a negative.
    function variance(uint256 n, int256 sum, uint256 sumSq) internal pure returns (uint256) {
        if (n == 0) return 0;
        // safe: n is a positive block count, well within int256; mean*mean is non-negative.
        // forge-lint: disable-start(unsafe-typecast)
        int256 mean = sum / int256(n);
        uint256 meanSq = uint256(mean * mean);
        // forge-lint: disable-end(unsafe-typecast)
        uint256 avgSq = sumSq / n;
        return avgSq > meanSq ? avgSq - meanSq : 0;
    }

    /// @notice Absolute value of a signed integer as a uint.
    function abs(int256 x) internal pure returns (uint256) {
        // safe: negation then cast of a non-positive value is exact within uint256.
        // forge-lint: disable-next-line(unsafe-typecast)
        return x < 0 ? uint256(-x) : uint256(x);
    }

    /// @notice A (signed) WAD value expressed in basis points of `capitalWad`.
    function bpsOfCapital(int256 valueWad, uint256 capitalWad) internal pure returns (int256) {
        if (capitalWad == 0) return 0;
        // safe: capital is a positive sim value bounded far under 2**255.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (valueWad * 10_000) / int256(capitalWad);
    }

    /// @notice Scale a per-run figure measured over `blocks` to a per-year rate (linear in time).
    function annualize(int256 valueWad, uint256 blocks) internal pure returns (int256) {
        if (blocks == 0) return 0;
        // safe: BLOCKS_PER_YEAR and `blocks` are positive counts within int256.
        // forge-lint: disable-start(unsafe-typecast)
        return (valueWad * int256(BLOCKS_PER_YEAR)) / int256(blocks);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @notice Annualized volatility (bps/yr) implied by a per-block uniform step of half-width
    ///         `stepTicks`. A uniform step on [-s, +s] has standard deviation `s/sqrt(3)` ticks, one
    ///         tick is ~1 basis point of price, and volatility scales with the square root of time:
    ///         `annualVolBps = stepTicks * sqrt(BLOCKS_PER_YEAR / 3)`. This is the sanity check that
    ///         keeps the price process calibrated to a realistic asset (a mistake that silently
    ///         inflated the sibling repo's numbers).
    function annualVolBps(uint24 stepTicks) internal pure returns (uint256) {
        return uint256(stepTicks) * FixedPointMathLib.sqrt(BLOCKS_PER_YEAR / 3);
    }
}
