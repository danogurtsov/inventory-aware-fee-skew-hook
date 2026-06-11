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

    /// @notice Fee-elastic retail notional: linear demand that chokes off at a maximum fee.
    /// @dev `notional = base * (choke - fee) / choke` for `fee < choke`, else `0`. Linear demand is
    ///      what makes fee revenue a *Laffer curve* — `revenue = notional * fee` is a parabola that
    ///      peaks at an interior fee and then falls as flow walks away. That interior peak is why a
    ///      best static fee exists to be found (and beaten), instead of "always charge more".
    function retailNotional(uint256 baseNotional, uint24 feePips, uint24 chokeFeePips)
        internal
        pure
        returns (uint256)
    {
        if (feePips >= chokeFeePips) return 0;
        return (baseNotional * (chokeFeePips - feePips)) / chokeFeePips;
    }
}
