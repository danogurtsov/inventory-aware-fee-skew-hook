# inventory-aware fee skew hook

A Uniswap v4 hook that makes the LP fee **asymmetric**, skewed by the pool's current inventory
imbalance: cheaper to trade the pool back toward its target ratio, dearer to push it further out of
balance. The goal is to let a passive liquidity position lean against its own inventory the way a
professional market maker does — and to measure, honestly, how much of the inventory risk that actually
removes.

> **Bottom line (measured, not promised).** The inventory skew is **at least as good as the best-tuned
> static fee** in every regime tested, and it **leans ahead of the directional (Nezlobin) fee** on
> signal quality — a current-state signal has no lag, a last-move signal does. But the **absolute edge is
> small and, over many seeds, within noise**, and a *volatility-aware* fee beats a pure inventory signal
> under clustering volatility. The value here is the honest measurement framework and the signal-quality
> argument, not an outperformance headline. Full numbers, confidence intervals and caveats:
> [docs/RESULTS.md](docs/RESULTS.md).

## The problem: a passive LP is a market maker who can't manage inventory

Every trade against an AMM hands the liquidity provider the other side. When flow is one-directional —
arbitrageurs buying the token that is going up, selling the one going down — the LP is left **holding the
loser**: it sold the winner cheap and bought the loser on the way down. Accumulated, this inventory drift
is the directional core of impermanent loss and the reason most passive LPs underperform simply holding.

A professional market maker never lets this happen. When its inventory skews long, it **skews its
quotes** — cheaper to sell, dearer to buy — to offload the excess and pull its book back to neutral. This
is the century-old core of market making, formalized by Avellaneda–Stoikov (2008): quote around a
reservation price that leans away from mid in proportion to inventory, trading a little spread for a lot
less inventory risk.

An ordinary AMM cannot do this. Its fee is **symmetric** — the same to buy or to sell — so it has no way
to lean against its own inventory. It takes whatever position the flow forces on it and eats the drift.

## What this hook does

Because `beforeSwap` sees the trade's direction (`SwapParams.zeroForOne`), a v4 hook can charge a
**different fee per direction**:

```
fee(direction) = baseFee ± skew(inventory imbalance, volatility)
```

- **discount the rebalancing side** — trading the pool back toward its target ratio is cheaper, so
  arbitrageurs and rebalancers are paid (in lower fees) to unwind the LP's unwanted inventory;
- **surcharge the worsening side** — trading that deepens the imbalance costs more, so one-directional
  toxic flow pays for the inventory risk it imposes.

The skew is an inventory controller in the spirit of Avellaneda–Stoikov, and a cousin of Nezlobin's
directional fee — but keyed to **inventory state**, which is observable *now* on-chain, rather than to a
backward-looking volatility or price-direction estimate.

## What it is not

A fee cannot eliminate impermanent loss — it is provable that no single fee function zeroes IL across all
states (path-independent-fee theory). The honest goal is to **reduce inventory variance and directional
IL**, not to erase them. And an inventory signal, while lag-free, is still a *state*, not a prediction:
the skew reacts to imbalance, it does not foresee the next move.

## How it is measured

Fee revenue is a vanity metric. The verdict here is **LP net PnL vs a rebalancing benchmark**
(`fees − loss-versus-rebalancing`) and **inventory variance / terminal-inventory skew** — measured
against the *best* symmetric fee (found by a Monte-Carlo grid search) and against a directional
(price-based) fee, with a rational fee-aware arbitrageur, fee-elastic retail flow, realistic
(stochastic / historical) prices, normalized to capital and annualized, with confidence intervals. The
simulation harness lives in `test/sim/`; the fork backtests in `test/fork/`. Results, tables and the
honest caveats are in [docs/RESULTS.md](docs/RESULTS.md).

## Threat model & safety

- **Never reverts a swap the pool would accept.** The fee is always clamped to `[minFee, maxFee]` for
  both directions; proven by fuzz + a Halmos symbolic spec on `SkewCurve`, and by a stateful invariant
  campaign (`test/invariant/`) over tens of thousands of random swaps, retunes and pause toggles.
- **Reads state, holds none at risk.** `beforeSwap` reads the pool's `slot0` tick (O(1), no external
  calls that could reenter) and computes the fee from pure libraries.
- **Governed, not custodial.** An `Ownable2Step` owner can retune the curve/target (validated) and can
  `pause()` to fall back to a fixed symmetric `baseFee`; it never takes custody of funds.
- **Dynamic-fee only.** Initialization reverts on a static-fee pool (`NotDynamicFee`).
- A fee cannot eliminate impermanent loss (see "What it is not"); the design goal is variance reduction
  measured honestly, not a guarantee.

## Build & test

```bash
forge build
forge test          # unit, invariant and simulation tests — fully offline
```

The fork tests (`test/fork/`) need a mainnet RPC. Copy `.env.example` to `.env` and set `ETH_RPC_URL`
to any mainnet provider (dRPC, Alchemy, Infura, QuickNode, your own node). `.env` is gitignored — never
commit a real key. Without it, the fork suite skips automatically; everything else still runs.

The core fee math also carries a symbolic spec that machine-proves its bounds/sign guarantees over all
inputs (not just sampled fuzz). It uses the `check_` prefix, so `forge test` ignores it; run it with
[Halmos](https://github.com/a16z/halmos): `halmos --match-contract SkewCurveSymbolic`.

## Layout

```
src/
  InventoryAwareFeeSkewHook.sol   the hook (asymmetric beforeSwap fee)
  libraries/
    Inventory.sol                 pool inventory imbalance vs target
    SkewCurve.sol                 (imbalance, direction, vol) -> fee, bounded
  interfaces/IInventoryFeeHook.sol
script/Deploy.s.sol               HookMiner CREATE2 deploy
test/
  unit/                           SkewCurve, Inventory, hook wiring, governance
  invariant/                      fee bounded both directions, never reverts a swap
  halmos/                         symbolic spec for SkewCurve
  sim/                            evaluation harness + policy comparison
  fork/                           live mainnet pools + historical replay (ETH_RPC_URL)
```

## Prior art & references

- Avellaneda & Stoikov, *High-frequency trading in a limit order book* (2008) — inventory-aware MM canon.
- A. Nezlobin — directional (asymmetric) AMM fee.
- *Characterizing Path-Independent Fees: A Route to Zero Impermanent Loss in CPMMs* — the impossibility
  result that bounds what any fee can do.
- Milionis et al. — loss-versus-rebalancing (LVR), for the inventory-vs-adverse-selection framing.
- OpenZeppelin `uniswap-hooks` — the `BaseOverrideFee` base this hook builds on.

## License

MIT — see [LICENSE](LICENSE).
