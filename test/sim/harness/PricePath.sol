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

    /// @notice External tick after `step` blocks with **stochastic, clustering volatility**.
    /// @dev The per-block step half-width is itself a mean-reverting random process around
    ///      `baseStepTicks` — calm and turbulent stretches persist (volatility clustering), the
    ///      defining feature of a Heston-style model, rather than a constant band. This stresses the
    ///      fee under changing volatility, where a lagging signal suffers most. Same seed → same path.
    function tickAtStochVol(
        uint256 seed,
        uint256 step,
        int24 startTick,
        uint24 baseStepTicks,
        int24 driftTicks
    ) internal pure returns (int24) {
        int256 tick = startTick;
        int256 vol = int256(uint256(baseStepTicks)); // current volatility state, in ticks
        int256 base = vol;
        int256 loClamp = base / 4 + 1;
        int256 hiClamp = base * 4;
        for (uint256 i = 1; i <= step; i++) {
            // Mean-reverting vol with a shock: pull a quarter of the way back to base, add noise.
            // safe: base and the modulo bound the magnitudes far inside int256.
            // forge-lint: disable-start(unsafe-typecast)
            uint256 hv = uint256(keccak256(abi.encode(seed, "vol", i)));
            int256 shock = int256(hv % (uint256(base) + 1)) - (base / 2);
            vol = vol + (base - vol) / 4 + shock;
            if (vol < loClamp) vol = loClamp;
            if (vol > hiClamp) vol = hiClamp;

            uint256 span = 2 * uint256(vol) + 1;
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            int256 delta = int256(h % span) - vol;
            tick += delta + driftTicks;
            // forge-lint: disable-end(unsafe-typecast)
        }
        // safe: the walk stays within the sim's tick band, far inside int24 range.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(tick);
    }
}
