// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title SkewCurve
/// @notice Maps an inventory imbalance and a swap direction to an **asymmetric** Uniswap v4 LP fee.
///         The direction that rebalances the pool (reduces `|imbalance|`) is *discounted*; the
///         direction that worsens it is *surcharged*. The skew grows with the imbalance (an
///         Avellaneda–Stoikov-style inventory lean) and, optionally, with volatility. The fee is a
///         `uint24` in pips (1_000_000 == 100%).
/// @dev Design guarantees, enforced structurally and proven by the unit fuzz + Halmos spec:
///        1. the fee is always within `[minFee, maxFee]` for either direction;
///        2. the rebalancing side is always `<= baseFee`, the worsening side always `>= baseFee`;
///        3. at zero imbalance the fee is exactly `baseFee` in both directions (symmetric);
///        4. the magnitude is monotone in `|imbalance|` (and in volatility).
library SkewCurve {
    error MinAboveBase();
    error BaseAboveMax();
    error MaxTooLarge();

    uint256 internal constant WAD = 1e18;

    /// @param baseFee  Fee at zero imbalance (pips) — the symmetric anchor.
    /// @param minFee   Lower clamp (pips); the discounted side never drops below this.
    /// @param maxFee   Upper clamp (pips); the surcharged side never rises above this.
    /// @param slope    Pips of skew per 1.0 (WAD) of `|imbalance|`.
    /// @param volSlope Extra pips of skew per 1.0 (WAD) of `|imbalance|` per 1.0 (WAD) of volatility.
    struct Params {
        uint24 baseFee;
        uint24 minFee;
        uint24 maxFee;
        uint256 slope;
        uint256 volSlope;
    }

    /// @notice Revert unless the params form a valid, in-range curve.
    function validate(Params memory p) internal pure {
        if (p.minFee > p.baseFee) revert MinAboveBase();
        if (p.baseFee > p.maxFee) revert BaseAboveMax();
        if (p.maxFee > LPFeeLibrary.MAX_LP_FEE) revert MaxTooLarge();
    }

    /// @notice The LP fee (pips) for a swap in the given direction at the current inventory state.
    /// @param imbalanceWad Signed inventory imbalance in `[-1e18, +1e18]`; `>0` == excess token0.
    /// @param zeroForOne   True for a token0 -> token1 swap (adds token0 to the pool).
    /// @param volWad       Volatility estimate (WAD); pass `0` to disable the volatility term.
    function fee(Params memory p, int256 imbalanceWad, bool zeroForOne, uint256 volWad)
        internal
        pure
        returns (uint24)
    {
        uint256 skew = _skewPips(p, _abs(imbalanceWad), volWad);
        uint256 raw;

        if (_isRebalancing(imbalanceWad, zeroForOne)) {
            // Discount the side that pulls inventory back toward target, never below `minFee`.
            raw = uint256(p.baseFee) > skew ? uint256(p.baseFee) - skew : 0;
            if (raw < p.minFee) raw = p.minFee;
        } else {
            // Surcharge the side that worsens inventory (or the neutral case), never above `maxFee`.
            uint256 room = uint256(p.maxFee) - p.baseFee;
            raw = skew >= room ? p.maxFee : uint256(p.baseFee) + skew;
            // `baseFee >= minFee` (validated), so `raw >= minFee` already; kept for symmetry of intent.
            if (raw < p.minFee) raw = p.minFee;
        }

        // safe: `raw` is clamped into `[minFee, maxFee]` above, and `maxFee <= 1e6 < 2**24`.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(raw);
    }

    /// @notice A swap rebalances iff it removes the token the pool holds in excess.
    /// @dev Excess token0 (`imbalance > 0`) is reduced by a token0-out swap (`oneForZero`); excess
    ///      token1 (`imbalance < 0`) is reduced by a token1-out swap (`zeroForOne`). At exactly zero
    ///      imbalance neither direction rebalances, so both take the (zero) surcharge == `baseFee`.
    function _isRebalancing(int256 imbalanceWad, bool zeroForOne) internal pure returns (bool) {
        if (imbalanceWad > 0) return !zeroForOne;
        if (imbalanceWad < 0) return zeroForOne;
        return false;
    }

    /// @dev Skew magnitude (pips) = `slope * |imb| + volSlope * |imb| * vol`, all in WAD-normalized
    ///      fixed point. Non-negative and monotone in both `|imb|` and `vol`.
    function _skewPips(Params memory p, uint256 absImbWad, uint256 volWad) private pure returns (uint256) {
        uint256 skew = FullMath.mulDiv(p.slope, absImbWad, WAD);
        if (p.volSlope != 0 && volWad != 0) {
            uint256 volTerm = FullMath.mulDiv(FullMath.mulDiv(p.volSlope, absImbWad, WAD), volWad, WAD);
            skew += volTerm;
        }
        return skew;
    }

    /// @dev Absolute value of a signed imbalance as a uint.
    function _abs(int256 x) private pure returns (uint256) {
        // safe: negation then cast of a non-positive value is exact within uint256.
        // forge-lint: disable-next-line(unsafe-typecast)
        return x < 0 ? uint256(-x) : uint256(x);
    }
}
