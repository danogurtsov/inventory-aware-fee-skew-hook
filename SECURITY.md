# Security

This is research/portfolio code, not audited, and is provided as-is (see the MIT license). Do not deploy
it to mainnet with real funds without an independent audit.

## Design safety properties

- The LP fee is always within `[minFee, maxFee]` for both swap directions — enforced structurally in
  `SkewCurve`, checked by fuzz tests, machine-proven by a Halmos symbolic spec, and held across a
  stateful invariant campaign.
- The hook never reverts a swap a vanilla pool would accept.
- `beforeSwap` performs no external calls that could reenter; it reads `slot0` and computes a pure fee.
- Owner controls are `Ownable2Step`; the owner can retune (with validation) or pause to a fixed
  symmetric fee, and never takes custody of funds.

## Reporting

This project is not operated as a live service and has no bug bounty. If you find an issue, open a
GitHub issue describing it; please do not include exploit details against any live deployment you do not
own.
