// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SimBase} from "./SimBase.sol";
import {Inventory} from "../../src/libraries/Inventory.sol";
import {SkewCurve} from "../../src/libraries/SkewCurve.sol";

/// @title SkewSim
/// @notice Drives the harness with the *actual production libraries* the hook uses — `Inventory` for
///         the imbalance signal and `SkewCurve` for the asymmetric fee — so the simulation measures
///         the real mechanism, not a re-implementation. The pool tick the harness passes to
///         `_quoteFee` is exactly what the on-chain hook reads from `slot0`, so the sim fee equals
///         the deployed fee for the same state.
/// @dev A `FeeMode` selects the policy under test: the static symmetric baseline (from `SimBase`) or
///      the inventory skew. The directional (Nezlobin) baseline is added on top of this in a later
///      commit; keeping the switch here lets every policy share one identical market and agent set.
abstract contract SkewSim is SimBase {
    enum FeeMode {
        Static,
        Skew,
        Directional
    }

    FeeMode internal feeMode = FeeMode.Static;
    Inventory.Config internal skewInvCfg;
    SkewCurve.Params internal skewCurve;

    // Directional (Nezlobin) policy: skew the fee by the *last observed* price move. `dirCurve.slope`
    // is the Nezlobin `c` in pips of skew per tick of move. The signal is one block stale by
    // construction — that lag is the whole point of comparing it against the lag-free inventory one.
    SkewCurve.Params internal dirCurve;
    int24 internal _dirPrevTick; // external tick at block b-1
    int24 internal _dirPrev2Tick; // external tick at block b-2

    /// @notice Configure the inventory-skew policy and select it.
    function _useSkew(Inventory.Config memory invCfg, SkewCurve.Params memory curve) internal {
        Inventory.validate(invCfg);
        SkewCurve.validate(curve);
        skewInvCfg = invCfg;
        skewCurve = curve;
        feeMode = FeeMode.Skew;
    }

    /// @notice Select the static symmetric baseline at `feePips`.
    function _useStatic(uint24 feePips) internal {
        staticFeePips = feePips;
        feeMode = FeeMode.Static;
    }

    /// @notice Configure the directional (Nezlobin) baseline and select it.
    function _useDirectional(SkewCurve.Params memory curve) internal {
        SkewCurve.validate(curve);
        dirCurve = curve;
        feeMode = FeeMode.Directional;
    }

    function _resetPolicy() internal override {
        _dirPrevTick = 0;
        _dirPrev2Tick = 0;
    }

    /// @dev Shift the external-tick history so the directional fee always reads a *past* move.
    function _onBlock(int24 extTick) internal override {
        _dirPrev2Tick = _dirPrevTick;
        _dirPrevTick = extTick;
    }

    /// @dev The fee for the current state under the selected policy. The skew policy matches the
    ///      on-chain hook exactly (imbalance from the pool tick, then the direction fee).
    function _quoteFee(int24 poolTick, int24 extTick)
        internal
        view
        virtual
        override
        returns (FeeQuote memory)
    {
        if (feeMode == FeeMode.Skew) {
            int256 imb = Inventory.imbalanceWad(poolTick, skewInvCfg);
            return FeeQuote({
                feeZeroForOne: SkewCurve.fee(skewCurve, imb, true, 0),
                feeOneForZero: SkewCurve.fee(skewCurve, imb, false, 0)
            });
        }
        if (feeMode == FeeMode.Directional) {
            return _directionalQuote();
        }
        return super._quoteFee(poolTick, extTick);
    }

    /// @dev Nezlobin directional fee from the last observed move `delta = tick(b-1) - tick(b-2)`.
    ///      When price last rose (`delta > 0`), informed flow keeps buying token0 (`oneForZero`), so
    ///      that side is surcharged and the opposite discounted. Backward-looking by construction.
    function _directionalQuote() internal view returns (FeeQuote memory) {
        int256 delta = int256(_dirPrevTick) - int256(_dirPrev2Tick);
        uint256 mag = delta < 0 ? uint256(-delta) : uint256(delta);
        uint256 skew = mag * dirCurve.slope; // pips of skew (slope = c, pips per tick)

        uint24 up = _addClamp(dirCurve, skew); // surcharged side
        uint24 down = _subClamp(dirCurve, skew); // discounted side
        if (delta > 0) {
            // price up -> surcharge buying token0 (oneForZero), discount selling token0 (zeroForOne)
            return FeeQuote({feeZeroForOne: down, feeOneForZero: up});
        } else if (delta < 0) {
            return FeeQuote({feeZeroForOne: up, feeOneForZero: down});
        }
        return FeeQuote({feeZeroForOne: dirCurve.baseFee, feeOneForZero: dirCurve.baseFee});
    }

    function _addClamp(SkewCurve.Params memory p, uint256 skew) private pure returns (uint24) {
        uint256 room = uint256(p.maxFee) - p.baseFee;
        uint256 raw = skew >= room ? p.maxFee : uint256(p.baseFee) + skew;
        // safe: raw is clamped to maxFee <= 1e6 < 2**24.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(raw);
    }

    function _subClamp(SkewCurve.Params memory p, uint256 skew) private pure returns (uint24) {
        uint256 raw = uint256(p.baseFee) > skew ? uint256(p.baseFee) - skew : 0;
        if (raw < p.minFee) raw = p.minFee;
        // safe: raw is in [minFee, baseFee] <= 1e6 < 2**24.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(raw);
    }
}
