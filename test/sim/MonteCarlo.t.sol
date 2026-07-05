// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SkewSim} from "./SkewSim.sol";
import {Inventory} from "../../src/libraries/Inventory.sol";
import {SkewCurve} from "../../src/libraries/SkewCurve.sol";
import {Metrics} from "./harness/Metrics.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

/// @notice Monte Carlo with confidence intervals: one seed is not evidence. Runs the paired
///         inventory-minus-directional LP-net difference over many seeds in the efficient random-walk
///         regime and reports mean, standard error and the 95% CI. The honest outcome: the edge
///         *leans* to inventory (positive mean, wins the majority of paths) but is **small and within
///         noise** at feasible sample sizes — the CI includes zero. This is the point of running MC:
///         it deflates the flattering single-seed number that commit 19 happened to draw, and forces
///         RESULTS to report a small, not-significant edge rather than a win.
contract MonteCarloTest is SkewSim {
    Market internal _mkt;
    uint256 internal constant N = 10; // seeds

    function market() internal view override returns (Market memory) {
        return _mkt;
    }

    function _walk() internal {
        _mkt = Market({
            startTick: 0,
            stepTicks: 14,
            driftTicks: 0, // efficient random walk: last move does not predict the next
            liquidity: 1e23,
            tickLower: -60_000,
            tickUpper: 60_000,
            blocks: 80,
            retailBase: 5e20,
            retailChokeFee: 12000
        });
    }

    function _invCfg() internal pure returns (Inventory.Config memory) {
        return Inventory.Config({tickLower: -60_000, tickUpper: 60_000, targetToken0Wad: 0.5e18});
    }

    function _skewCurve() internal pure returns (SkewCurve.Params memory) {
        return SkewCurve.Params({baseFee: 3000, minFee: 100, maxFee: 10_000, slope: 40_000, volSlope: 0});
    }

    function _dirCurve() internal pure returns (SkewCurve.Params memory) {
        return SkewCurve.Params({baseFee: 3000, minFee: 100, maxFee: 10_000, slope: 75, volSlope: 0});
    }

    function test_inventoryEdgeIsPositiveButWithinNoise() public {
        _walk();

        int256 sum;
        uint256 sumSq;
        int256 wins;
        for (uint256 s = 1; s <= N; s++) {
            uint256 seed = s * 1009;

            _useSkew(_invCfg(), _skewCurve());
            int256 invNet = _run(seed).lpNetWad;

            _useDirectional(_dirCurve());
            int256 dirNet = _run(seed).lpNetWad;

            int256 d = invNet - dirNet; // paired difference on an identical path
            sum += d;
            // safe: |d| is a bounded LP-net difference; its square stays far under 2**256.
            // forge-lint: disable-next-line(unsafe-typecast)
            sumSq += uint256(d * d);
            if (d > 0) wins += 1;
        }

        // safe: N is a small positive constant.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 mean = sum / int256(N);
        uint256 variance = Metrics.variance(N, sum, sumSq);
        uint256 sd = FixedPointMathLib.sqrt(variance);
        uint256 stderr = sd / FixedPointMathLib.sqrt(N);
        // safe: mean is a bounded LP-net difference, exact within int256/uint256 here.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 ciLow = mean - int256(2 * stderr);

        emit log_named_int("mean inv-dir (wad)", mean);
        emit log_named_uint("stderr (wad)", stderr);
        emit log_named_int("95% CI low (wad)", ciLow);
        emit log_named_int("seeds where inv > dir", wins);

        // Honest, reproducible facts on these seeds: the point estimate favors inventory and it wins
        // the majority of paths...
        assertGt(mean, int256(0), "point estimate favors inventory");
        // safe: N/2 is a small positive constant.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertGe(wins, int256(N / 2), "inventory wins at least half the paths");

        // ...but the edge is NOT statistically significant: the 95% CI includes zero. We assert this
        // explicitly so the result is not quietly overstated — RESULTS must report a small, noisy edge.
        assertLe(ciLow, int256(0), "edge is within noise (CI includes zero) at this sample size");
    }
}
