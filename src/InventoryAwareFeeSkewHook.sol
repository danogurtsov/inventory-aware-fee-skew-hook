// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";
import {BaseOverrideFee} from "uniswap-hooks/fee/BaseOverrideFee.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Inventory} from "./libraries/Inventory.sol";
import {SkewCurve} from "./libraries/SkewCurve.sol";
import {IInventoryFeeHook} from "./interfaces/IInventoryFeeHook.sol";

/// @title InventoryAwareFeeSkewHook
/// @notice A Uniswap v4 hook that charges an **asymmetric** LP fee, skewed by the pool's current
///         inventory imbalance: the direction that rebalances the pool toward its target composition
///         is discounted, the direction that worsens the imbalance is surcharged. Built on
///         OpenZeppelin's `BaseOverrideFee` (per-swap fee override).
/// @dev The signal is read fresh from the pool's `slot0` tick on every swap — inventory is a *current
///      state*, so there is no observation to accumulate and no lag, unlike a volatility- or
///      price-direction-based fee. `beforeSwap` sees `SwapParams.zeroForOne`, which is what makes a
///      different fee per direction possible at all.
/// @dev The owner can retune the inventory config and the skew curve, and can pause to fall back to a
///      fixed symmetric `baseFee` in both directions — without ever reverting a swap.
contract InventoryAwareFeeSkewHook is BaseOverrideFee, Ownable2Step, Pausable, IInventoryFeeHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using Inventory for Inventory.Config;
    using SkewCurve for SkewCurve.Params;

    Inventory.Config internal _invConfig;
    SkewCurve.Params internal _skewParams;

    constructor(
        IPoolManager poolManager_,
        address initialOwner,
        Inventory.Config memory invConfig_,
        SkewCurve.Params memory skewParams_
    ) BaseHook(poolManager_) Ownable(initialOwner) {
        _setInventoryConfig(invConfig_);
        _setSkewParams(skewParams_);
    }

    // --- owner controls -------------------------------------------------------

    /// @notice Retune the inventory signal (range and target composition).
    function setInventoryConfig(Inventory.Config calldata invConfig_) external onlyOwner {
        _setInventoryConfig(invConfig_);
    }

    /// @notice Retune the skew curve (base/min/max fee and slopes).
    function setSkewParams(SkewCurve.Params calldata skewParams_) external onlyOwner {
        _setSkewParams(skewParams_);
    }

    /// @notice Pause skew; swaps then pay a fixed symmetric `baseFee`. Never reverts a swap.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume inventory-skew pricing.
    function unpause() external onlyOwner {
        _unpause();
    }

    // --- fee logic ------------------------------------------------------------

    /// @dev The direction-specific inventory-skew fee. Reads the current tick, turns it into a signed
    ///      imbalance, and asks the skew curve for the fee of the swap's direction. When paused, falls
    ///      back to the symmetric `baseFee`. Never reverts.
    function _getFee(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        view
        override
        returns (uint24)
    {
        if (paused()) return _skewParams.baseFee;
        int256 imbalance = Inventory.imbalanceWad(_currentTick(key), _invConfig);
        return _skewParams.fee(imbalance, params.zeroForOne, 0);
    }

    // --- views (IInventoryFeeHook) -------------------------------------------

    /// @inheritdoc IInventoryFeeHook
    function currentImbalance(PoolKey calldata key) external view returns (int256) {
        return Inventory.imbalanceWad(_currentTick(key), _invConfig);
    }

    /// @inheritdoc IInventoryFeeHook
    function currentFee(PoolKey calldata key, bool zeroForOne) external view returns (uint24) {
        if (paused()) return _skewParams.baseFee;
        int256 imbalance = Inventory.imbalanceWad(_currentTick(key), _invConfig);
        return _skewParams.fee(imbalance, zeroForOne, 0);
    }

    /// @notice Current inventory config.
    function inventoryConfig() external view returns (Inventory.Config memory) {
        return _invConfig;
    }

    /// @notice Current skew-curve params.
    function skewParams() external view returns (SkewCurve.Params memory) {
        return _skewParams;
    }

    // --- internal -------------------------------------------------------------

    function _setInventoryConfig(Inventory.Config memory c) internal {
        c.validate();
        _invConfig = c;
        emit InventoryConfigUpdated(c.tickLower, c.tickUpper, c.targetToken0Wad);
    }

    function _setSkewParams(SkewCurve.Params memory p) internal {
        p.validate();
        _skewParams = p;
        emit SkewParamsUpdated(p.baseFee, p.minFee, p.maxFee, p.slope);
    }

    function _currentTick(PoolKey calldata key) internal view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(key.toId());
    }
}
