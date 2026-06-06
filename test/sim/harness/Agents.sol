// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Agents
/// @notice Pure behavioural primitives for the two market participants in the simulation.
/// @dev Kept pure and separate so the economic assumptions are testable in isolation. Both
///      primitives are *fee-aware*, and both accept a per-direction fee — the whole point of the
///      hook is an asymmetric fee, so the agents must respond to it from the very first commit
///      (a fee-inelastic or direction-blind agent is exactly what flattered the sibling repo).
library Agents {
    /// @notice No-arbitrage half-band in ticks implied by a fee.
    /// @dev A tick is ~1 basis point, and a fee of `feePips` is `feePips/100` bips, so the arb only
    ///      profits once the pool is more than ~`feePips/100` ticks away from the external price. It
    ///      therefore trades the pool to that band edge and stops — it does not close the gap fully.
    ///      This is what turns the fee into a real cost of arbitrage rather than a free transfer.
    function bandTicks(uint24 feePips) internal pure returns (int24) {
        // safe: feePips/100 <= MAX_LP_FEE/100 = 10_000, well within int24.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(uint24(feePips / 100));
    }

    /// @notice Fee-elastic retail notional: base flow scaled down as the fee rises.
    /// @dev `notional = base * ref / (ref + fee)`. At zero fee it equals `base`; it decreases
    ///      monotonically toward zero as the fee grows, and never goes negative. `refFeePips` sets
    ///      the sensitivity scale (the fee at which retail flow halves).
    function retailNotional(uint256 baseNotional, uint24 feePips, uint24 refFeePips)
        internal
        pure
        returns (uint256)
    {
        return (baseNotional * refFeePips) / (uint256(refFeePips) + feePips);
    }
}
