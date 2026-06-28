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
        Skew
    }

    FeeMode internal feeMode = FeeMode.Static;
    Inventory.Config internal skewInvCfg;
    SkewCurve.Params internal skewCurve;

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

    /// @dev The fee for the current state under the selected policy. For the skew policy this is the
    ///      same computation the hook performs: imbalance from the pool tick, then the direction fee.
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
        return super._quoteFee(poolTick, extTick);
    }
}
