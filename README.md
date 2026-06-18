# inventory-aware fee skew hook

A Uniswap v4 hook that makes the LP fee **asymmetric**, skewed by the pool's current inventory
imbalance: cheaper to trade the pool back toward its target ratio, dearer to push it further out of
balance. The goal is to let a passive liquidity position lean against its own inventory the way a
professional market maker does — and to measure, honestly, how much of the inventory risk that actually
removes.

> Status: work in progress. The verdict section below is a placeholder until the simulation suite is in
> place — this repo's whole point is to measure the mechanism against the right baselines before making
> any claim.

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

## How it is measured (verdict — TBD until the sim lands)

Fee revenue is a vanity metric. The verdict here is **LP net PnL vs a rebalancing benchmark** and,
specifically, **inventory variance / terminal-inventory skew** — measured against the *best* symmetric
fee and against a directional (price-based) fee, with a rational fee-aware arbitrageur, fee-elastic
retail flow, realistic (stochastic / historical) prices, normalized to capital and annualized, with
confidence intervals. Numbers land here once the simulation suite is complete.

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
  InventoryAwareFeeSkewHook.sol   the hook (asymmetric beforeSwap fee)      — TBD
  libraries/
    Inventory.sol                 pool inventory imbalance vs target        — TBD
    SkewCurve.sol                 (imbalance, direction, vol) -> fee, bounded — TBD
test/
  unit/ invariant/ sim/ fork/     correctness, safety, evaluation, real pools
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
