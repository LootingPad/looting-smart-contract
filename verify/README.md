# Verify on robin.etherscan.io

Robinhood explorer: https://robin.etherscan.io

## Status (chain 4663)

All four production contracts are verified (Exact Match) on RobinScan:

| Contract | Address |
|---|---|
| LootingLaunchRegistry | https://robin.etherscan.io/address/0xe39493f3aef4fbA076d7c8B60F8b23fA7e2848fe#code |
| LootingDevLock | https://robin.etherscan.io/address/0x3e5b1935EdcA330CEfDd158Ec266AeCCbc77a78e#code |
| LootingStakingVault (impl) | https://robin.etherscan.io/address/0xF854B5Eb2339A79F67f63F9A97AD865411F3E609#code |
| LootingStakingFactory | https://robin.etherscan.io/address/0x4Cf5D199888e5BEA839e4cA7f8558288f102Bf58#code |

Also exact-matched on Sourcify for chainId 4663.

## CLI (needs free Etherscan API key)

1. Create a free key at https://etherscan.io/myapikey (Etherscan API V2 covers Robinhood / chainId 4663).
2. Export it and run:

```bash
export ETHERSCAN_API_KEY=your_key_here
cd /Users/taufiq.hidayah/Downloads/looting-contracts

# Registry
forge verify-contract 0xe39493f3aef4fbA076d7c8B60F8b23fA7e2848fe \
  src/LootingLaunchRegistry.sol:LootingLaunchRegistry \
  --chain 4663 \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --constructor-args $(cat verify/args-registry.txt) \
  --watch

# DevLock
forge verify-contract 0x3e5b1935EdcA330CEfDd158Ec266AeCCbc77a78e \
  src/LootingDevLock.sol:LootingDevLock \
  --chain 4663 \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --constructor-args $(cat verify/args-devlock.txt) \
  --watch

# Vault implementation (no constructor args)
forge verify-contract 0xF854B5Eb2339A79F67f63F9A97AD865411F3E609 \
  src/LootingStakingVault.sol:LootingStakingVault \
  --chain 4663 \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --watch

# Factory
forge verify-contract 0x4Cf5D199888e5BEA839e4cA7f8558288f102Bf58 \
  src/LootingStakingFactory.sol:LootingStakingFactory \
  --chain 4663 \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --constructor-args $(cat verify/args-factory.txt) \
  --watch
```

## UI (no API key)

Open https://robin.etherscan.io/verifyContract and for each address:

| Field | Value |
|---|---|
| Compiler Type | Solidity (Standard-Json-Input) |
| Compiler Version | `v0.8.28+commit.7893614a` |
| Open Source License | MIT |
| Optimization | Yes, runs `200` |
| Standard JSON | upload `verify/*.standard.json` |
| Constructor Arguments | paste matching `verify/args-*.txt` (ABI-encoded, with `0x`) |

Addresses are listed in `../deployments/4663.json`.
