// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

import {SimPool} from "./harness/SimPool.sol";
import {PricePath} from "./harness/PricePath.sol";
import {Agents} from "./harness/Agents.sol";
import {Metrics} from "./harness/Metrics.sol";

/// @title SimBase
/// @notice Abstract harness that runs a market against a `SimPool`: each block an external price is
///         drawn (`PricePath`), a rational fee-aware arbitrageur pulls the pool to the no-arb band,
///         then fee-elastic retail trades noise. It measures the LP the honest way — **net PnL vs a
///         rebalancing benchmark (fees minus loss-versus-rebalancing) and inventory variance / final
///         skew**, valuing every trade at the external price of its block. Fee revenue alone is a
///         vanity metric and is reported only as a component, never as the verdict.
/// @dev The fee is quoted through `_quoteFee`, so the same loop drives a static symmetric fee now and
///      the asymmetric inventory-skew fee later with no rewrite. `_quoteFee` defaults to a settable
///      static symmetric fee; the skew tests override it.
abstract contract SimBase is Test {
    using PricePath for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q96 = 1 << 96;

    // --- market configuration -------------------------------------------------

    struct Market {
        int24 startTick; // pool & external price at block 0
        uint24 stepTicks; // per-block volatility (half-width)
        int24 driftTicks; // per-block drift (0 == symmetric, >0 == toxic one-directional)
        uint128 liquidity; // constant active liquidity
        int24 tickLower; // LP position range lower bound (for capital & concentration)
        int24 tickUpper; // LP position range upper bound
        uint256 blocks; // number of blocks (12s each)
        uint256 retailBase; // retail notional per block at zero fee (token1 units)
        uint24 retailChokeFee; // fee (pips) at which retail flow chokes to zero
    }

    // Fee (pips) charged per direction. `zeroForOne` == trader sells token0 (pushes price down).
    struct FeeQuote {
        uint24 feeZeroForOne;
        uint24 feeOneForZero;
    }

    /// @notice The objective outcome of one run. Raw WAD figures plus the normalized verdicts.
    struct RunResult {
        int256 lpNetWad; // LP net PnL vs rebalancing (fees - LVR), token1 WAD  <-- the verdict
        uint256 feeValueWad; // LP fee revenue (component, valued at block price)
        int256 lvrWad; // loss-versus-rebalancing (fees - lpNet)
        uint256 invVarianceWad; // variance of the LP's token0 inventory drift  <-- what the skew targets
        int256 terminalInv0; // LP's net token0 position at the end (final skew)
        uint256 avgFeePips; // mean fee charged across all swaps (elasticity/1 - sided cost)
        uint256 lpCapitalWad; // LP position value at the start (normalization base)
        int256 lpNetBps; // LP net as basis points of capital (comparable across sizes)
        int256 lpNetAnnualBps; // LP net annualized (bps/yr, 12s clock)  <-- the headline figure
        int256 lvrAnnualBps; // loss-versus-rebalancing annualized (bps/yr)
    }

    // --- per-run accumulators (reset by `_reset`) -----------------------------

    int256 internal invDelta0; // net token0 the LP has taken on since block 0
    int256 internal invDelta1; // net token1 the LP has taken on since block 0
    uint256 internal feeCum0; // cumulative LP fees collected in token0
    uint256 internal feeCum1; // cumulative LP fees collected in token1
    uint256 internal retailInNotional; // cumulative retail input actually swapped (elasticity probe)

    int256 internal lpNetWad; // running LP net PnL, valued per-block at the external price
    uint256 internal feeValueWad; // running LP fee revenue, valued per-block
    uint256 internal curPriceWad; // external price (token1/token0 WAD) for the block being simulated

    uint256 internal invSampleN; // inventory-drift samples (one per block)
    int256 internal invSampleSum; // sum of sampled invDelta0
    uint256 internal invSampleSumSq; // sum of squares of sampled invDelta0

    uint256 internal feePipsSum; // sum of per-swap fees charged
    uint256 internal feeSwapCount; // number of swaps charged a fee

    uint24 internal staticFeePips = 500; // default static symmetric fee for the base `_quoteFee`

    function _reset() internal {
        invDelta0 = 0;
        invDelta1 = 0;
        feeCum0 = 0;
        feeCum1 = 0;
        retailInNotional = 0;
        lpNetWad = 0;
        feeValueWad = 0;
        curPriceWad = 0;
        invSampleN = 0;
        invSampleSum = 0;
        invSampleSumSq = 0;
        feePipsSum = 0;
        feeSwapCount = 0;
        _resetPolicy();
    }

    /// @dev Hook for a policy to reset its own per-run state (e.g. a directional fee's tick history).
    function _resetPolicy() internal virtual {}

    /// @dev Hook called once per block *after* the block is simulated, so a policy can fold the
    ///      just-observed external tick into a backward-looking signal (used by the directional fee).
    function _onBlock(int24 extTick) internal virtual {}

    // --- the run loop ---------------------------------------------------------

    /// @notice Simulate the whole market over `market().blocks` and return the objective metrics.
    function _run(uint256 seed) internal returns (RunResult memory r) {
        Market memory m = market();
        _reset();
        SimPool pool = _newPool();

        for (uint256 b = 1; b <= m.blocks; b++) {
            int24 extTick = PricePath.tickAt(seed, b, m.startTick, m.stepTicks, m.driftTicks);
            curPriceWad = _priceWadAtTick(extTick);

            FeeQuote memory q = _quoteFee(pool.tick(), extTick);
            _stepArb(pool, extTick, q);
            _stepRetail(pool, seed, b, q);

            // Sample the LP's inventory drift once per block (post-flow).
            invSampleN += 1;
            invSampleSum += invDelta0;
            // safe: |invDelta0| is bounded by pool liquidity; its square stays far under 2**256.
            // forge-lint: disable-next-line(unsafe-typecast)
            invSampleSumSq += uint256(invDelta0 * invDelta0);

            _onBlock(extTick);
        }

        r.lpNetWad = lpNetWad;
        r.feeValueWad = feeValueWad;
        // safe: feeValueWad is a sum of sim fee values, bounded far under 2**255.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.lvrWad = int256(feeValueWad) - lpNetWad;
        r.invVarianceWad = Metrics.variance(invSampleN, invSampleSum, invSampleSumSq);
        r.terminalInv0 = invDelta0;
        r.avgFeePips = feeSwapCount == 0 ? 0 : feePipsSum / feeSwapCount;

        // Normalize: raw token figures are meaningless; report bps of capital and annualized rate.
        r.lpCapitalWad = _lpCapitalWad();
        r.lpNetBps = Metrics.bpsOfCapital(r.lpNetWad, r.lpCapitalWad);
        r.lpNetAnnualBps = Metrics.annualize(r.lpNetBps, m.blocks);
        r.lvrAnnualBps = Metrics.annualize(Metrics.bpsOfCapital(r.lvrWad, r.lpCapitalWad), m.blocks);
    }

    // --- agent steps ----------------------------------------------------------

    /// @dev Rational fee-aware arb: pull the pool to the profitable band edge around `extTick`, using
    ///      the fee for the direction it must trade. Inside the band it does nothing.
    function _stepArb(SimPool pool, int24 extTick, FeeQuote memory q) internal {
        int24 poolTick = pool.tick();
        int24 bandZ = Agents.bandTicks(q.feeZeroForOne); // selling token0 lowers price
        int24 bandO = Agents.bandTicks(q.feeOneForZero); // buying token0 raises price

        if (poolTick > extTick + bandZ) {
            uint160 target = TickMath.getSqrtPriceAtTick(extTick + bandZ);
            (bool z4o, uint256 aIn, uint256 aOut, uint256 fee) = pool.swapToPrice(target, q.feeZeroForOne);
            _applySwap(z4o, aIn, aOut, fee, q.feeZeroForOne);
        } else if (poolTick < extTick - bandO) {
            uint160 target = TickMath.getSqrtPriceAtTick(extTick - bandO);
            (bool z4o, uint256 aIn, uint256 aOut, uint256 fee) = pool.swapToPrice(target, q.feeOneForZero);
            _applySwap(z4o, aIn, aOut, fee, q.feeOneForZero);
        }
    }

    /// @dev Fee-elastic retail: total notional shrinks with the fee; split into two opposing trades
    ///      (pseudo-random lean by block) so retail is mostly noise, not a directional bet.
    function _stepRetail(SimPool pool, uint256 seed, uint256 blk, FeeQuote memory q) internal {
        Market memory m = market();
        uint24 avgFee = uint24((uint256(q.feeZeroForOne) + q.feeOneForZero) / 2);
        uint256 notional = Agents.retailNotional(m.retailBase, avgFee, m.retailChokeFee);
        if (notional == 0) return;

        uint256 h = uint256(keccak256(abi.encode(seed, "retail", blk)));
        bool moreSells = (h & 1) == 0;
        uint256 sellPart = (notional * (moreSells ? 6 : 4)) / 10; // token0-in (zeroForOne)
        uint256 buyPart = notional - sellPart; // token1-in (oneForZero)

        if (sellPart > 0) {
            (uint256 usedIn, uint256 aOut, uint256 fee) = pool.swapExactIn(true, sellPart, q.feeZeroForOne);
            _applySwap(true, usedIn, aOut, fee, q.feeZeroForOne);
            retailInNotional += usedIn + fee;
        }
        if (buyPart > 0) {
            (uint256 usedIn, uint256 aOut, uint256 fee) = pool.swapExactIn(false, buyPart, q.feeOneForZero);
            _applySwap(false, usedIn, aOut, fee, q.feeOneForZero);
            retailInNotional += usedIn + fee;
        }
    }

    /// @dev Fold one executed swap into inventory, fees, and the LP's mark-to-market PnL at the
    ///      block's external price. The LP is the counterparty: it receives the input token (curve
    ///      amount + fee) and pays out the output token. Valuing received-minus-paid at the external
    ///      price is exactly LP-net-vs-rebalancing, and it already contains both the fee gain and the
    ///      LVR loss without modelling them separately.
    function _applySwap(
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeAmount,
        uint24 feePips
    ) internal {
        uint256 p = curPriceWad;
        // safe: sim amounts are bounded well under 2**255 by liquidity and step size.
        // forge-lint: disable-start(unsafe-typecast)
        if (zeroForOne) {
            uint256 recvVal = FullMath.mulDiv(amountIn + feeAmount, p, WAD); // token0 received -> token1
            lpNetWad += int256(recvVal) - int256(amountOut);
            feeValueWad += FullMath.mulDiv(feeAmount, p, WAD);
            invDelta0 += int256(amountIn + feeAmount);
            invDelta1 -= int256(amountOut);
            feeCum0 += feeAmount;
        } else {
            uint256 paidVal = FullMath.mulDiv(amountOut, p, WAD); // token0 paid -> token1
            lpNetWad += int256(amountIn + feeAmount) - int256(paidVal);
            feeValueWad += feeAmount;
            invDelta1 += int256(amountIn + feeAmount);
            invDelta0 -= int256(amountOut);
            feeCum1 += feeAmount;
        }
        // forge-lint: disable-end(unsafe-typecast)
        feePipsSum += feePips;
        feeSwapCount += 1;
    }

    // --- fee policy (overridable) ---------------------------------------------

    /// @notice Fee quote for the current state. Base implementation is a static symmetric fee; the
    ///         skew mechanism overrides this to lean the fee against inventory.
    function _quoteFee(
        int24,
        /*poolTick*/
        int24 /*extTick*/
    )
        internal
        view
        virtual
        returns (FeeQuote memory)
    {
        return FeeQuote({feeZeroForOne: staticFeePips, feeOneForZero: staticFeePips});
    }

    // --- helpers --------------------------------------------------------------

    /// @notice External price (token1 per token0, WAD) at a tick.
    function _priceWadAtTick(int24 tick) internal pure returns (uint256) {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        uint256 priceX96 = FullMath.mulDiv(sqrtP, sqrtP, Q96); // price * 2**96
        return FullMath.mulDiv(priceX96, WAD, Q96);
    }

    /// @notice Value (token1 WAD) of the LP position at the start price — the normalization base.
    /// @dev The token0/token1 held by `liquidity` over `[tickLower, tickUpper]` at the start price,
    ///      valued in token1. A narrower range packs more capital at the price, so the same drift is
    ///      a larger fraction of it — which is exactly why concentration raises inventory risk.
    function _lpCapitalWad() internal view returns (uint256) {
        Market memory m = market();
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(m.startTick);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(m.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(m.tickUpper);
        uint256 amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtUpper, m.liquidity, false);
        uint256 amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtP, m.liquidity, false);
        return amount1 + FullMath.mulDiv(amount0, _priceWadAtTick(m.startTick), WAD);
    }

    /// @notice The market parameters for this run.
    function market() internal view virtual returns (Market memory);

    /// @notice A fresh pool at the market's start price and liquidity.
    function _newPool() internal returns (SimPool) {
        Market memory m = market();
        return new SimPool(TickMath.getSqrtPriceAtTick(m.startTick), m.liquidity);
    }
}
