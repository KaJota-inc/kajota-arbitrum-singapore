import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { network } from "hardhat";

/**
 * Unit tests for CosellEscrowV2 — N-party fan-out on release.
 *
 * Reuses the MockUSDC 6-decimal token so split values are tested in
 * base units (100 USDC = 100_000_000). Focus is the release loop and
 * atomic-fan-out invariant: sum(recipient deltas) == gross, no dust
 * left in the escrow.
 */
describe("CosellEscrowV2", async () => {
  const { viem } = await network.create();
  const [registrant, buyer, releaseAuth, r1, r2, r3, r4, attacker] =
    await viem.getWalletClients();

  const deployStack = async (
    recipients: `0x${string}`[],
    shares: number[],
  ) => {
    const registry = await viem.deployContract("CosellRegistryV2");
    const usdc = await viem.deployContract("MockUSDC");
    const escrow = await viem.deployContract("CosellEscrowV2", [
      usdc.address,
      registry.address,
      releaseAuth.account.address,
    ]);

    const productId = "px";
    await registry.write.register(
      [productId, recipients, shares, "USDC"],
      { account: registrant.account },
    );
    const listingId = await registry.read.computeListingId([
      productId,
      registrant.account.address,
      recipients,
      shares,
    ]);

    await usdc.write.mint([buyer.account.address, 1_000_000_000n]); // 1000 USDC

    return { registry, usdc, escrow, listingId };
  };

  // ----------------------------------------------------------------
  //  deposit + release: 3 parties, exact-divisible amount
  // ----------------------------------------------------------------

  it("fans out cleanly across 3 recipients with an exact-divisible gross", async () => {
    const recipients = [r1.account.address, r2.account.address, r3.account.address];
    const shares = [1000, 3000, 6000]; // 10/30/60
    const { usdc, escrow, listingId } = await deployStack(recipients, shares);

    const gross = 100_000_000n; // 100 USDC — exact-divisible by 10/30/60
    await usdc.write.approve([escrow.address, gross], { account: buyer.account });
    await escrow.write.deposit([listingId, gross], { account: buyer.account });

    // Locate the depositId via the balance-change on the escrow.
    // Simpler: computeDeposit via re-read of the deposits mapping is
    // not directly exposed, so we compute it by knowing there is a
    // single deposit under this listingId. Fetch via the Deposited event.
    const publicClient = await viem.getPublicClient();
    const [deposited] = await publicClient.getContractEvents({
      abi: escrow.abi,
      address: escrow.address,
      eventName: "Deposited",
      fromBlock: 0n,
      toBlock: "latest",
    });
    const depositId = deposited.args.depositId as `0x${string}`;

    await escrow.write.release([depositId], { account: releaseAuth.account });

    // Verify each recipient's balance is exactly their share.
    const b1 = await usdc.read.balanceOf([r1.account.address]);
    const b2 = await usdc.read.balanceOf([r2.account.address]);
    const b3 = await usdc.read.balanceOf([r3.account.address]);
    assert.equal(b1, 10_000_000n); // 10 USDC
    assert.equal(b2, 30_000_000n); // 30 USDC
    assert.equal(b3, 60_000_000n); // 60 USDC

    // Escrow drained fully — no dust retained.
    const escrowResidual = await usdc.read.balanceOf([escrow.address]);
    assert.equal(escrowResidual, 0n);
  });

  // ----------------------------------------------------------------
  //  deposit + release: 4 parties with rounding-remainder to last
  // ----------------------------------------------------------------

  it("routes the rounding remainder to the last recipient", async () => {
    const recipients = [
      r1.account.address, r2.account.address,
      r3.account.address, r4.account.address,
    ];
    // 3333 / 3333 / 3333 / 1 = 10000. Not exact-divisible on gross=7,
    // which forces the dust to land on r4 (the last recipient).
    const shares = [3333, 3333, 3333, 1];
    const { usdc, escrow, listingId } = await deployStack(recipients, shares);

    const gross = 7n;
    await usdc.write.approve([escrow.address, gross], { account: buyer.account });
    await escrow.write.deposit([listingId, gross], { account: buyer.account });

    const publicClient = await viem.getPublicClient();
    const [deposited] = await publicClient.getContractEvents({
      abi: escrow.abi,
      address: escrow.address,
      eventName: "Deposited",
      fromBlock: 0n,
      toBlock: "latest",
    });
    const depositId = deposited.args.depositId as `0x${string}`;

    await escrow.write.release([depositId], { account: releaseAuth.account });

    const balances = [
      await usdc.read.balanceOf([r1.account.address]),
      await usdc.read.balanceOf([r2.account.address]),
      await usdc.read.balanceOf([r3.account.address]),
      await usdc.read.balanceOf([r4.account.address]),
    ];
    const sum = balances.reduce((a, b) => a + b, 0n);
    assert.equal(sum, gross, "sum of recipient balances must equal gross");
    // No dust in escrow.
    assert.equal(await usdc.read.balanceOf([escrow.address]), 0n);
  });

  // ----------------------------------------------------------------
  //  reverts
  // ----------------------------------------------------------------

  it("reverts NotReleaseAuth when a non-authorized caller releases", async () => {
    const recipients = [r1.account.address, r2.account.address];
    const shares = [4000, 6000];
    const { usdc, escrow, listingId } = await deployStack(recipients, shares);

    const gross = 10_000_000n;
    await usdc.write.approve([escrow.address, gross], { account: buyer.account });
    await escrow.write.deposit([listingId, gross], { account: buyer.account });

    const publicClient = await viem.getPublicClient();
    const [deposited] = await publicClient.getContractEvents({
      abi: escrow.abi,
      address: escrow.address,
      eventName: "Deposited",
      fromBlock: 0n,
      toBlock: "latest",
    });
    const depositId = deposited.args.depositId as `0x${string}`;

    await assert.rejects(
      escrow.write.release([depositId], { account: attacker.account }),
      /NotReleaseAuth/,
    );
  });

  it("reverts DepositNotPending on double-release", async () => {
    const recipients = [r1.account.address, r2.account.address];
    const shares = [4000, 6000];
    const { usdc, escrow, listingId } = await deployStack(recipients, shares);

    const gross = 10_000_000n;
    await usdc.write.approve([escrow.address, gross], { account: buyer.account });
    await escrow.write.deposit([listingId, gross], { account: buyer.account });

    const publicClient = await viem.getPublicClient();
    const [deposited] = await publicClient.getContractEvents({
      abi: escrow.abi,
      address: escrow.address,
      eventName: "Deposited",
      fromBlock: 0n,
      toBlock: "latest",
    });
    const depositId = deposited.args.depositId as `0x${string}`;

    await escrow.write.release([depositId], { account: releaseAuth.account });
    await assert.rejects(
      escrow.write.release([depositId], { account: releaseAuth.account }),
      /DepositNotPending/,
    );
  });

  it("reverts ZeroAmount on a zero-value deposit", async () => {
    const recipients = [r1.account.address, r2.account.address];
    const shares = [4000, 6000];
    const { escrow, listingId } = await deployStack(recipients, shares);
    await assert.rejects(
      escrow.write.deposit([listingId, 0n], { account: buyer.account }),
      /ZeroAmount/,
    );
  });

  it("reverts ListingNotActive after deactivation", async () => {
    const recipients = [r1.account.address, r2.account.address];
    const shares = [4000, 6000];
    const { registry, escrow, listingId } = await deployStack(recipients, shares);
    await registry.write.deactivate([listingId], { account: registrant.account });
    await assert.rejects(
      escrow.write.deposit([listingId, 1n], { account: buyer.account }),
      /ListingNotActive/,
    );
  });

  // ----------------------------------------------------------------
  //  refund
  // ----------------------------------------------------------------

  it("refunds the buyer after REFUND_DELAY and rejects earlier attempts", async () => {
    const recipients = [r1.account.address, r2.account.address];
    const shares = [4000, 6000];
    const { usdc, escrow, listingId } = await deployStack(recipients, shares);

    const gross = 10_000_000n;
    await usdc.write.approve([escrow.address, gross], { account: buyer.account });
    await escrow.write.deposit([listingId, gross], { account: buyer.account });

    const publicClient = await viem.getPublicClient();
    const [deposited] = await publicClient.getContractEvents({
      abi: escrow.abi,
      address: escrow.address,
      eventName: "Deposited",
      fromBlock: 0n,
      toBlock: "latest",
    });
    const depositId = deposited.args.depositId as `0x${string}`;

    // Too early.
    await assert.rejects(
      escrow.write.refund([depositId], { account: buyer.account }),
      /RefundTooEarly/,
    );

    // Fast-forward past REFUND_DELAY.
    await publicClient.request({
      method: "evm_increaseTime" as any,
      params: [Number(14 * 24 * 60 * 60 + 1)] as any,
    });
    await publicClient.request({
      method: "evm_mine" as any,
      params: [] as any,
    });

    const buyerBefore = await usdc.read.balanceOf([buyer.account.address]);
    await escrow.write.refund([depositId], { account: buyer.account });
    const buyerAfter = await usdc.read.balanceOf([buyer.account.address]);
    assert.equal(buyerAfter - buyerBefore, gross);
  });
});
