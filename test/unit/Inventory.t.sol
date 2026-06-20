// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Inventory} from "../../src/libraries/Inventory.sol";

/// @notice Smoke tests for the inventory signal: it saturates at the range ends and sits at zero at
///         the target composition. Exhaustive table + fuzz coverage is added alongside the mechanism.
contract InventoryTest is Test {
    using Inventory for Inventory.Config;

    function _cfg() internal pure returns (Inventory.Config memory) {
        // Symmetric range around tick 0 with a 50/50 target.
        return Inventory.Config({tickLower: -1000, tickUpper: 1000, targetToken0Wad: 0.5e18});
    }

    function test_lowerEdgeIsAllToken0() public pure {
        // Price at the lower tick: the position is entirely token0 -> +1.
        assertApproxEqAbs(Inventory.imbalanceWad(-1000, _cfg()), int256(1e18), 1e12);
    }

    function test_upperEdgeIsAllToken1() public pure {
        // Price at the upper tick: entirely token1 -> -1.
        assertApproxEqAbs(Inventory.imbalanceWad(1000, _cfg()), -int256(1e18), 1e12);
    }

    function test_centerIsBalanced() public pure {
        // At the mid tick with a 50/50 target the imbalance is ~0.
        assertApproxEqAbs(Inventory.imbalanceWad(0, _cfg()), int256(0), 1e15);
    }

    function test_monotoneDecreasingInPrice() public pure {
        int256 low = Inventory.imbalanceWad(-500, _cfg());
        int256 mid = Inventory.imbalanceWad(0, _cfg());
        int256 high = Inventory.imbalanceWad(500, _cfg());
        assertGt(low, mid, "more token0 at lower price");
        assertGt(mid, high, "less token0 at higher price");
    }

    function test_validateRejectsBadConfig() public {
        vm.expectRevert(Inventory.InvalidRange.selector);
        this.validateExt(Inventory.Config({tickLower: 100, tickUpper: 100, targetToken0Wad: 0.5e18}));

        vm.expectRevert(Inventory.InvalidTarget.selector);
        this.validateExt(Inventory.Config({tickLower: -1000, tickUpper: 1000, targetToken0Wad: 0}));
    }

    /// @dev External wrapper so `vm.expectRevert` can catch the library's internal revert.
    function validateExt(Inventory.Config memory c) public pure {
        c.validate();
    }

    // --- exhaustive coverage --------------------------------------------------

    function testFuzz_alwaysInUnitRange(int24 tick, int24 lower, int24 width, uint256 target) public pure {
        lower = int24(bound(lower, -100_000, 100_000));
        width = int24(bound(width, 10, 100_000));
        int24 upper = lower + width;
        target = bound(target, 1, 1e18 - 1);
        Inventory.Config memory c =
            Inventory.Config({tickLower: lower, tickUpper: upper, targetToken0Wad: target});
        int256 imb = Inventory.imbalanceWad(tick, c);
        assertGe(imb, -int256(1e18), "imbalance below -1");
        assertLe(imb, int256(1e18), "imbalance above +1");
    }

    function testFuzz_saturatesOutsideRange(int24 tick) public pure {
        Inventory.Config memory c = _cfg(); // [-1000, 1000]
        // Below the range the position is all token0 (+1); above it, all token1 (-1).
        if (tick <= -1000) {
            assertApproxEqAbs(
                Inventory.imbalanceWad(tick, c), int256(1e18), 1e12, "clamped to +1 below range"
            );
        } else if (tick >= 1000) {
            assertApproxEqAbs(
                Inventory.imbalanceWad(tick, c), -int256(1e18), 1e12, "clamped to -1 above range"
            );
        }
    }

    function test_narrowRangeSaturatesFast() public pure {
        // A tight range hits full imbalance within a few ticks — concentration reacts sharply.
        Inventory.Config memory narrow =
            Inventory.Config({tickLower: -50, tickUpper: 50, targetToken0Wad: 0.5e18});
        int256 imbAt40 = Inventory.imbalanceWad(-40, narrow);

        Inventory.Config memory wide = _cfg(); // [-1000, 1000]
        int256 imbAt40Wide = Inventory.imbalanceWad(-40, wide);

        // Same 40-tick move from center is a far larger imbalance in the tighter range.
        assertGt(imbAt40, imbAt40Wide, "narrow range is more sensitive to a given move");
    }

    function test_asymmetricTargetShiftsZeroPoint() public pure {
        // A target that wants more token0 (70%) reads a center-price pool as already short token0.
        Inventory.Config memory c =
            Inventory.Config({tickLower: -1000, tickUpper: 1000, targetToken0Wad: 0.7e18});
        int256 atCenter = Inventory.imbalanceWad(0, c);
        assertLt(atCenter, int256(0), "below a high token0 target, the pool reads as under-weight token0");
    }
}
