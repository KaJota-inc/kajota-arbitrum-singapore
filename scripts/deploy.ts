/**
 * Deploy script for Kajota Mesh contracts.
 *
 * Deploys the full stack — v1 (Registry + Escrow), v2 (RegistryV2 +
 * EscrowV2 = N-party split), and KajotaEscrow (single-recipient with
 * dispute path) — in one run. Idempotent per chain: writes
 * deployments/<chainId>.json so re-invocations from a fresh EOA on the
 * same chain overwrite that manifest cleanly.
 *
 * USDC handling:
 *   - Chains with a canonical Circle USDC address (Arbitrum Sepolia,
 *     Ethereum Sepolia): use it from the map / env override.
 *   - Chains without canonical USDC (Robinhood Chain testnet):
 *     auto-deploy MockUSDC. Buildathon demo flows still work; a Circle-
 *     bridged USDC swap is a follow-up.
 *
 * Usage:
 *   pnpm deploy:arbitrum-sepolia
 *   pnpm deploy:robinhood-testnet
 *
 * Required env (see .env.example at the repo root):
 *   DEPLOYER_PRIVATE_KEY  — funded with the chain's testnet ETH
 *   USDC_<NETWORK>        — canonical USDC address (optional; if
 *                           unset, MockUSDC is deployed)
 *   INITIAL_RELEASE_AUTH  — optional; defaults to deployer
 *
 * Output:
 *   - prints all deployed addresses to stdout
 *   - writes deployments/<chainId>.json for downstream agents
 */
import { network } from "hardhat";
import { getAddress, type Address } from "viem";
import { writeFileSync, mkdirSync } from "node:fs";
import path from "node:path";

const USDC_ADDRESS_BY_CHAIN_ID: Record<number, string | undefined> = {
  // Ethereum Sepolia — Circle's official testnet USDC.
  11155111:
    process.env.USDC_ETHEREUM_SEPOLIA ??
    "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
  84532: process.env.USDC_BASE_SEPOLIA,
  5003: process.env.USDC_MANTLE_SEPOLIA,
  // Arbitrum Sepolia — Circle's official testnet USDC.
  421614:
    process.env.USDC_ARBITRUM_SEPOLIA ??
    "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d",
  // Robinhood Chain testnet — no canonical Circle USDC yet, override
  // via env or fall through to the auto-deployed MockUSDC below.
  46630: process.env.USDC_ROBINHOOD_TESTNET,
};

const CHAIN_NAMES: Record<number, string> = {
  11155111: "Ethereum Sepolia",
  84532: "Base Sepolia",
  5003: "Mantle Sepolia",
  421614: "Arbitrum Sepolia",
  46630: "Robinhood Chain Testnet",
};

async function main() {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const [deployer] = await viem.getWalletClients();

  const chainId = await publicClient.getChainId();
  const chainName =
    publicClient.chain?.name ?? CHAIN_NAMES[chainId] ?? `chain-${chainId}`;

  // Guardrail: never accidentally deploy to a mainnet whose chainId
  // rhymes with a testnet id we support (Robinhood mainnet = 4663;
  // testnet = 46630; off by a factor of 10 in decimal).
  const KNOWN_MAINNET_IDS = new Set<number>([1, 42161, 8453, 5000, 4663]);
  if (KNOWN_MAINNET_IDS.has(chainId)) {
    throw new Error(
      `Refusing to deploy: chainId ${chainId} looks like a MAINNET. ` +
        `This repo is testnet-scoped for the buildathon.`,
    );
  }

  console.log(`\nKajota Mesh — deploy on ${chainName} (chainId ${chainId})`);
  console.log(`Deployer: ${deployer.account.address}`);
  const balance = await publicClient.getBalance({
    address: deployer.account.address,
  });
  console.log(`Balance:  ${balance} wei`);
  if (balance === 0n) {
    throw new Error(
      "Deployer balance is 0 — top up the EOA with testnet ETH before retrying.",
    );
  }

  // ---- USDC address ------------------------------------------------
  let usdcAddress: Address;
  const canonicalUsdc = USDC_ADDRESS_BY_CHAIN_ID[chainId];
  let mockUsdcDeployed = false;
  if (canonicalUsdc) {
    usdcAddress = getAddress(canonicalUsdc) as Address;
    console.log(`USDC:     ${usdcAddress} (canonical)`);
  } else {
    console.log(`USDC:     no canonical address — deploying MockUSDC`);
    const mock = await viem.deployContract("MockUSDC");
    usdcAddress = mock.address as Address;
    mockUsdcDeployed = true;
    console.log(`  → MockUSDC        @ ${usdcAddress}`);
  }

  // ---- releaseAuth -------------------------------------------------
  const releaseAuthEnv = process.env.INITIAL_RELEASE_AUTH;
  const releaseAuth: Address =
    releaseAuthEnv && releaseAuthEnv.length > 0
      ? (getAddress(releaseAuthEnv) as Address)
      : (deployer.account.address as Address);
  console.log(`Release:  ${releaseAuth}\n`);

  // ---- 1. CosellRegistry (v1) --------------------------------------
  console.log("Deploying CosellRegistry (v1) …");
  const registry = await viem.deployContract("CosellRegistry");
  console.log(`  → CosellRegistry  @ ${registry.address}`);

  // ---- 2. CosellEscrow (v1) ----------------------------------------
  console.log("Deploying CosellEscrow (v1) …");
  const escrow = await viem.deployContract("CosellEscrow", [
    usdcAddress,
    registry.address,
    releaseAuth,
  ]);
  console.log(`  → CosellEscrow    @ ${escrow.address}`);

  // ---- 3. CosellRegistryV2 (N-party) -------------------------------
  console.log("Deploying CosellRegistryV2 (N-party) …");
  const registryV2 = await viem.deployContract("CosellRegistryV2");
  console.log(`  → CosellRegistryV2 @ ${registryV2.address}`);

  // ---- 4. CosellEscrowV2 (N-party) ---------------------------------
  console.log("Deploying CosellEscrowV2 (N-party) …");
  const escrowV2 = await viem.deployContract("CosellEscrowV2", [
    usdcAddress,
    registryV2.address,
    releaseAuth,
  ]);
  console.log(`  → CosellEscrowV2   @ ${escrowV2.address}`);

  // ---- 5. KajotaEscrow (single-recipient + dispute) ----------------
  // Note: KajotaEscrow takes (usdc, disputeResolver). Dispute resolver
  // defaults to the deployer for testnet demos; production should
  // rotate to a multisig via setDisputeResolver().
  console.log("Deploying KajotaEscrow (dispute-flavored) …");
  const kajotaEscrow = await viem.deployContract("KajotaEscrow", [
    usdcAddress,
    releaseAuth, // reuse the same address as the dispute resolver on testnet
  ]);
  console.log(`  → KajotaEscrow     @ ${kajotaEscrow.address}\n`);

  // ---- 6. Persist addresses ---------------------------------------
  const deploymentsDir = path.resolve(
    import.meta.dirname,
    "..",
    "deployments",
  );
  mkdirSync(deploymentsDir, { recursive: true });
  const out = {
    chainId,
    chainName,
    deployer: deployer.account.address,
    usdc: usdcAddress,
    usdcSource: mockUsdcDeployed ? "MockUSDC (this repo)" : "canonical",
    releaseAuth,
    contracts: {
      registry: registry.address,
      escrow: escrow.address,
      registryV2: registryV2.address,
      escrowV2: escrowV2.address,
      kajotaEscrow: kajotaEscrow.address,
    },
    deployedAt: new Date().toISOString(),
  };
  const outPath = path.join(deploymentsDir, `${chainId}.json`);
  writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n");
  console.log(`Wrote ${outPath}`);

  console.log("\nDone. Next steps:");
  console.log(`  1. Verify all contracts on the block explorer for ${chainName}:`);
  console.log(
    `     npx hardhat verify --network ${network.name} ${registry.address}`,
  );
  console.log(
    `     npx hardhat verify --network ${network.name} ${escrow.address} \\\n` +
      `       ${usdcAddress} ${registry.address} ${releaseAuth}`,
  );
  console.log(
    `     npx hardhat verify --network ${network.name} ${registryV2.address}`,
  );
  console.log(
    `     npx hardhat verify --network ${network.name} ${escrowV2.address} \\\n` +
      `       ${usdcAddress} ${registryV2.address} ${releaseAuth}`,
  );
  console.log(
    `     npx hardhat verify --network ${network.name} ${kajotaEscrow.address} \\\n` +
      `       ${usdcAddress} ${releaseAuth}`,
  );
  console.log(
    "  2. Update scripts/arbitrum-demo.sh + demo/SHOT_LIST.md with the new addresses.",
  );
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
