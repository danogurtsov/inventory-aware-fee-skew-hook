// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SkewSim} from "./SkewSim.sol";
import {Inventory} from "../../src/libraries/Inventory.sol";
import {SkewCurve} from "../../src/libraries/SkewCurve.sol";

/// @notice Stresses the mechanism under **clustering (Heston-ish) volatility** — calm and turbulent
///         stretches that persist — instead of a constant band. Changing volatility is exactly where
///         a lagging signal is punished, so it is the fair setting to re-test the inventory-vs-
///         directional finding. Confirms the sign of the result survives realistic vol dynamics.
contract StochasticVolTest is SkewSim {
    Market internal _mkt;
    uint256 internal constant SEEDS = 3;

    function market() internal view override returns (Market memory) {
        return _mkt;
    }

    function _base() internal {
        _mkt = Market({
            startTick: 0,
            stepTicks: 10, // base vol; the stochastic path clusters around it
            driftTicks: 0,
            liquidity: 1e23,
            tickLower: -60_000,
            tickUpper: 60_000,
            blocks: 90,
            retailBase: 5e20,
            retailChokeFee: 12000
        });
        stochVolEnabled = true;
    }

    function _invCfg() internal pure returns (Inventory.Config memory) {
        return Inventory.Config({tickLower: -60_000, tickUpper: 60_000, targetToken0Wad: 0.5e18});
    }

    function _meanNet() internal returns (int256 acc) {
        for (uint256 s = 1; s <= SEEDS; s++) {
            acc += _run(s * 29).lpNetWad;
        }
        // safe: SEEDS is a small positive constant.
        // forge-lint: disable-next-line(unsafe-typecast)
        acc /= int256(SEEDS);
    }

    function test_metricsValidUnderStochVol() public {
        _base();
        _useSkew(
            _invCfg(),
            SkewCurve.Params({baseFee: 3000, minFee: 100, maxFee: 10_000, slope: 40_000, volSlope: 0})
        );
        RunResult memory r = _run(1);
        assertGt(r.lpCapitalWad, 0);
        assertEq(r.lvrWad, int256(r.feeValueWad) - r.lpNetWad, "identity holds under stochastic vol");
    }

    /// @dev Honest boundary of the thesis. Under clustering volatility with no drift, the ordering
    ///      *flips*: the directional (Nezlobin) fee beats the pure inventory skew. Its move-magnitude
    ///      signal implicitly tracks the **volatility regime**, which clusters and therefore persists,
    ///      so its one-block lag costs little — while the pure inventory signal is blind to volatility.
    ///      This is exactly why `SkewCurve` carries a `volSlope` term: a complete design pairs the
    ///      lag-free inventory state with a volatility term. Inventory alone still never breaks the LP
    ///      (it stays >= the best static), but it does not dominate a vol-aware fee here.
    function test_stochVolFavorsVolAwareDirectional() public {
        _base();

        _useStatic(3000);
        int256 stat = _meanNet();

        _useDirectional(
            SkewCurve.Params({baseFee: 3000, minFee: 100, maxFee: 10_000, slope: 75, volSlope: 0})
        );
        int256 dir = _meanNet();

        _useSkew(
            _invCfg(),
            SkewCurve.Params({baseFee: 3000, minFee: 100, maxFee: 10_000, slope: 40_000, volSlope: 0})
        );
        int256 inv = _meanNet();

        emit log_named_int("stochvol static  net", stat);
        emit log_named_int("stochvol direct  net", dir);
        emit log_named_int("stochvol invskew net", inv);

        // Inventory never breaks the LP: still on the right side of the best static.
        assertGe(inv, stat, "inventory >= static under stochastic vol");
        // But under clustering vol the vol-tracking directional signal wins — the honest limit of a
        // vol-blind inventory fee.
        assertGe(dir, inv, "directional (vol-tracking) beats vol-blind inventory under clustering vol");
    }
}
