// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SkewCurve} from "../../src/libraries/SkewCurve.sol";

/// @notice Smoke tests for the skew fee: symmetric at zero imbalance, and skewed the right way when
///         the pool is lopsided (discount the rebalancing direction, surcharge the worsening one).
///         Exhaustive bounds/sign/monotonicity fuzzing is added alongside.
contract SkewCurveTest is Test {
    using SkewCurve for SkewCurve.Params;

    // base 0.30%, floor 0.01%, cap 1.00%, skew slope 5000 pips per unit imbalance, no vol term.
    function _p() internal pure returns (SkewCurve.Params memory) {
        return SkewCurve.Params({baseFee: 3000, minFee: 100, maxFee: 10_000, slope: 5000, volSlope: 0});
    }

    function test_zeroImbalanceIsSymmetricBase() public pure {
        assertEq(_p().fee(0, true, 0), 3000);
        assertEq(_p().fee(0, false, 0), 3000);
    }

    function test_excessToken0SkewsCorrectly() public pure {
        // imbalance > 0: adding token0 (zeroForOne) worsens -> surcharge; removing it -> discount.
        uint24 worsening = _p().fee(0.5e18, true, 0); // zeroForOne adds token0
        uint24 rebalancing = _p().fee(0.5e18, false, 0); // oneForZero removes token0
        assertGt(worsening, 3000, "worsening side surcharged above base");
        assertLt(rebalancing, 3000, "rebalancing side discounted below base");
    }

    function test_excessToken1SkewsCorrectly() public pure {
        // imbalance < 0: adding token1 (oneForZero) worsens; removing it (zeroForOne) rebalances.
        uint24 worsening = _p().fee(-0.5e18, false, 0);
        uint24 rebalancing = _p().fee(-0.5e18, true, 0);
        assertGt(worsening, 3000, "worsening side surcharged above base");
        assertLt(rebalancing, 3000, "rebalancing side discounted below base");
    }

    function test_clampsToBounds() public pure {
        // A huge imbalance saturates both sides to the cap/floor.
        assertEq(_p().fee(1e18, true, 0), 8000); // 3000 + 5000
        SkewCurve.Params memory steep =
            SkewCurve.Params({baseFee: 3000, minFee: 100, maxFee: 10_000, slope: 50_000, volSlope: 0});
        assertEq(steep.fee(1e18, true, 0), 10_000); // capped at maxFee
        assertEq(steep.fee(1e18, false, 0), 100); // floored at minFee
    }
}
