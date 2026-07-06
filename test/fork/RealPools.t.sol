// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SkewSim} from "../sim/SkewSim.sol";
import {Inventory} from "../../src/libraries/Inventory.sol";
import {SkewCurve} from "../../src/libraries/SkewCurve.sol";

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @notice Exercises the mechanism against *live* mainnet price state. Requires `ETH_RPC_URL`; skips
///         cleanly when it is unset so offline CI stays green. Reads each pool's current tick and
///         checks the inventory signal and skew fee are sane and correctly asymmetric on real data,
///         then seeds the three-policy comparison at the live price level.
/// @dev The hook is not attached to these v3 pools (a v4 hook binds at pool creation); this validates
///      the library logic and the harness on genuine on-chain ticks.
contract RealPoolsForkTest is SkewSim {
    Market internal _mkt;

    struct RealPool {
        string name;
        address v3pool;
        uint24 step;
    }

    function market() internal view override returns (Market memory) {
        return _mkt;
    }

    function _skipUnlessFork() internal returns (bool forked) {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            emit log("ETH_RPC_URL unset - skipping fork test");
            return false;
        }
        vm.createSelectFork(rpc);
        return true;
    }

    function _pools() internal pure returns (RealPool[3] memory) {
        return [
            RealPool("ETH/USDC  0.05%", 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640, 120),
            RealPool("WBTC/ETH  0.30%", 0xCBCdF9626bC03E24f779434178A73a0B4bad62eD, 200),
            RealPool("USDC/USDT 0.01%", 0x3416cF6C708Da44DB2624D63ea0AAef7113527C6, 20)
        ];
    }

    function _curve() internal pure returns (SkewCurve.Params memory) {
        return SkewCurve.Params({baseFee: 3000, minFee: 100, maxFee: 10_000, slope: 40_000, volSlope: 0});
    }

    function test_forkSignalAndFeeOnLiveTicks() public {
        if (!_skipUnlessFork()) return;

        RealPool[3] memory pools = _pools();
        SkewCurve.Params memory curve = _curve();

        for (uint256 i; i < pools.length; i++) {
            (, int24 liveTick,,,,,) = IUniswapV3Pool(pools[i].v3pool).slot0();
            emit log_string(pools[i].name);
            emit log_named_int("  live mainnet tick", liveTick);

            // A range centred on the live tick reads as balanced -> symmetric base fee both ways.
            Inventory.Config memory centered = Inventory.Config({
                tickLower: liveTick - 2000, tickUpper: liveTick + 2000, targetToken0Wad: 0.5e18
            });
            assertEq(SkewCurve.fee(curve, Inventory.imbalanceWad(liveTick, centered), true, 0), curve.baseFee);
            assertEq(
                SkewCurve.fee(curve, Inventory.imbalanceWad(liveTick, centered), false, 0), curve.baseFee
            );

            // A range whose centre sits below the live price reads as excess token1 -> asymmetric fee,
            // and both directions stay inside the curve bounds.
            Inventory.Config memory shifted =
                Inventory.Config({tickLower: liveTick - 4000, tickUpper: liveTick, targetToken0Wad: 0.5e18});
            int256 imb = Inventory.imbalanceWad(liveTick, shifted);
            uint24 z = SkewCurve.fee(curve, imb, true, 0);
            uint24 o = SkewCurve.fee(curve, imb, false, 0);
            assertTrue(z != o, "asymmetric on a live off-centre state");
            assertGe(z, curve.minFee);
            assertLe(z, curve.maxFee);
            assertGe(o, curve.minFee);
            assertLe(o, curve.maxFee);
        }
    }

    function test_forkComparisonSeededByLivePrice() public {
        if (!_skipUnlessFork()) return;

        RealPool[3] memory pools = _pools();
        for (uint256 i; i < pools.length; i++) {
            (, int24 liveTick,,,,,) = IUniswapV3Pool(pools[i].v3pool).slot0();

            _mkt = Market({
                startTick: liveTick,
                stepTicks: pools[i].step,
                driftTicks: 0,
                liquidity: 1e23,
                tickLower: liveTick - 60_000,
                tickUpper: liveTick + 60_000,
                blocks: 80,
                retailBase: 5e20,
                retailChokeFee: 12000
            });
            Inventory.Config memory invCfg = Inventory.Config({
                tickLower: liveTick - 60_000, tickUpper: liveTick + 60_000, targetToken0Wad: 0.5e18
            });

            _useStatic(3000);
            int256 stat = _run(1).lpNetWad;
            _useSkew(invCfg, _curve());
            int256 inv = _run(1).lpNetWad;

            emit log_string(pools[i].name);
            emit log_named_int("  static lpNet wad", stat);
            emit log_named_int("  invskew lpNet wad", inv);
            // On a live-seeded path the skew still does not break the LP.
            assertGe(inv, stat, "invskew >= static on a live-seeded path");
        }
    }
}
