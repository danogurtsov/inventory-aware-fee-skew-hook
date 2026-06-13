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
}
