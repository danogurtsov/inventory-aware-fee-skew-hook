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

    // --- exhaustive properties (the correctness backbone) --------------------

    // A fuzzed-but-valid params set: min <= base <= max <= MAX_LP_FEE, arbitrary slopes.
    function _validParams(uint24 baseFee, uint24 minFee, uint24 maxFee, uint256 slope, uint256 volSlope)
        internal
        pure
        returns (SkewCurve.Params memory p)
    {
        maxFee = uint24(bound(maxFee, 1, 1_000_000)); // MAX_LP_FEE
        baseFee = uint24(bound(baseFee, 0, maxFee));
        minFee = uint24(bound(minFee, 0, baseFee));
        slope = bound(slope, 0, 5_000_000);
        volSlope = bound(volSlope, 0, 5_000_000);
        p = SkewCurve.Params({
            baseFee: baseFee, minFee: minFee, maxFee: maxFee, slope: slope, volSlope: volSlope
        });
    }

    function testFuzz_alwaysWithinBounds(
        uint24 baseFee,
        uint24 minFee,
        uint24 maxFee,
        uint256 slope,
        uint256 volSlope,
        int256 imb,
        bool dir,
        uint256 vol
    ) public pure {
        SkewCurve.Params memory p = _validParams(baseFee, minFee, maxFee, slope, volSlope);
        imb = bound(imb, -1e18, 1e18);
        vol = bound(vol, 0, 100e18);
        uint24 f = p.fee(imb, dir, vol);
        assertGe(f, p.minFee, "fee below floor");
        assertLe(f, p.maxFee, "fee above cap");
    }

    function testFuzz_signIsCorrect(uint256 slope, int256 imb, uint256 vol) public pure {
        // With a nonzero imbalance, the rebalancing side is <= base and the worsening side is >= base.
        SkewCurve.Params memory p = SkewCurve.Params({
            baseFee: 3000, minFee: 100, maxFee: 10_000, slope: bound(slope, 0, 200_000), volSlope: 0
        });
        imb = bound(imb, -1e18, 1e18);
        vol = bound(vol, 0, 100e18);
        if (imb == 0) {
            assertEq(p.fee(imb, true, vol), p.baseFee, "symmetric at zero");
            assertEq(p.fee(imb, false, vol), p.baseFee, "symmetric at zero");
            return;
        }
        // For imb>0 the worsening direction is zeroForOne; for imb<0 it is oneForZero.
        bool worseningDir = imb > 0;
        assertGe(p.fee(imb, worseningDir, vol), p.baseFee, "worsening >= base");
        assertLe(p.fee(imb, !worseningDir, vol), p.baseFee, "rebalancing <= base");
    }

    function testFuzz_monotoneInImbalance(uint256 a, uint256 b) public pure {
        SkewCurve.Params memory p = _p();
        uint256 lo = bound(a, 0, 1e18);
        uint256 hi = bound(b, 0, 1e18);
        if (hi < lo) (lo, hi) = (hi, lo);
        // safe: lo, hi are bounded to [0, 1e18], well within int256.
        // forge-lint: disable-start(unsafe-typecast)
        int256 loImb = int256(lo);
        int256 hiImb = int256(hi);
        // forge-lint: disable-end(unsafe-typecast)
        // Worsening side (imb>0, zeroForOne) is non-decreasing in |imb|.
        assertLe(p.fee(loImb, true, 0), p.fee(hiImb, true, 0), "surcharge grows with imbalance");
        // Rebalancing side (imb>0, oneForZero) is non-increasing in |imb|.
        assertGe(p.fee(loImb, false, 0), p.fee(hiImb, false, 0), "discount grows with imbalance");
    }

    function testFuzz_volWidensSkew(uint256 vol) public pure {
        SkewCurve.Params memory p =
            SkewCurve.Params({baseFee: 3000, minFee: 100, maxFee: 10_000, slope: 2000, volSlope: 3000});
        vol = bound(vol, 1, 1e18);
        // More volatility cannot shrink the surcharge at a fixed imbalance.
        assertGe(p.fee(0.5e18, true, vol), p.fee(0.5e18, true, 0), "vol widens the surcharge");
    }
}
