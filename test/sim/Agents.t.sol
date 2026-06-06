// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SimBase} from "./SimBase.sol";
import {SimPool} from "./harness/SimPool.sol";
import {Agents} from "./harness/Agents.sol";

/// @notice Establishes that the two simulated agents behave as claimed: the arb is rational and
///         fee-aware (it stops at the no-arb band, wider band for a higher fee), and retail flow is
///         fee-elastic (volume falls as the fee rises). These are the assumptions every later result
///         rests on, so they are pinned here before any mechanism is built.
contract AgentsTest is SimBase {
    // A plain, liquid market; individual tests override the pieces they exercise.
    function market() internal pure override returns (Market memory) {
        return Market({
            startTick: 0,
            stepTicks: 10,
            driftTicks: 0,
            liquidity: 1e21,
            blocks: 50,
            retailBase: 1e21,
            retailRefFee: 3000
        });
    }

    function _quote(uint24 fee) internal pure returns (FeeQuote memory) {
        return FeeQuote({feeZeroForOne: fee, feeOneForZero: fee});
    }

    // --- arb is rational: stops at the band, not at the external price --------

    function test_arbStopsAtBand_highSide() public {
        // Pool starts 1000 ticks above external; arb sells token0 down to (external + band).
        uint24 fee = 3000; // band = 30 ticks
        SimPool pool = new SimPool(TickMath.getSqrtPriceAtTick(1000), 1e23);
        int24 ext = 0;

        _reset();
        _stepArb(pool, ext, _quote(fee));

        int24 band = Agents.bandTicks(fee);
        int24 resid = pool.tick() - ext;
        // It pulled the price down to the band edge, and stopped there — not at the external price.
        assertApproxEqAbs(int256(resid), int256(band), 1, "arb should stop ~band ticks from external");
        assertGt(resid, int24(0), "arb must not close the gap fully");
    }

    function test_arbStopsAtBand_lowSide() public {
        // Pool starts 1000 ticks below external; arb buys token0 up to (external - band).
        uint24 fee = 3000;
        SimPool pool = new SimPool(TickMath.getSqrtPriceAtTick(-1000), 1e23);
        int24 ext = 0;

        _reset();
        _stepArb(pool, ext, _quote(fee));

        int24 band = Agents.bandTicks(fee);
        int24 resid = ext - pool.tick();
        assertApproxEqAbs(int256(resid), int256(band), 1, "arb should stop ~band ticks from external");
        assertGt(resid, int24(0), "arb must not close the gap fully");
    }

    function test_higherFeeWiderBand() public {
        int24 ext = 0;
        SimPool a = new SimPool(TickMath.getSqrtPriceAtTick(1000), 1e23);
        SimPool b = new SimPool(TickMath.getSqrtPriceAtTick(1000), 1e23);

        _reset();
        _stepArb(a, ext, _quote(1000)); // band 10
        _stepArb(b, ext, _quote(10_000)); // band 100

        assertGt(b.tick() - ext, a.tick() - ext, "higher fee leaves a wider residual mispricing");
    }

    function test_arbInsideBandDoesNothing() public {
        uint24 fee = 3000; // band 30
        SimPool pool = new SimPool(TickMath.getSqrtPriceAtTick(20), 1e23); // within 30 of ext=0
        int24 ext = 0;

        _reset();
        _stepArb(pool, ext, _quote(fee));

        assertEq(pool.tick(), int24(20), "no trade when already inside the band");
        assertEq(feeCum0 + feeCum1, 0, "no fee when the arb sits out");
    }

    // --- retail is fee-elastic: volume falls as the fee rises -----------------

    function testFuzz_retailNotionalMonotoneInFee(uint24 lowFee, uint24 hiFee) public pure {
        lowFee = uint24(bound(lowFee, 0, 500_000));
        hiFee = uint24(bound(hiFee, 0, 500_000));
        vm.assume(hiFee > lowFee);
        uint256 lo = Agents.retailNotional(1e21, lowFee, 3000);
        uint256 hi = Agents.retailNotional(1e21, hiFee, 3000);
        assertLe(hi, lo, "higher fee cannot increase retail volume");
    }

    function test_retailVolumeFallsWithFee() public {
        SimPool cheap = new SimPool(TickMath.getSqrtPriceAtTick(0), 1e23);
        SimPool dear = new SimPool(TickMath.getSqrtPriceAtTick(0), 1e23);

        _reset();
        _stepRetail(cheap, 1, 0, _quote(300)); // 0.03%
        uint256 volCheap = retailInNotional;

        _reset();
        _stepRetail(dear, 1, 0, _quote(30_000)); // 3.00%
        uint256 volDear = retailInNotional;

        assertGt(volCheap, volDear, "retail trades less when the fee is high");
    }
}
