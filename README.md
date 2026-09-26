# LOOTING Contracts

On-chain custody for the LOOTING launchpad. Canonical product source: `LOOTING_PRODUCT_SPEC.md` in
the `looting` web repo.

This repo holds **only** the parts that must live on-chain: token custody and the gates that need a
user signature. XP, seasons, tiers, leaderboards, buy/exit detection, anti-sybil, reorg handling and
every list endpoint belong to the backend, not here.

## Contracts

| Contract | Purpose | UI surface |
|---|---|---|
| `LootingLaunchRegistry` | Record of which tokens launched through LOOTING plus the reward split snapshotted at launch. The gate both other modules check. | — (backend writes it) |
| `LootingDevLock` | Time locks and linear vesting of creator supply. Locks cannot be cancelled. | `/devlock` |
| `LootingStakingFactory` | Creates and funds one staking vault per Create Staking event; registry for the Events list. | `/create-staking` |
| `LootingStakingVault` | Holds the principal and the creator-funded reward pool for a single event. One clone per event. | `/staking` |
| `FeeSplitter` | Abstract base of Dev Lock and the factory. Collects the flat ETH fee and splits it 50/50. | fee rows in both forms |

Deliberately **not** here: Lucky Box, reward routing and the XP/season modules. Those wait until the
indexer exists, per the scope decision recorded in the plan.

## Fees

Both creates charge a flat **0.003 ETH**, split 50% operations / 50% LOOTING buyback.

- Dev Lock operations wallet: `0x6B5A599160Eb1fFf5da90A0C63b144e341cDBF1F`
- Create Staking operations wallet: `0x2Cd6aBfFcDB83Ea1D111611696EA3a596bd997bD`
- Launch fee remainder wallet (reserved for the deferred launch router): `0xD712570969461D9f736a76e290a4Ee700509a59B`

The fee is a variable bounded by `MAX_FEE` (0.05 ETH), not a constant. A **decrease applies
immediately**; an **increase waits out `FEE_TIMELOCK` (1 day)** so a create already in flight can
never be charged more than the UI quoted. `setFee` schedules, `applyFee` applies.

Both halves leave the contract through pull functions with fixed destinations:

- `withdrawOps()` is permissionless and always pays `opsWallet`, so a wallet that rejects ETH can
  never block a create.
- `buyback(adapter, ethIn, minLootingOut, deadline)` is keeper-only. The keeper supplies the route
  and the quote; the contract fixes the destination, the budget, the allowlist, the deadline and a
  `minLootingPerEth` price floor. Output is measured from the recipient's balance, not trusted from
  the adapter's return value.

> The fee numbers in the web repo (`apps/web/src/lib/fees.ts`) and roughly eleven places in the spec
> still read 0.0005 / 0.0019. Those are stale relative to this repo.

## Frontend values these contracts must match

- Lock options: flexible, 30 days, 90 days (`STAKING_LOCK_OPTIONS`)
- Dev Lock cadences are UI metadata only — vesting is continuous linear regardless of cadence
- `vestedAmount` / `claimableAmount` mirror the math in `DevLock.tsx`

## Layout

```
src/            contracts
test/           forge tests, including fee-split, clone-safety and invariant fuzzing
script/         Deploy.s.sol
deployments/    one <chainId>.json per deployment
```

## Build and test

```bash
forge build
forge test
forge fmt --check
forge lint src/
```

69 tests, all passing. The remaining lint warnings are accepted: `block-timestamp` is inherent to a
vesting schedule, the `uint64` timestamp casts are safe until 2106, and the `arbitrary-send-eth`
hits are on an allowlisted adapter and on fixed-destination pull payments.

## Deploy

```bash
cp .env.example .env    # fill ADMIN, KEEPER, RPC_URL, PRIVATE_KEY
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --broadcast --verify
```

Deploy order (spec §61.2): registry, Dev Lock, vault implementation, factory. The script writes
`deployments/<chainId>.json` with the addresses, the deploy block and the fee, which is what the
backend and the frontend read.

`ADMIN` should be a multisig (spec §29). It holds `DEFAULT_ADMIN_ROLE` everywhere. `KEEPER` is the
backend key: it holds `REGISTRAR_ROLE` on the registry and `KEEPER_ROLE` on both fee collectors.

### Post-deploy wiring

These need addresses that do not exist at deploy time, so the admin multisig does them afterwards on
both `LootingDevLock` and `LootingStakingFactory`:

1. `setLootingToken(LOOTING)`
2. `setBuybackRecipient(treasury)`
3. `setMinLootingPerEth(floor)` — `buyback` reverts until this is set
4. `setBuybackRouter(adapter, true)` — must be a LOOTING-deployed adapter matching
   `ILootingBuybackAdapter`, **never** a raw Uniswap router, whose argument order differs

Until then the buyback half simply accrues as ETH; nothing is lost.

## Known limits

- A creator cannot reclaim unclaimed reward tokens after an event ends. The spec defines no reclaim
  function, so none was added.
- Reward accrual is simple interest on the current principal, not compounding.
- `LootingRewardRouter` is deferred until the Pons ABI is verified on-chain.

See `AGENTS.md` before changing anything, and `LISTING.md` for the DefiLlama integration.
