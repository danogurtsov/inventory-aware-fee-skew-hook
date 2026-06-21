// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {InventoryAwareFeeSkewHook} from "../../src/InventoryAwareFeeSkewHook.sol";
import {Inventory} from "../../src/libraries/Inventory.sol";
import {SkewCurve} from "../../src/libraries/SkewCurve.sol";

/// @notice Governance and safety controls: only the owner retunes the config/curve, pausing falls
///         back to a symmetric fee, and the dynamic-fee guard rejects a static-fee pool.
contract HookConfigTest is Test, Deployers {
    InventoryAwareFeeSkewHook internal hook;
    address internal owner = address(0xB0B);
    address internal stranger = address(0xBAD);

    Inventory.Config internal invCfg =
        Inventory.Config({tickLower: -1000, tickUpper: 1000, targetToken0Wad: 0.5e18});
    SkewCurve.Params internal skew =
        SkewCurve.Params({baseFee: 3000, minFee: 100, maxFee: 10_000, slope: 5000, volSlope: 0});

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        bytes memory args = abi.encode(manager, owner, invCfg, skew);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(InventoryAwareFeeSkewHook).creationCode, args);
        hook = new InventoryAwareFeeSkewHook{salt: salt}(manager, owner, invCfg, skew);
        assertEq(address(hook), expected);
        (key,) = initPoolAndAddLiquidity(
            currency0,
            currency1,
            IHooks(address(hook)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            TickMath.getSqrtPriceAtTick(500)
        );
    }

    // --- ownership ------------------------------------------------------------

    function test_onlyOwnerSetsSkewParams() public {
        SkewCurve.Params memory p =
            SkewCurve.Params({baseFee: 1000, minFee: 50, maxFee: 5000, slope: 2000, volSlope: 0});

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        hook.setSkewParams(p);

        vm.prank(owner);
        hook.setSkewParams(p);
        assertEq(hook.skewParams().baseFee, 1000, "owner retuned the curve");
    }

    function test_onlyOwnerSetsInventoryConfig() public {
        Inventory.Config memory c =
            Inventory.Config({tickLower: -500, tickUpper: 500, targetToken0Wad: 0.6e18});

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        hook.setInventoryConfig(c);

        vm.prank(owner);
        hook.setInventoryConfig(c);
        assertEq(hook.inventoryConfig().targetToken0Wad, 0.6e18, "owner retuned the signal");
    }

    function test_setterValidatesParams() public {
        // baseFee above maxFee must revert through the library validator.
        SkewCurve.Params memory bad =
            SkewCurve.Params({baseFee: 9000, minFee: 100, maxFee: 5000, slope: 0, volSlope: 0});
        vm.expectRevert(SkewCurve.BaseAboveMax.selector);
        vm.prank(owner);
        hook.setSkewParams(bad);
    }

    // --- pausing --------------------------------------------------------------

    function test_pausedFeeIsSymmetricBase() public {
        // While skewed, the fee is asymmetric.
        assertTrue(hook.currentFee(key, true) != hook.currentFee(key, false), "asymmetric when live");

        vm.prank(owner);
        hook.pause();

        // Paused: both directions collapse to the plain baseFee.
        assertEq(hook.currentFee(key, true), skew.baseFee, "paused -> base (zeroForOne)");
        assertEq(hook.currentFee(key, false), skew.baseFee, "paused -> base (oneForZero)");

        vm.prank(owner);
        hook.unpause();
        assertTrue(
            hook.currentFee(key, true) != hook.currentFee(key, false), "asymmetric again after unpause"
        );
    }

    function test_onlyOwnerPauses() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        hook.pause();
    }

    // --- dynamic-fee guard ----------------------------------------------------

    function test_rejectsStaticFeePool() public {
        vm.expectRevert();
        initPool(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0));
    }
}
