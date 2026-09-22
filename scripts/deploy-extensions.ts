/**
 * Deploy ONLY the four new contracts (v2 registry + v2 escrow +
 * AgentIdentityBinding + X402DepositFacilitator) against the existing
 * verified v1 addresses on the target chain.
 *
 * Use this when you don't want to disturb v1's already-verified
 * deployment — the v1 contracts stay at their original addresses
 * (referenced from README + demo script), and the new extensions land
 * alongside them and reference the same USDC.
 *
 * Reads the existing v1 addresses + USDC from deployments/<chainId>.json.
 * Requires the manifest to already exist with at least: usdc + releaseAuth.
 * Merges the new addresses into that manifest so downstream tooling
 * (arbitrum-demo.sh, docs) picks them up.
 *
 * Usage:
 *   pnpm hardhat run --network arbitrumSepolia scripts/deploy-extensions.ts
 */
import { network } from "hardhat";
import { getAddress, type Address } from "viem";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";

async function main() {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const [deployer] = await viem.getWalletClients();
  const chainId = await publicClient.getChainId();

  // Mainnet guardrail (same list as deploy.ts).
  const KNOWN_MAINNET_IDS = new Set<number>([1, 42161, 8453, 5000, 4663]);
  if (KNOWN_MAINNET_IDS.has(chainId)) {
    throw new Error(
      `Refusing to deploy: chainId ${chainId} looks like a MAINNET.`,
    );
  }

  const deploymentsDir = path.resolve(
    import.meta.dirname,
    "..",
    "deployments",
  );
  const manifestPath = path.join(deploymentsDir, `${chainId}.json`);
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as {
    chainId: number;
    chainName?: string;
    deployer?: string;
    usdc: string;
    releaseAuth: string;
    registry?: string;
    escrow?: string;
    contracts?: Record<string, string>;
    deployedAt?: string;
    extensionsDeployedAt?: string;
  };

  const usdcAddress = getAddress(manifest.usdc) as Address;
  const releaseAuth = getAddress(manifest.releaseAuth) as Address;

  console.log(`\nExtension deploy on ${manifest.chainName ?? `chain-${chainId}`} (${chainId})`);
  console.log(`Deployer:      ${deployer.account.address}`);
  console.log(`USDC:          ${usdcAddress} (from manifest)`);
  console.log(`Release auth:  ${releaseAuth} (from manifest)\n`);

  const balance = await publicClient.getBalance({
    address: deployer.account.address,
  });
  console.log(`Deployer balance: ${balance} wei`);
  if (balance === 0n) {
    throw new Error("Deployer balance is 0 — top up before retrying.");
  }

  // ---- CosellRegistryV2 -------------------------------------------
  console.log("\nDeploying CosellRegistryV2 …");
  const registryV2 = await viem.deployContract("CosellRegistryV2");
  console.log(`  → CosellRegistryV2       @ ${registryV2.address}`);

  // ---- CosellEscrowV2 ---------------------------------------------
  console.log("Deploying CosellEscrowV2 …");
  const escrowV2 = await viem.deployContract("CosellEscrowV2", [
    usdcAddress,
    registryV2.address,
    releaseAuth,
  ]);
  console.log(`  → CosellEscrowV2         @ ${escrowV2.address}`);

  // ---- AgentIdentityBinding ---------------------------------------
  console.log("Deploying AgentIdentityBinding …");
  const identityBinding = await viem.deployContract("AgentIdentityBinding");
  console.log(`  → AgentIdentityBinding   @ ${identityBinding.address}`);

  // ---- X402DepositFacilitator -------------------------------------
  console.log("Deploying X402DepositFacilitator …");
  const x402 = await viem.deployContract("X402DepositFacilitator", [
    usdcAddress,
    escrowV2.address,
  ]);
  console.log(`  → X402DepositFacilitator @ ${x402.address}\n`);

  // ---- Merge into manifest ----------------------------------------
  const contracts = {
    ...(manifest.contracts ?? {}),
    registry: manifest.registry ?? "",
    escrow: manifest.escrow ?? "",
    registryV2: registryV2.address,
    escrowV2: escrowV2.address,
    agentIdentityBinding: identityBinding.address,
    x402DepositFacilitator: x402.address,
  };
  const updated = {
    ...manifest,
    contracts,
    extensionsDeployedAt: new Date().toISOString(),
  };
  writeFileSync(manifestPath, JSON.stringify(updated, null, 2) + "\n");
  console.log(`Wrote ${manifestPath}`);

  const finalBalance = await publicClient.getBalance({
    address: deployer.account.address,
  });
  const spent = balance - finalBalance;
  console.log(`\nGas spent: ${spent} wei (${Number(spent) / 1e18} ETH)`);

  console.log("\nVerify commands (Etherscan V2 unified API, ARBISCAN_API_KEY):");
  console.log(
    `  npx hardhat verify --network ${network.name} ${registryV2.address}`,
  );
  console.log(
    `  npx hardhat verify --network ${network.name} ${escrowV2.address} \\\n` +
      `    ${usdcAddress} ${registryV2.address} ${releaseAuth}`,
  );
  console.log(
    `  npx hardhat verify --network ${network.name} ${identityBinding.address}`,
  );
  console.log(
    `  npx hardhat verify --network ${network.name} ${x402.address} \\\n` +
      `    ${usdcAddress} ${escrowV2.address}`,
  );
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
