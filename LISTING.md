# Aggregator listings

Scoped deliberately: **DefiLlama is the only listing this repo needs to support.** The others were
reviewed and either belong to someone else or should wait.

| Target | Decision | Why |
|---|---|---|
| DefiLlama | Do it | Free, self-serve PR, and the TVL adapter reads straight from the contracts below. |
| GeckoTerminal | Not ours | It indexes DEX pools, not our vaults. That is the chain's / Pons' job once pools exist. |
| DappRadar, De.Fi | After the audit | Both surface a security score; listing pre-audit publishes a low one. |
| CoinMarketCap | After the LOOTING token exists | It is a token listing, not a protocol listing. |
| vfat.tools, DexScan, Footprint, Dapp.com, L2BEAT, DeFi Pulse | Skip | vfat and DexScan are pool/pair oriented; Footprint and Dapp.com add little traffic for the effort; L2BEAT only lists L2s, which we are not; DeFi Pulse is effectively dormant. |

## What DefiLlama needs from these contracts

A TVL adapter for a new project must **compute TVL from blockchain data**. Fetch adapters that call
our own API get rejected. Everything the adapter needs is therefore readable on-chain:

- `LootingStakingFactory.vaultCount()` and `vaults(offset, limit)` — enumerate every vault
- `LootingStakingVault.vaultInfo()` — `stakeToken`, `totalStaked`, `rewardRemaining` per vault
- `LootingDevLock.lockOf(lockId)` — locked amounts per position
- `LootingLaunchRegistry.launchCount()` / `launches(offset, limit)` — every launched token

TVL = sum of `totalStaked + rewardRemaining` across vaults. Dev Lock balances are **vesting, not
TVL**, and DefiLlama treats them as a separate category, so keep them out of the main number.

## Submission steps

1. Deploy, then commit `deployments/<chainId>.json` — the adapter needs the factory address and the
   deploy block as its `start`.
2. Fork `DefiLlama/DefiLlama-Adapters`, add `projects/looting/index.js`.
3. Set `start` to the factory deploy block, write a `methodology` string, and list any token that
   needs `misrepresentedTokens`. Support `timetravel` by keying every read off the block argument.
4. Open the PR. Protocol metadata (logo, category, links, audit) goes through `defillama-server` or
   metadata@defillama.com.
5. Fees and revenue are a **separate** adapter in `DefiLlama/dimension-adapters`. Our revenue is the
   `FeeCollected` event: `toOps` plus `toBuyback` equals total fee revenue.

## Before submitting

- Contracts verified on the block explorer.
- At least one real staking vault with non-trivial TVL — DefiLlama rejects empty protocols.
- The audit done, so the metadata PR can reference it.
