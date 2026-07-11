// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SkewSim} from "./SkewSim.sol";
import {Inventory} from "../../src/libraries/Inventory.sol";
import {SkewCurve} from "../../src/libraries/SkewCurve.sol";

/// @notice Emits the machine-readable data behind the RESULTS tables and charts. Run with `-vv` and
///         grep the `CSV` lines. The charts deliberately show a *tradeoff* — the skew's effect is
///         small and mixed across regimes, and a slope sweep shows more skew is not monotonically
///         better — rather than a single line going up.
contract ChartDataTest is SkewSim {
    Market internal _mkt;

    function market() internal view override returns (Market memory) {
        return _mkt;
    }

    function _invCfg() internal pure returns (Inventory.Config memory) {
        return Inventory.Config({tickLower: -60_000, tickUpper: 60_000, targetToken0Wad: 0.5e18});
    }

    function _base() internal {
        _mkt = Market({
            startTick: 0,
            stepTicks: 12,
            driftTicks: 0,
            liquidity: 1e23,
            tickLower: -60_000,
            tickUpper: 60_000,
            blocks: 90,
            retailBase: 5e20,
            retailChokeFee: 12000
        });
    }

    /// @dev CSV: regime, static_net, directional_net, inventory_net (raw wad). The data behind the
    ///      cross-regime table — inventory leads on trend/walk, trails under clustering vol.
    function test_chartData_regimes() public {
        emit log_string("CSV regime,static,directional,inventory");

        _base();
        _emitRow("trend", 6);

        _base();
        _mkt.stepTicks = 14;
        _emitRow("random_walk", 0);

        _base();
        stochVolEnabled = true;
        _emitRow("stoch_vol", 0);
    }

    function _emitRow(string memory name, int24 drift) internal {
        _mkt.driftTicks = drift;

        _useStatic(3000);
        int256 s = _run(3).lpNetWad;
        _useDirectional(
            SkewCurve.Params({baseFee: 3000, minFee: 100, maxFee: 10_000, slope: 75, volSlope: 0})
        );
        int256 d = _run(3).lpNetWad;
        _useSkew(
            _invCfg(),
            SkewCurve.Params({baseFee: 3000, minFee: 100, maxFee: 10_000, slope: 40_000, volSlope: 0})
        );
        int256 v = _run(3).lpNetWad;

        emit log_string(string.concat(
                "CSV ", name, ",", vm.toString(s), ",", vm.toString(d), ",", vm.toString(v)
            ));
    }

    /// @dev CSV: slope, inventory_net, avg_fee_pips. A skew-slope sweep — the tradeoff between leaning
    ///      harder on inventory and the fee that costs; it is not monotone, which is the point.
    function test_chartData_slopeSweep() public {
        _base();
        emit log_string("CSV slope,inventory_net,avg_fee_pips");

        uint256[5] memory slopes = [uint256(0), 10_000, 40_000, 120_000, 400_000];
        for (uint256 i = 0; i < slopes.length; i++) {
            _useSkew(
                _invCfg(),
                SkewCurve.Params({baseFee: 3000, minFee: 100, maxFee: 10_000, slope: slopes[i], volSlope: 0})
            );
            RunResult memory r = _run(3);
            emit log_string(string.concat(
                    "CSV ",
                    vm.toString(slopes[i]),
                    ",",
                    vm.toString(r.lpNetWad),
                    ",",
                    vm.toString(r.avgFeePips)
                ));
        }
    }
}
