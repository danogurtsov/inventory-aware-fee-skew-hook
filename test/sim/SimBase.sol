// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {SimPool} from "./harness/SimPool.sol";
import {PricePath} from "./harness/PricePath.sol";
import {Agents} from "./harness/Agents.sol";

/// @title SimBase
/// @notice Abstract harness that runs a market against a `SimPool`: each block an external price is
///         drawn (`PricePath`), a rational fee-aware arbitrageur pulls the pool to the no-arb band,
///         then fee-elastic retail trades noise. It accumulates the LP's inventory drift and fee
///         revenue as it goes. The objective metrics (LP net vs rebalancing, inventory variance) are
///         layered on in the next commit; here the market and the agents are established and tested.
/// @dev A `FeeSchedule` returns the fee per direction, so the same loop drives a static symmetric fee
///      now and the asymmetric skew fee later — no rewrite when the mechanism arrives.
abstract contract SimBase is Test {
    using PricePath for uint256;

    // --- market configuration -------------------------------------------------

    struct Market {
        int24 startTick; // pool & external price at block 0
        uint24 stepTicks; // per-block volatility (half-width)
        int24 driftTicks; // per-block drift (0 == symmetric, >0 == toxic one-directional)
        uint128 liquidity; // constant active liquidity
        uint256 blocks; // number of blocks (12s each)
        uint256 retailBase; // retail notional per block at zero fee (token1 units)
        uint24 retailRefFee; // fee (pips) at which retail flow halves
    }

    // Fee (pips) charged for a swap in the given direction, at the current pool state.
    // `zeroForOne == true` means the trader sells token0 (pushes price down).
    struct FeeQuote {
        uint24 feeZeroForOne;
        uint24 feeOneForZero;
    }

    // --- per-run accumulators (reset by `_reset`) -----------------------------

    int256 internal invDelta0; // net token0 the LP has taken on since block 0
    int256 internal invDelta1; // net token1 the LP has taken on since block 0
    uint256 internal feeCum0; // cumulative LP fees collected in token0
    uint256 internal feeCum1; // cumulative LP fees collected in token1
    uint256 internal retailInNotional; // cumulative retail input actually swapped (elasticity probe)

    function _reset() internal {
        invDelta0 = 0;
        invDelta1 = 0;
        feeCum0 = 0;
        feeCum1 = 0;
        retailInNotional = 0;
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
            _applySwap(z4o, aIn, aOut, fee);
        } else if (poolTick < extTick - bandO) {
            uint160 target = TickMath.getSqrtPriceAtTick(extTick - bandO);
            (bool z4o, uint256 aIn, uint256 aOut, uint256 fee) = pool.swapToPrice(target, q.feeOneForZero);
            _applySwap(z4o, aIn, aOut, fee);
        }
    }

    /// @dev Fee-elastic retail: total notional shrinks with the fee; split into two opposing trades
    ///      (pseudo-random lean by block) so retail is mostly noise, not a directional bet.
    function _stepRetail(SimPool pool, uint256 seed, uint256 blk, FeeQuote memory q) internal {
        Market memory m = market();
        uint24 avgFee = uint24((uint256(q.feeZeroForOne) + q.feeOneForZero) / 2);
        uint256 notional = Agents.retailNotional(m.retailBase, avgFee, m.retailRefFee);
        if (notional == 0) return;

        // Lean: split the notional 60/40 by a per-block coin flip, so net retail flow is small.
        uint256 h = uint256(keccak256(abi.encode(seed, "retail", blk)));
        bool moreSells = (h & 1) == 0;
        uint256 sellPart = (notional * (moreSells ? 6 : 4)) / 10; // token0-in (zeroForOne)
        uint256 buyPart = notional - sellPart; // token1-in (oneForZero)

        if (sellPart > 0) {
            // retail sells token0: notional is token1-denominated, convert at current price ~1 for sim
            (uint256 usedIn, uint256 aOut, uint256 fee) = pool.swapExactIn(true, sellPart, q.feeZeroForOne);
            _applySwap(true, usedIn, aOut, fee);
            retailInNotional += usedIn + fee;
        }
        if (buyPart > 0) {
            (uint256 usedIn, uint256 aOut, uint256 fee) = pool.swapExactIn(false, buyPart, q.feeOneForZero);
            _applySwap(false, usedIn, aOut, fee);
            retailInNotional += usedIn + fee;
        }
    }

    /// @dev Fold one executed swap into the LP's inventory and fee accumulators. The LP is the
    ///      counterparty: it receives the input token (curve amount + fee) and pays out the output.
    function _applySwap(bool zeroForOne, uint256 amountIn, uint256 amountOut, uint256 feeAmount) internal {
        // safe: sim swap amounts are bounded well under 2**255 by the pool's liquidity and step size.
        // forge-lint: disable-start(unsafe-typecast)
        if (zeroForOne) {
            invDelta0 += int256(amountIn + feeAmount);
            invDelta1 -= int256(amountOut);
            feeCum0 += feeAmount;
        } else {
            invDelta1 += int256(amountIn + feeAmount);
            invDelta0 -= int256(amountOut);
            feeCum1 += feeAmount;
        }
        // forge-lint: disable-end(unsafe-typecast)
    }

    // --- to be provided by concrete tests ------------------------------------

    /// @notice The market parameters for this run.
    function market() internal view virtual returns (Market memory);

    /// @notice A fresh pool at the market's start price and liquidity.
    function _newPool() internal returns (SimPool) {
        Market memory m = market();
        return new SimPool(TickMath.getSqrtPriceAtTick(m.startTick), m.liquidity);
    }
}
