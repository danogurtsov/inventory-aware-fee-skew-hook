// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SimBase} from "./SimBase.sol";
import {Metrics} from "./harness/Metrics.sol";

/// @notice Pins the normalization layer: results are reported in basis points of LP capital and
///         annualized on a 12s clock, and the price process is calibrated to a realistic asset. The
///         volatility sanity check is the guard that stops an accidentally mis-scaled price path from
///         silently inflating every downstream figure (the exact failure the sibling repo hit).
contract NormalizeTest is SimBase {
    Market internal _mkt;

    function market() internal view override returns (Market memory) {
        return _mkt;
    }

    function _base() internal {
        _mkt = Market({
            startTick: 0,
            stepTicks: 10, // ~93% annualized vol — realistic for ETH
            driftTicks: 0,
            liquidity: 1e23,
            tickLower: -60_000,
            tickUpper: 60_000,
            blocks: 200,
            retailBase: 5e20,
            retailChokeFee: 12000
        });
    }

    function test_capitalIsPositiveAndFinite() public {
        _base();
        RunResult memory r = _run(1);
        assertGt(r.lpCapitalWad, 0, "LP capital must be positive");
    }

    function test_bpsAndAnnualAreConsistent() public {
        _base();
        RunResult memory r = _run(1);

        // bps is lpNet re-expressed against capital; annual is bps scaled by year/blocks.
        assertEq(r.lpNetBps, Metrics.bpsOfCapital(r.lpNetWad, r.lpCapitalWad), "bps definition");
        assertEq(r.lpNetAnnualBps, Metrics.annualize(r.lpNetBps, _mkt.blocks), "annual definition");
        // 200 blocks is a tiny slice of a year, so annualizing magnifies the per-run figure.
        assertGt(_absBps(r.lpNetAnnualBps), _absBps(r.lpNetBps), "annualization scales up a short run");
    }

    function test_narrowerRangeIsMoreCapitalConcentrated() public {
        _base();
        RunResult memory wide = _run(2);

        _base();
        _mkt.tickLower = -600;
        _mkt.tickUpper = 600; // same liquidity packed into a 100x tighter range
        RunResult memory narrow = _run(2);

        // The same liquidity over a tighter range is far less capital at risk per unit L, so a given
        // inventory drift is a larger fraction of it — concentration amplifies the LP's exposure.
        assertLt(narrow.lpCapitalWad, wide.lpCapitalWad, "tighter range holds less capital per L");
    }

    // --- volatility sanity: the calibration guard ----------------------------

    function test_volCalibrationIsRealistic() public pure {
        // stepTicks = 10 must land in a believable band for a crypto pair: ~20%..300% per year.
        uint256 volBps = Metrics.annualVolBps(10);
        assertGe(volBps, 2000, "annualized vol too low to be a real crypto asset");
        assertLe(volBps, 30_000, "annualized vol implausibly high (mis-scaled path)");
        // And it is monotone in the step size.
        assertGt(Metrics.annualVolBps(20), volBps, "more step ticks -> more vol");
    }

    function _absBps(int256 x) internal pure returns (uint256) {
        return Metrics.abs(x);
    }
}
