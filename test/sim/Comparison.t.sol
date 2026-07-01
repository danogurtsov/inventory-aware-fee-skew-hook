// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SkewSim} from "./SkewSim.sol";
import {Inventory} from "../../src/libraries/Inventory.sol";
import {SkewCurve} from "../../src/libraries/SkewCurve.sol";
import {Metrics} from "./harness/Metrics.sol";

/// @notice The central research question: does an inventory-STATE fee (lag-free) beat a directional
///         (Nezlobin) fee (last-move, lagged) and the best static fee? Runs all three over an
///         identical market in two regimes — a persistent trend (where the last move predicts the
///         next, so the directional signal is informative) and an efficient random walk (where the
///         last move is noise, so a backward signal misfires). Mean LP net over a few seeds each.
contract ComparisonTest is SkewSim {
    Market internal _mkt;
    uint256 internal constant SEEDS = 3;

    function market() internal view override returns (Market memory) {
        return _mkt;
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

    // Mean raw LP net (wad) over SEEDS for the currently selected policy. Raw wad keeps the small
    // differences that annualized-bps rounding would erase.
    function _meanNet() internal returns (int256 acc) {
        for (uint256 s = 1; s <= SEEDS; s++) {
            acc += _run(s * 17).lpNetWad;
        }
        // safe: SEEDS is a small positive constant.
        // forge-lint: disable-next-line(unsafe-typecast)
        acc /= int256(SEEDS);
    }

    function _runAllThree(string memory label) internal returns (int256 stat, int256 dir, int256 inv) {
        _useStatic(3000);
        stat = _meanNet();
        _useDirectional(_dirCurve());
        dir = _meanNet();
        _useSkew(_invCfg(), _skewCurve());
        inv = _meanNet();
        emit log_string(label);
        emit log_named_int("  static  net", stat);
        emit log_named_int("  direct  net", dir);
        emit log_named_int("  invskew net", inv);
    }

    function test_compareAcrossRegimes() public {
        // Regime A: persistent trend — the directional signal is informative here.
        _mkt = Market({
            startTick: 0,
            stepTicks: 6,
            driftTicks: 6,
            liquidity: 1e23,
            tickLower: -60_000,
            tickUpper: 60_000,
            blocks: 90,
            retailBase: 5e20,
            retailChokeFee: 12000
        });
        (int256 tStat, int256 tDir, int256 tInv) = _runAllThree("TREND");

        // Regime B: efficient random walk (no drift) — the last move is noise.
        _mkt.driftTicks = 0;
        _mkt.stepTicks = 14;
        (int256 wStat, int256 wDir, int256 wInv) = _runAllThree("RANDOM WALK");

        // (1) The inventory skew never *breaks* the LP: it stays within a hair of the best static in
        //     both regimes (it is price-pinned, so it cannot do large harm or good on its own) and is
        //     marginally on the right side of it.
        assertApproxEqRel(tInv, tStat, 0.05e18, "invskew ~ static in trend");
        assertApproxEqRel(wInv, wStat, 0.05e18, "invskew ~ static in random walk");
        assertGe(tInv, tStat, "invskew >= static in trend");
        assertGe(wInv, wStat, "invskew >= static in random walk");

        // (2) The central signal-vs-signal finding: the lag-free inventory policy beats the lagged
        //     directional (Nezlobin) policy in BOTH regimes, and the gap widens in the efficient
        //     random walk, where the directional fee's backward-looking signal reacts to pure noise.
        assertGe(tInv, tDir, "inventory (lag-free) >= directional (lagged) in trend");
        assertGe(wInv, wDir, "inventory (lag-free) >= directional (lagged) in random walk");
        assertLt(wDir, wStat, "directional underperforms even a static fee on noise (its signal misfires)");
    }
}
