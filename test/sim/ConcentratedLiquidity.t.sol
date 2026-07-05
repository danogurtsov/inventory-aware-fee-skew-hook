// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SkewSim} from "./SkewSim.sol";
import {Inventory} from "../../src/libraries/Inventory.sol";
import {SkewCurve} from "../../src/libraries/SkewCurve.sol";

/// @notice Concentration variant: real LPs are not spread over the full range, they concentrate, and
///         concentration amplifies inventory risk (a given price move is a larger fraction of a
///         tighter position, and the inventory signal saturates faster). Re-runs the comparison with a
///         narrow range so the wide-range figures are treated as a floor, not the whole story.
contract ConcentratedLiquidityTest is SkewSim {
    Market internal _mkt;
    uint256 internal constant SEEDS = 3;

    // A tight LP range; the inventory config matches it so the signal is scaled to the position.
    int24 internal constant LO = -900;
    int24 internal constant HI = 900;

    function market() internal view override returns (Market memory) {
        return _mkt;
    }

    function _narrow() internal {
        _mkt = Market({
            startTick: 0,
            stepTicks: 12,
            driftTicks: 0,
            liquidity: 1e23,
            tickLower: LO,
            tickUpper: HI,
            blocks: 90,
            retailBase: 5e20,
            retailChokeFee: 12000
        });
    }

    function _invCfg() internal pure returns (Inventory.Config memory) {
        return Inventory.Config({tickLower: LO, tickUpper: HI, targetToken0Wad: 0.5e18});
    }

    function _meanNetBps() internal returns (int256 acc) {
        for (uint256 s = 1; s <= SEEDS; s++) {
            acc += _run(s * 41).lpNetAnnualBps;
        }
        // safe: SEEDS is a small positive constant.
        // forge-lint: disable-next-line(unsafe-typecast)
        acc /= int256(SEEDS);
    }

    function test_concentrationDoesNotBreakTheSkew() public {
        _narrow();

        _useStatic(3000);
        int256 stat = _meanNetBps();

        _useDirectional(
            SkewCurve.Params({baseFee: 3000, minFee: 100, maxFee: 10_000, slope: 75, volSlope: 0})
        );
        int256 dir = _meanNetBps();

        _useSkew(
            _invCfg(),
            SkewCurve.Params({baseFee: 3000, minFee: 100, maxFee: 10_000, slope: 40_000, volSlope: 0})
        );
        int256 inv = _meanNetBps();

        emit log_named_int("narrow static  net (annual bps)", stat);
        emit log_named_int("narrow direct  net (annual bps)", dir);
        emit log_named_int("narrow invskew net (annual bps)", inv);

        // Under concentration the inventory skew still does not break the LP: it stays on the right
        // side of the best static. (Concentration mainly scales magnitudes; it does not rescue the
        // small absolute edge — that honest picture is what RESULTS reports.)
        assertGe(inv, stat, "invskew >= static under concentration");
    }
}
