// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Metrics
/// @notice Pure statistics used to turn a run's raw accumulators into the objective figures. Kept
///         separate so the definitions are testable in isolation and reused unchanged across every
///         baseline and the skew mechanism.
library Metrics {
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
}
