// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SimBase} from "./SimBase.sol";
import {Metrics} from "./harness/Metrics.sol";

/// @notice Exercises the objective metric on a static-fee run: the numbers are finite and sane, the
///         fees-minus-LVR identity holds, and a one-directional (toxic) market drives the LP's
///         inventory and its loss-versus-rebalancing up relative to a symmetric market. This is the
///         ruler every later mechanism is measured against — pinned before any mechanism exists.
contract MetricsTest is SimBase {
    Market internal _mkt;

    function market() internal view override returns (Market memory) {
        return _mkt;
    }

    function _symmetricMarket() internal {
        _mkt = Market({
            startTick: 0,
            stepTicks: 10,
            driftTicks: 0,
            liquidity: 1e23,
            tickLower: -60_000,
            tickUpper: 60_000,
            blocks: 200,
            retailBase: 5e20,
            retailRefFee: 3000
        });
    }

    function _toxicMarket() internal {
        _symmetricMarket();
        _mkt.driftTicks = 8; // steady one-directional pressure -> the LP is run over
    }

    function test_staticBaselineRuns() public {
        _symmetricMarket();
        staticFeePips = 500; // 0.05%
        RunResult memory r = _run(1);

        // Fees were collected, and the fees-minus-LVR identity holds by construction.
        assertGt(r.feeValueWad, 0, "static fee should earn revenue");
        assertEq(r.lvrWad, int256(r.feeValueWad) - r.lpNetWad, "lvr = fees - lpNet");
        assertGe(r.invVarianceWad, 0, "variance is non-negative");
        assertApproxEqAbs(r.avgFeePips, 500, 1, "avg fee tracks the static fee");
    }

    function test_toxicFlowHurtsLP() public {
        staticFeePips = 500;

        _symmetricMarket();
        RunResult memory calm = _run(7);

        _toxicMarket();
        RunResult memory toxic = _run(7);

        // Under one-directional flow the LP ends far more lopsided and loses more to rebalancing.
        assertGt(
            Metrics.abs(toxic.terminalInv0),
            Metrics.abs(calm.terminalInv0),
            "toxic flow leaves the LP holding more inventory"
        );
        assertGt(toxic.lvrWad, calm.lvrWad, "toxic flow raises loss-versus-rebalancing");
    }

    function test_feeRevenueIsNotTheVerdict() public {
        // A higher static fee earns more per trade yet need not improve LP net — the exact trap the
        // sibling repo fell into. We only assert the two are measured separately here.
        _symmetricMarket();

        staticFeePips = 500;
        RunResult memory lowFee = _run(3);

        staticFeePips = 3000;
        RunResult memory highFee = _run(3);

        // Both produce a well-defined LP-net figure; the point is the harness reports net, not just
        // revenue, so a revenue gain can coexist with a net loss.
        assertTrue(highFee.lpNetWad != lowFee.lpNetWad, "different fees produce different LP net");
    }
}
