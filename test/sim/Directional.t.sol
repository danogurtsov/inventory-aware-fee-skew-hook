// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SkewSim} from "./SkewSim.sol";
import {SkewCurve} from "../../src/libraries/SkewCurve.sol";

/// @notice The directional (Nezlobin) baseline: a fee skewed by the *last observed* price move. It is
///         the closest prior art to this hook, and the key opponent — it leans the same asymmetric
///         fee, but off a backward-looking price-direction signal instead of the lag-free inventory
///         state. This commit establishes that it runs and skews correctly; the head-to-head against
///         the inventory signal is the next commit.
contract DirectionalTest is SkewSim {
    Market internal _mkt;

    function market() internal view override returns (Market memory) {
        return _mkt;
    }

    function _trendMarket() internal {
        _mkt = Market({
            startTick: 0,
            stepTicks: 8,
            driftTicks: 5, // a persistent up-trend: the directional signal should point up
            liquidity: 1e23,
            tickLower: -60_000,
            tickUpper: 60_000,
            blocks: 150,
            retailBase: 5e20,
            retailChokeFee: 12000
        });
    }

    function _dirCurve() internal pure returns (SkewCurve.Params memory) {
        // c = 75 pips of skew per tick of last move (Nezlobin used c ~ 0.75 of prior block impact).
        return SkewCurve.Params({baseFee: 3000, minFee: 100, maxFee: 10_000, slope: 75, volSlope: 0});
    }

    function test_directionalProducesValidMetrics() public {
        _trendMarket();
        _useDirectional(_dirCurve());
        RunResult memory r = _run(1);

        assertGt(r.lpCapitalWad, 0, "capital positive");
        assertEq(r.lvrWad, int256(r.feeValueWad) - r.lpNetWad, "identity holds under directional");
        assertGe(r.avgFeePips, 100);
        assertLe(r.avgFeePips, 10_000);
    }

    function test_directionalDiffersFromStatic() public {
        _trendMarket();

        _useStatic(3000);
        RunResult memory stat = _run(2);

        _useDirectional(_dirCurve());
        RunResult memory dir = _run(2);

        // The directional skew is genuinely active: it changes the LP outcome versus a matched static.
        assertTrue(dir.lpNetWad != stat.lpNetWad, "directional fee is active");
    }
}
