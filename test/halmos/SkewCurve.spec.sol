// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SkewCurve} from "../../src/libraries/SkewCurve.sol";

/// @notice Symbolic spec for `SkewCurve`, to machine-prove its guarantees over *all* inputs rather
///         than a sampled fuzz. Run with Halmos:
///           `halmos --match-contract SkewCurveSymbolic`
///         The `check_` prefix is executed by Halmos (which treats the function parameters as
///         symbolic) and ignored by `forge test`, so this file adds proof targets without touching
///         the offline suite. Params are constrained to the same validity Halmos would see on-chain
///         (`minFee <= baseFee <= maxFee <= MAX_LP_FEE`).
contract SkewCurveSymbolic is Test {
    using SkewCurve for SkewCurve.Params;

    uint24 internal constant MAX_LP_FEE = 1_000_000;

    function _assumeValid(SkewCurve.Params memory p, int256 imb, uint256 vol) internal pure {
        vm.assume(p.minFee <= p.baseFee);
        vm.assume(p.baseFee <= p.maxFee);
        vm.assume(p.maxFee <= MAX_LP_FEE);
        vm.assume(imb >= -1e18 && imb <= 1e18);
        vm.assume(vol <= 1e21);
        vm.assume(p.slope <= 1e9);
        vm.assume(p.volSlope <= 1e9);
    }

    /// @dev The fee is always within [minFee, maxFee], for either direction and any state.
    function check_feeWithinBounds(SkewCurve.Params memory p, int256 imb, bool dir, uint256 vol) public pure {
        _assumeValid(p, imb, vol);
        uint24 f = p.fee(imb, dir, vol);
        assert(f >= p.minFee);
        assert(f <= p.maxFee);
    }

    /// @dev At zero imbalance the fee is exactly baseFee in both directions (symmetric anchor).
    function check_symmetricAtZero(SkewCurve.Params memory p, bool dir, uint256 vol) public pure {
        _assumeValid(p, 0, vol);
        assert(p.fee(0, dir, vol) == p.baseFee);
    }

    /// @dev The worsening side is never below baseFee; the rebalancing side never above it.
    function check_signIsCorrect(SkewCurve.Params memory p, int256 imb, uint256 vol) public pure {
        _assumeValid(p, imb, vol);
        vm.assume(imb != 0);
        bool worseningDir = imb > 0; // for imb>0 the worsening direction is zeroForOne
        assert(p.fee(imb, worseningDir, vol) >= p.baseFee);
        assert(p.fee(imb, !worseningDir, vol) <= p.baseFee);
    }
}
