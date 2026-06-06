// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title PricePath
/// @notice Deterministic external-price series in tick space for the inventory simulation.
/// @dev A seeded random walk: each block the "true" market price moves by a bounded random step.
///      `stepTicks` sets volatility — small for calm, large for volatile. The same (seed, stepTicks,
///      startTick) always yields the same path, so a static-fee run and a skew-fee run are compared
///      over an identical market. A drift term lets us build one-directional (toxic) regimes where an
///      LP's inventory steadily skews — the case the fee is meant to defend.
library PricePath {
    /// @notice External tick after `step` blocks, walking from `startTick`.
    /// @param seed       Path seed; distinct seeds are independent Monte Carlo draws.
    /// @param step       Block index (0 returns startTick).
    /// @param startTick  Tick at block 0.
    /// @param stepTicks  Half-width of the per-block uniform step (volatility).
    /// @param driftTicks Deterministic per-block drift added to the walk (0 == symmetric).
    function tickAt(uint256 seed, uint256 step, int24 startTick, uint24 stepTicks, int24 driftTicks)
        internal
        pure
        returns (int24)
    {
        int256 tick = startTick;
        uint256 span = 2 * uint256(stepTicks) + 1;
        for (uint256 i = 1; i <= step; i++) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            // safe: `h % span` < span <= 2*stepTicks+1, well within int256.
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 delta = int256(h % span) - int256(uint256(stepTicks));
            tick += delta + driftTicks;
        }
        // safe: the walk stays within the sim's tick band, far inside int24 range.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(tick);
    }
}
