// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Temporary dependency-wiring probe. It exists only to prove that the OpenZeppelin
// `uniswap-hooks` bundled tree (its matched v4-core / v4-periphery) resolves under our
// remappings, pragma and evm version *before* any real contract is written. It is deleted
// once the real hook lands (commit 13). It intentionally references the exact surfaces the
// hook will use: BaseOverrideFee, StateLibrary, HookMiner, and SwapParams.zeroForOne.

import {BaseOverrideFee} from "uniswap-hooks/fee/BaseOverrideFee.sol";
import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @dev A minimal `BaseOverrideFee` subclass. Returns a fixed fee and reads the swap direction,
///      exercising the same imports the inventory hook will depend on.
contract Probe is BaseOverrideFee {
    using StateLibrary for IPoolManager;

    uint24 internal constant PROBE_FEE = 3000; // 0.30% in pips

    constructor(IPoolManager poolManager_) BaseHook(poolManager_) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
    }

    /// @dev Direction-aware constant fee — proves `SwapParams.zeroForOne` is readable in this callback.
    function _getFee(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        internal
        pure
        override
        returns (uint24)
    {
        // The asymmetric hook will branch on this; here we only prove the field resolves.
        return params.zeroForOne ? PROBE_FEE : PROBE_FEE;
    }

    /// @dev Prove the dynamic-fee flag constant is reachable from the bundled v4-core.
    function dynamicFeeFlag() external pure returns (uint24) {
        return LPFeeLibrary.DYNAMIC_FEE_FLAG;
    }
}
