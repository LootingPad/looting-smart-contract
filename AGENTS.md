# AGENTS.md

`LOOTING_PRODUCT_SPEC.md` in the `looting` web repo is the canonical product source. Read it before
changing behaviour here; if the code and the spec disagree, resolve it in the spec first.

## Rules (spec §40)

- Never change reward economics without updating `LOOTING_PRODUCT_SPEC.md`.
- Never add arbitrary token transfer functions to reward contracts. There is no `rescueTokens`, and
  adding one would let an admin reach staked principal.
- Never assume frontend state is authoritative for XP or eligibility.
- Never use wallet balance alone to classify a BUY.
- Never use non-verifiable randomness for production Lucky Boxes.
- All Pons integration code must be isolated in a `pons-adapter`.
- All privileged contract actions must be tested and logged. Every admin and keeper function emits an
  event and has a test asserting the caller check.
- Never store secrets in the repository. `.env` is gitignored; `.env.example` holds no keys.
- Every production migration requires a rollback strategy.

## Rules specific to this repo

- Scope is custody and wallet-signed gates only. XP, seasons, tiers, leaderboards, buy/exit
  detection, reorg states, anti-sybil and list endpoints belong to the backend.
- The backend must never hold user funds. Where a swap is needed, the contract executes it and the
  backend supplies route parameters as the keeper.
- Writes that move a user's funds must be user-signed via the `prepare` → sign → `confirm` flow
  (spec §22). The keeper key is only for protocol-owned actions.
- `_collectFee()` does no external calls. Refund last, via `_refundExcess(refund)` as the final
  statement of a create path, so checks-effects-interactions holds.
- `nonReentrant` must come before `whenNotPaused` on every payable entrypoint.
- Reject fee-on-transfer and rebasing tokens by measuring the balance delta. Silent under-funding
  would break the invariant that principal is always withdrawable.
- One vault clone per staking event. Never introduce a shared multi-pool vault: permissionless vault
  creation means a bug in one event must not reach another event's funds.
- A vault clone's constructor does not run. Anything a clone needs goes in `initialize`, and the
  implementation must stay permanently locked against initialization.
- A pause may block new creates and new stakes. It must never block a claim or an unlocked unstake.
- Keeper functions must never take a destination address as a parameter. Destinations are contract
  state set by the admin.

## Invariants under test (spec §17)

- Dev Lock: total claimed never exceeds the locked amount; a lock cannot be cancelled.
- Staking: reward payouts never exceed the funded pool; the vault balance always covers
  `totalStaked + rewardRemaining`; an empty pool never blocks a principal withdrawal.
- Fees: ETH held always covers `opsAccrued + buybackAccrued`; the create fee is never part of a
  reward pool.
- Registry: `creatorBps + luckyBoxBps == totalCreatorFeeBps`, and the total never exceeds 100%.

## Before opening a PR

```bash
forge build && forge test && forge fmt --check && forge lint src/
```

Add a test for every new branch, including the revert path. Deviations from the spec text go in the
"Known limits" section of `README.md` with the reason.
