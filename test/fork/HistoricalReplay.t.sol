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

/// @notice A genuine historical backtest: replays a real mainnet pool's actual per-12s tick path
///         (reconstructed from v3 `observe` tick-cumulatives) as the external price the agents trade
///         against, then compares the policies over that real path. Requires `ETH_RPC_URL`; skips
///         cleanly when unset. This is the honesty check the sibling repo taught — real price dynamics
///         can behave differently from any synthetic path, so the conclusion must survive them.
contract HistoricalReplayTest is SkewSim {
    address internal constant ETH_USDC_V3 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    uint32 internal constant BLOCK_SECS = 12;
    uint256 internal constant NBLOCKS = 80;

    Market internal _mkt;

    function market() internal view override returns (Market memory) {
        return _mkt;
    }

    function _buildReplayFromPool(address pool) internal returns (int24 startTick) {
        // secondsAgos: NBLOCKS+1 samples 12s apart, newest last.
        uint32[] memory ago = new uint32[](NBLOCKS + 1);
        for (uint256 i = 0; i <= NBLOCKS; i++) {
            ago[i] = uint32((NBLOCKS - i) * BLOCK_SECS);
        }
        (int56[] memory cum,) = IUniswapV3Pool(pool).observe(ago);

        // Average tick over each 12s interval = (cum[i+1] - cum[i]) / 12; use it as that block's level.
        delete replayTicks;
        for (uint256 i = 0; i < NBLOCKS; i++) {
            int56 d = cum[i + 1] - cum[i];
            // safe: an average tick over 12s is a real pool tick, far inside int24 range.
            // forge-lint: disable-next-line(unsafe-typecast)
            replayTicks.push(int24(d / int56(uint56(BLOCK_SECS))));
        }
        replayEnabled = true;
        return replayTicks[0];
    }

    function _curve() internal pure returns (SkewCurve.Params memory) {
        return SkewCurve.Params({baseFee: 3000, minFee: 100, maxFee: 10_000, slope: 40_000, volSlope: 0});
    }

    function test_historicalReplay() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            emit log("ETH_RPC_URL unset - skipping historical replay");
            return;
        }
        vm.createSelectFork(rpc);

        int24 startTick = _buildReplayFromPool(ETH_USDC_V3);
        assertEq(replayTicks.length, NBLOCKS, "replay path fully built from live observe");

        _mkt = Market({
            startTick: startTick,
            stepTicks: 1, // unused under replay
            driftTicks: 0,
            liquidity: 1e23,
            tickLower: startTick - 60_000,
            tickUpper: startTick + 60_000,
            blocks: NBLOCKS,
            retailBase: 5e20,
            retailChokeFee: 12000
        });
        Inventory.Config memory invCfg = Inventory.Config({
            tickLower: startTick - 60_000, tickUpper: startTick + 60_000, targetToken0Wad: 0.5e18
        });

        _useStatic(3000);
        int256 stat = _run(1).lpNetWad;

        _useDirectional(
            SkewCurve.Params({baseFee: 3000, minFee: 100, maxFee: 10_000, slope: 75, volSlope: 0})
        );
        int256 dir = _run(1).lpNetWad;

        _useSkew(invCfg, _curve());
        int256 inv = _run(1).lpNetWad;

        emit log_named_int("replay static  lpNet wad", stat);
        emit log_named_int("replay direct  lpNet wad", dir);
        emit log_named_int("replay invskew lpNet wad", inv);

        // The only hard claim on real data: the mechanism does not break the LP. Whether inventory
        // beats the others on calm real ETH/USDC data is reported, not asserted — real dynamics can
        // differ from synthetic regimes, and that conditional result is itself a finding.
        assertGe(inv, stat, "invskew >= static on the real historical path");
    }
}
