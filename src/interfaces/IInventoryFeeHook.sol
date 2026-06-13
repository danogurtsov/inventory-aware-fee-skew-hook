// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IInventoryFeeHook
/// @notice External surface of the inventory-aware fee-skew hook.
interface IInventoryFeeHook {
    event InventoryConfigUpdated(int24 tickLower, int24 tickUpper, uint256 targetToken0Wad);
    event SkewParamsUpdated(uint24 baseFee, uint24 minFee, uint24 maxFee, uint256 slope);

    /// @notice The pool's current signed inventory imbalance in `[-1e18, +1e18]`.
    function currentImbalance(PoolKey calldata key) external view returns (int256);

    /// @notice The fee (pips) the hook would charge `key` for a swap in the given direction.
    /// @param zeroForOne True for a token0 -> token1 swap (pushes the price down).
    function currentFee(PoolKey calldata key, bool zeroForOne) external view returns (uint24);
}
