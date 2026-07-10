# Results

An honest account of what the inventory-aware fee skew does and does not achieve, measured with the
harness in `test/sim/` and the fork tests in `test/fork/`. Read the bottom line first.

## Bottom line

- **The inventory skew never breaks the LP.** Across every regime tested (persistent trend, efficient
  random walk, clustering volatility, concentrated liquidity, and a live-seeded historical replay) its
  LP net PnL is **at least as good as the best-tuned static symmetric fee**. It is not a downgrade.
- **It wins on signal quality, not on a big number.** A fee keyed to the pool's *current inventory
  state* has no lag, whereas the closest prior art — Nezlobin's directional fee — reacts to the *last
  price move*. In a trend and in an efficient random walk, the inventory policy edges ahead of the
  directional one.
- **But the absolute edge is small and, over many seeds, within noise.** A 10-seed Monte Carlo puts the
  inventory-over-directional LP-net edge at **+0.07%** on average with a 95% confidence interval that
  **includes zero**. The flattering single-seed figures are not representative.
- **A pure inventory signal is beaten by a volatility-aware fee under clustering volatility.** When
  volatility clusters, the directional fee's move-magnitude signal implicitly tracks the vol regime and
  wins. This is why the fee curve carries a volatility term; a complete design pairs the two.

The contribution of this repo is the **honest measurement framework** and the **signal-quality argument
(state beats a lagged estimate)** — not an outperformance headline. A fee cannot escape the fact that,
in a pool arbitraged to the external market, LP inventory is a function of price, not of the fee.

## Why the effect is inherently small

In a CPMM whose price is held at the external market by arbitrage, the LP's inventory is essentially a
deterministic function of the current price. The fee skew changes *who* trades (it discounts the
rebalancing side and surcharges the worsening side) and it shifts the no-arbitrage band slightly — but it
cannot move the inventory trajectory much, because inventory is pinned to price and price is pinned to the
market. So the mechanism's ceiling is low by construction. This matches the impossibility result that no
fee can eliminate impermanent loss across all states (see `README` references).

## Method

- **Objective metric:** LP net PnL versus a rebalancing benchmark (`fees − loss-versus-rebalancing`),
  valuing every trade at the external price of its block; plus inventory variance / terminal skew.
  Normalized to basis points of LP capital and annualized on a 12-second clock.
- **Agents:** a rational, fee-aware arbitrageur that trades only to the no-arbitrage band (per
  direction, so it responds to the asymmetric fee) and fee-elastic retail flow (linear demand with a
  choke price, which makes fee revenue a Laffer curve).
- **Baselines:** the **best static symmetric fee** (found by a Monte-Carlo grid search — an interior
  optimum at ~0.30% here, a genuinely strong opponent) and the **directional (Nezlobin) fee**.
- **Robustness:** stochastic clustering (Heston-ish) volatility, a narrow-range concentrated variant,
  Monte Carlo over seeds with confidence intervals, and a live historical replay from Uniswap v3
  `observe` data.

All figures below are LP net PnL on an identical price path per row; higher is better. Raw wad units are
used where annualized bps rounding would erase the (small) differences.

## Signal comparison across regimes

Mean LP net over a few seeds; wide range unless noted.

| regime                              | best static | directional (Nezlobin) | inventory skew |
|-------------------------------------|-------------|------------------------|----------------|
| persistent trend                    | 104.60e18   | 104.58e18              | **104.67e18**  |
| efficient random walk               | 104.69e18   | 104.18e18              | **104.78e18**  |
| clustering volatility (no drift)    | 104.74e18   | **105.06e18**          | 104.85e18      |
| concentrated (narrow range, ratio)  | baseline    | −0.3% vs static        | **+0.85% vs static** |

Reading:
- In the **trend** and **random walk**, inventory ≥ static ≥ or ≈ directional; the directional fee even
  underperforms a plain static fee on the random walk, because its backward-looking signal reacts to
  noise.
- Under **clustering volatility**, the ordering flips: the directional fee's magnitude signal tracks the
  (persistent) volatility regime and wins. The pure inventory signal is blind to volatility.
- Under **concentration**, the relative picture is amplified (a tighter position carries more inventory
  risk per unit capital), and inventory leads — but see the caveat below.

## Monte Carlo (the significance check)

Paired `inventory − directional` LP net, efficient random walk, 10 seeds, 80 blocks:

| statistic                | value      |
|--------------------------|------------|
| mean (inv − dir)         | +0.068e18  |
| standard error           |  0.097e18  |
| 95% CI lower bound        | −0.126e18 |
| seeds where inv > dir     | 6 / 10    |

The edge is **positive on average and wins the majority of paths, but is not statistically
significant** — the confidence interval includes zero, and reaching significance would need ~80+ seeds.
Report it as a small, noisy lean, not a win.

## Caveats (limits of the model)

- The `SimPool` uses **constant liquidity** and the real Uniswap v4 swap math (`SwapMath`), so it is
  faithful *within an active range* but does not model liquidity running out at range edges. In the
  **concentrated** case this makes the *absolute* annualized figures implausibly large (~340×/yr);
  only the **relative ordering** is meaningful there — quote it as a ratio, never as a yield.
- Volatility is calibrated to a realistic band (~93%/yr for the base regime); the calibration is
  asserted in `test/sim/Normalize.t.sol`.
- The historical replay is a short (~80-block) window of calm ETH/USDC data; it checks the mechanism does
  not break the LP on real dynamics rather than proving outperformance.

## Open problems / future work

- **Wire a realized-volatility estimate into the skew's volatility term.** The pure inventory signal
  loses to a vol-aware fee under clustering volatility; the curve already supports a `volSlope`, so the
  natural next step is to feed a live vol estimate and show the vol-aware inventory skew closes that gap.
- **Longer, more varied historical windows** (turbulent periods, multiple pairs) to test the sign of the
  edge on real data with confidence intervals.
- **A strategic-arb adversary** that games the predictable directional discount, to bound how much value
  the skew can hand away.
