/**
 * Deploy a USDG-flavored CosellEscrowV2 + X402DepositFacilitator pair
 * against the existing CosellRegistryV2 on the target chain.
 *
 * Kajota Mesh's escrow + facilitator are token-agnostic — the `IERC20`
 * constructor arg accepts any standard ERC-20. This script wires a
 * fresh pair of instances at Paxos' USDG address so the primitive
 * supports both Circle USDC and Paxos USDG side-by-side.
 *
 * The registry (v2) is token-agnostic and shared across both variants.
 *
 * USDG addresses (verified from docs.paxos.com/guides/stablecoin/usdg):
 *   Arbitrum One         0x004B506865409877C9fA29bfb1ebA929984B9bbC
 *   Arbitrum Sepolia     0xFFC95faa3d63Cde504a05B567C600B78C0b41892
 *   Robinhood Chain      0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
 *   Robinhood Testnet    0x7E955252E15c84f5768B83c41a71F9eba181802F
 *
 * Operational note (documented in README): USDG has an
 * ASSET_PROTECTION_ROLE that can freeze balances via `isFrozen(address)`
 * and wipe frozen holdings. For an escrow that means: if Paxos freezes
 * the escrow's own address, buyer funds land in limbo. Not a hackathon
 * concern, but real for production users.
 *
 * Usage:
 *   pnpm hardhat run --network arbitrumSepolia scripts/deploy-usdg.ts
 *   pnpm hardhat run --network robinhoodTestnet scripts/deploy-usdg.ts
 */
import { network } from "hardhat";
import { getAddress, type Address } from "viem";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";

const USDG_BY_CHAIN_ID: Record<number, string | undefined> = {
  421614: "0xFFC95faa3d63Cde504a05B567C600B78C0b41892", // Arbitrum Sepolia
  46630:  "0x7E955252E15c84f5768B83c41a71F9eba181802F", // Robinhood Chain testnet
};

const CHAIN_NAMES: Record<number, string> = {
  421614: "Arbitrum Sepolia",
  46630:  "Robinhood Chain Testnet",
};

async function main() {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const [deployer] = await viem.getWalletClients();
  const chainId = await publicClient.getChainId();
  const chainName =
    publicClient.chain?.name ?? CHAIN_NAMES[chainId] ?? `chain-${chainId}`;

  // Mainnet guardrail (same list as deploy.ts).
  const KNOWN_MAINNET_IDS = new Set<number>([1, 42161, 8453, 5000, 4663]);
  if (KNOWN_MAINNET_IDS.has(chainId)) {
    throw new Error(
      `Refusing to deploy: chainId ${chainId} looks like a MAINNET.`,
    );
  }

  const usdgAddress = USDG_BY_CHAIN_ID[chainId];
  if (!usdgAddress) {
    throw new Error(
      `No USDG address configured for chainId ${chainId}. ` +
        `Add it to USDG_BY_CHAIN_ID after verifying against docs.paxos.com.`,
    );
  }
  const usdg = getAddress(usdgAddress) as Address;

  // Load existing manifest — must already contain registryV2 + releaseAuth
  // from the earlier extension deploy.
  const deploymentsDir = path.resolve(
    import.meta.dirname,
    "..",
    "deployments",
  );
  const manifestPath = path.join(deploymentsDir, `${chainId}.json`);
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));

  const registryV2Address = manifest.contracts?.registryV2;
  if (!registryV2Address) {
    throw new Error(
      `Manifest for chainId ${chainId} has no contracts.registryV2 — ` +
        `run scripts/deploy-extensions.ts first.`,
    );
  }
  const registryV2 = getAddress(registryV2Address) as Address;

  const releaseAuth = getAddress(manifest.releaseAuth) as Address;

  console.log(`\nUSDG variant deploy on ${chainName} (${chainId})`);
  console.log(`Deployer:      ${deployer.account.address}`);
  console.log(`USDG:          ${usdg} (Paxos)`);
  console.log(`RegistryV2:    ${registryV2} (reused, token-agnostic)`);
  console.log(`Release auth:  ${releaseAuth}\n`);

  const balance = await publicClient.getBalance({
    address: deployer.account.address,
  });
  console.log(`Deployer balance: ${balance} wei`);
  if (balance === 0n) {
    throw new Error("Deployer balance is 0 — top up before retrying.");
  }

  // ---- CosellEscrowV2 (USDG-flavored) -----------------------------
  console.log("\nDeploying CosellEscrowV2 (USDG) …");
  const escrowV2Usdg = await viem.deployContract("CosellEscrowV2", [
    usdg,
    registryV2,
    releaseAuth,
  ]);
  console.log(`  → CosellEscrowV2 (USDG)         @ ${escrowV2Usdg.address}`);

  // ---- X402DepositFacilitator (USDG-flavored) --------------------
  console.log("Deploying X402DepositFacilitator (USDG) …");
  const x402Usdg = await viem.deployContract("X402DepositFacilitator", [
    usdg,
    escrowV2Usdg.address,
  ]);
  console.log(`  → X402DepositFacilitator (USDG) @ ${x402Usdg.address}\n`);

  // ---- Merge into manifest ----------------------------------------
  const contracts = {
    ...(manifest.contracts ?? {}),
    escrowV2Usdg: escrowV2Usdg.address,
    x402DepositFacilitatorUsdg: x402Usdg.address,
  };
  const updated = {
    ...manifest,
    contracts,
    usdg,
    usdgDeployedAt: new Date().toISOString(),
  };
  writeFileSync(manifestPath, JSON.stringify(updated, null, 2) + "\n");
  console.log(`Wrote ${manifestPath}`);

  const finalBalance = await publicClient.getBalance({
    address: deployer.account.address,
  });
  const spent = balance - finalBalance;
  console.log(`\nGas spent: ${spent} wei (${Number(spent) / 1e18} ETH)`);

  console.log("\nVerify commands (Etherscan V2 unified API):");
  console.log(
    `  npx hardhat verify etherscan --network ${network.name} ${escrowV2Usdg.address} \\\n` +
      `    ${usdg} ${registryV2} ${releaseAuth}`,
  );
  console.log(
    `  npx hardhat verify etherscan --network ${network.name} ${x402Usdg.address} \\\n` +
      `    ${usdg} ${escrowV2Usdg.address}`,
  );
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
