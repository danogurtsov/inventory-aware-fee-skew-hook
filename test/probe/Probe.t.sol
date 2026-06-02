// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {Probe} from "../../src/probe/Probe.sol";

/// @dev Proves the OZ uniswap-hooks bundled tree wires up end-to-end: mine a flagged hook
///      address, deploy a `BaseOverrideFee` subclass against a fresh v4 PoolManager, and read
///      the dynamic-fee flag constant. If this compiles and passes, the real hook can be built
///      on the same deps. Deleted once the real hook exists.
contract ProbeTest is Test, Deployers {
    Probe internal probe;

    function setUp() public {
        deployFreshManagerAndRouters();

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        bytes memory args = abi.encode(manager);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(Probe).creationCode, args);
        probe = new Probe{salt: salt}(manager);
        assertEq(address(probe), expected);
    }

    function test_deploysAtFlaggedAddress() public view {
        // The mined address must carry the beforeSwap permission bit.
        assertTrue(uint160(address(probe)) & Hooks.BEFORE_SWAP_FLAG != 0);
    }

    function test_dynamicFeeFlagReachable() public view {
        assertEq(probe.dynamicFeeFlag(), LPFeeLibrary.DYNAMIC_FEE_FLAG);
    }
}
