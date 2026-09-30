/**
 * One-shot deploy of LootingLaunchRouter using backend .env KEEPER_PRIVATE_KEY.
 * Does not print the private key.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createWalletClient, createPublicClient, http, getAddress, parseEther } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, "..");
const BACKEND_ENV = resolve(ROOT, "../../backend/looting-backend/.env");
const ARTIFACT = resolve(ROOT, "out/LootingLaunchRouter.sol/LootingLaunchRouter.json");
const DEPLOYMENTS = resolve(ROOT, "deployments/4663.json");

function loadEnv(path) {
  const out = {};
  for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
    const t = line.trim();
    if (!t || t.startsWith("#")) continue;
    const i = t.indexOf("=");
    if (i < 0) continue;
    out[t.slice(0, i)] = t.slice(i + 1).trim().replace(/^["']|["']$/g, "");
  }
  return out;
}

const robinhood = {
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [] } },
};

async function main() {
  const env = loadEnv(BACKEND_ENV);
  let pk = env.KEEPER_PRIVATE_KEY || "";
  if (!pk) throw new Error("KEEPER_PRIVATE_KEY missing");
  if (!pk.startsWith("0x")) pk = `0x${pk}`;
  const rpc = env.RPC_HTTP_URL;
  if (!rpc) throw new Error("RPC_HTTP_URL missing");

  const admin = getAddress("0x28b14bF827b10D2037fdc367a1f86434069D5E50");
  const pauser = admin;
  const ponsFactory = getAddress(env.PONS_V2_FACTORY || "0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e");
  const feeWallet = getAddress(env.LAUNCH_FEE_WALLET || "0xD712570969461D9f736a76e290a4Ee700509a59B");
  const fee = parseEther("0.00035");

  const account = privateKeyToAccount(pk);
  console.log("deployer", account.address);
  console.log("admin", admin);
  console.log("ponsFactory", ponsFactory);
  console.log("feeWallet", feeWallet);

  const chain = { ...robinhood, rpcUrls: { default: { http: [rpc] } } };
  const transport = http(rpc, { timeout: 60_000 });
  const publicClient = createPublicClient({ chain, transport });
  const walletClient = createWalletClient({ account, chain, transport });

  const chainId = await publicClient.getChainId();
  if (chainId !== 4663) throw new Error(`unexpected chainId ${chainId}`);

  const balance = await publicClient.getBalance({ address: account.address });
  console.log("balanceWei", balance.toString());

  const artifact = JSON.parse(readFileSync(ARTIFACT, "utf8"));
  const hash = await walletClient.deployContract({
    abi: artifact.abi,
    bytecode: artifact.bytecode.object,
    args: [admin, pauser, ponsFactory, feeWallet, fee],
  });
  console.log("tx", hash);

  const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 180_000 });
  if (receipt.status !== "success" || !receipt.contractAddress) {
    throw new Error(`deploy failed status=${receipt.status}`);
  }
  const router = getAddress(receipt.contractAddress);
  console.log("LootingLaunchRouter", router);

  const existing = JSON.parse(readFileSync(DEPLOYMENTS, "utf8"));
  existing.launchRouter = router;
  existing.launchRouterDeployTx = hash;
  existing.launchRouterDeployBlock = Number(receipt.blockNumber);
  writeFileSync(DEPLOYMENTS, `${JSON.stringify(existing, null, 2)}\n`);
  console.log("updated", DEPLOYMENTS);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
