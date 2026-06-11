// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SimBase} from "./SimBase.sol";

/// @notice Establishes the baseline every mechanism must beat: the **best-tuned static symmetric
///         fee**, found by a Monte-Carlo grid search over LP net. The sibling repo's central mistake
///         was comparing against a naive fee tier; here the bar is the best static fee, so any claim
///         the skew makes is a claim over a genuinely strong opponent.
contract BaselinesTest is SimBase {
    Market internal _mkt;

    // Candidate static fees (pips): 0.01% .. 1.00%.
    uint24[6] internal FEES = [uint24(100), 300, 500, 1000, 3000, 10_000];
    uint256 internal constant SEEDS = 3; // averaged per fee (kept small for gas)

    function market() internal view override returns (Market memory) {
        return _mkt;
    }

    function _base() internal {
        _mkt = Market({
            startTick: 0,
            stepTicks: 10,
            driftTicks: 0,
            liquidity: 1e23,
            tickLower: -60_000,
            tickUpper: 60_000,
            blocks: 120, // trimmed vs the metric tests to keep the whole grid under the gas limit
            retailBase: 5e20,
            retailChokeFee: 12000
        });
    }

    /// @dev Mean LP net (annualized bps) for a static symmetric `fee` across SEEDS paths.
    function _meanNet(uint24 fee) internal returns (int256) {
        staticFeePips = fee;
        int256 acc;
        for (uint256 s = 1; s <= SEEDS; s++) {
            acc += _run(s * 101).lpNetAnnualBps;
        }
        // safe: SEEDS is a small positive constant, exact within int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        return acc / int256(uint256(SEEDS));
    }

    /// @notice Grid-search the static symmetric fee in one pass; returns best and worst grid points.
    function bestSymmetric() public returns (uint24 bestFee, int256 bestNet, int256 worstNet) {
        _base();
        bestNet = type(int256).min;
        worstNet = type(int256).max;
        for (uint256 i = 0; i < FEES.length; i++) {
            int256 net = _meanNet(FEES[i]);
            emit log_named_int(_feeLabel(FEES[i]), net);
            if (net > bestNet) {
                bestNet = net;
                bestFee = FEES[i];
            }
            if (net < worstNet) worstNet = net;
        }
        emit log_named_uint("best fee (pips)", bestFee);
        emit log_named_int("best net (annual bps)", bestNet);
    }

    function test_gridHasAWellDefinedOptimum() public {
        (uint24 bestFee, int256 bestNet, int256 worstNet) = bestSymmetric();

        // A best fee was selected, and the fee level materially changes LP net (a real tradeoff, not
        // "always charge more"): the best strictly beats the worst grid point.
        assertTrue(bestFee != 0, "a best fee was selected");
        assertGt(bestNet, worstNet, "the fee level materially changes LP net");

        // The optimum is interior: too low bleeds LVR, too high drives retail away (a Laffer peak).
        // This is what makes it a strong baseline — the skew must beat a genuinely well-tuned fee.
        assertTrue(bestFee != FEES[0] && bestFee != FEES[FEES.length - 1], "optimum is interior");
    }

    function _feeLabel(uint24 fee) internal pure returns (string memory) {
        return string.concat("net @ fee ", vm.toString(uint256(fee)), " pips");
    }
}
