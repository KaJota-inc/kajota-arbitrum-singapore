import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { network } from "hardhat";
import { encodeFunctionData, keccak256, toBytes, type Address } from "viem";

/**
 * Unit tests for X402DepositFacilitator.
 *
 * Exercises the full EIP-3009 -> facilitator -> CosellEscrowV2.deposit
 * roundtrip: the buyer never touches ETH, the facilitator submits the
 * tx, and the original buyer is recorded against the depositId so a
 * later refund routes back to them.
 *
 * viem's `signTypedData` produces the same EIP-712 signature Circle's
 * canonical USDC verifies — same domain, same type hash — so this
 * mock-driven test doubles as a smoke test for the real-USDC path.
 */
describe("X402DepositFacilitator", async () => {
  const { viem } = await network.create();
  const publicClient = await viem.getPublicClient();
  const [registrant, buyer, releaseAuth, r1, r2, facilitator, attacker] =
    await viem.getWalletClients();

  const deployStack = async () => {
    const usdc = await viem.deployContract("MockUSDC");
    const registry = await viem.deployContract("CosellRegistryV2");
    const escrow = await viem.deployContract("CosellEscrowV2", [
      usdc.address,
      registry.address,
      releaseAuth.account.address,
    ]);
    const x402 = await viem.deployContract("X402DepositFacilitator", [
      usdc.address,
      escrow.address,
    ]);

    const recipients = [r1.account.address, r2.account.address];
    const shares = [3000, 7000];
    await registry.write.register(
      ["p1", recipients, shares, "USDC"],
      { account: registrant.account },
    );
    const listingId = await registry.read.computeListingId([
      "p1",
      registrant.account.address,
      recipients,
      shares,
    ]);

    // Fund buyer with 1000 USDC.
    await usdc.write.mint([buyer.account.address, 1_000_000_000n]);

    return { usdc, registry, escrow, x402, listingId };
  };

  /**
   * Sign an EIP-3009 TransferWithAuthorization off-chain. Same domain
   * separator + type hash Circle's USDC uses.
   */
  const signAuthorization = async (
    tokenAddress: Address,
    signerClient: (typeof buyer),
    args: {
      from: Address;
      to: Address;
      value: bigint;
      validAfter: bigint;
      validBefore: bigint;
      nonce: `0x${string}`;
    },
  ) => {
    const chainId = await publicClient.getChainId();
    const signature = await signerClient.signTypedData({
      domain: {
        name: "USD Coin",
        version: "2",
        chainId,
        verifyingContract: tokenAddress,
      },
      types: {
        TransferWithAuthorization: [
          { name: "from", type: "address" },
          { name: "to", type: "address" },
          { name: "value", type: "uint256" },
          { name: "validAfter", type: "uint256" },
          { name: "validBefore", type: "uint256" },
          { name: "nonce", type: "bytes32" },
        ],
      },
      primaryType: "TransferWithAuthorization",
      message: args,
    });

    // viem returns 0x-prefixed hex; slice into v/r/s.
    const sig = signature.slice(2);
    const r = `0x${sig.slice(0, 64)}` as `0x${string}`;
    const s = `0x${sig.slice(64, 128)}` as `0x${string}`;
    const v = parseInt(sig.slice(128, 130), 16);
    return { v, r, s };
  };

  it("relays a deposit end-to-end from a signed EIP-3009 authorization", async () => {
    const { usdc, escrow, x402, listingId } = await deployStack();

    const value = 10_000_000n; // 10 USDC
    const validAfter = 0n;
    const validBefore = 2_000_000_000n; // year 2033
    const nonce = keccak256(toBytes("x402-nonce-1"));

    const { v, r, s } = await signAuthorization(usdc.address, buyer, {
      from: buyer.account.address as Address,
      to: x402.address,
      value,
      validAfter,
      validBefore,
      nonce,
    });

    // Anyone (facilitator) can submit — the fact-generating signature is
    // the buyer's, so the deposit tracks to them regardless of msg.sender.
    await x402.write.relayDeposit(
      [
        listingId,
        value,
        buyer.account.address,
        validAfter,
        validBefore,
        nonce,
        v,
        r,
        s,
      ],
      { account: facilitator.account },
    );

    // 1. USDC ended up in the escrow, not in the facilitator.
    assert.equal(await usdc.read.balanceOf([x402.address]), 0n);
    assert.equal(await usdc.read.balanceOf([escrow.address]), value);
    // 2. Buyer's balance dropped exactly by value.
    assert.equal(
      await usdc.read.balanceOf([buyer.account.address]),
      1_000_000_000n - value,
    );
    // 3. Original buyer recorded on the depositId.
    const [relayed] = await publicClient.getContractEvents({
      abi: x402.abi,
      address: x402.address,
      eventName: "DepositRelayed",
      fromBlock: 0n,
      toBlock: "latest",
    });
    const depositId = relayed.args.depositId as `0x${string}`;
    const original = await x402.read.originalBuyerOf([depositId]);
    assert.equal(
      original.toLowerCase(),
      buyer.account.address.toLowerCase(),
    );
  });

  it("prevents replay of the same signed authorization", async () => {
    const { usdc, x402, listingId } = await deployStack();

    const value = 5_000_000n;
    const validBefore = 2_000_000_000n;
    const nonce = keccak256(toBytes("x402-nonce-replay"));

    const { v, r, s } = await signAuthorization(usdc.address, buyer, {
      from: buyer.account.address as Address,
      to: x402.address,
      value,
      validAfter: 0n,
      validBefore,
      nonce,
    });

    await x402.write.relayDeposit(
      [listingId, value, buyer.account.address, 0n, validBefore, nonce, v, r, s],
      { account: facilitator.account },
    );

    await assert.rejects(
      x402.write.relayDeposit(
        [listingId, value, buyer.account.address, 0n, validBefore, nonce, v, r, s],
        { account: facilitator.account },
      ),
      /AuthorizationUsed/,
    );
  });

  it("reverts on an expired authorization (validBefore in the past)", async () => {
    const { usdc, x402, listingId } = await deployStack();

    const value = 1_000_000n;
    // validBefore already in the past — should be rejected by USDC.
    const validBefore = 1n;
    const nonce = keccak256(toBytes("x402-nonce-expired"));

    const { v, r, s } = await signAuthorization(usdc.address, buyer, {
      from: buyer.account.address as Address,
      to: x402.address,
      value,
      validAfter: 0n,
      validBefore,
      nonce,
    });

    await assert.rejects(
      x402.write.relayDeposit(
        [listingId, value, buyer.account.address, 0n, validBefore, nonce, v, r, s],
        { account: facilitator.account },
      ),
      /AuthorizationExpired/,
    );
  });

  it("reverts on a signature signed by the wrong account", async () => {
    const { usdc, x402, listingId } = await deployStack();

    const value = 1_000_000n;
    const validBefore = 2_000_000_000n;
    const nonce = keccak256(toBytes("x402-nonce-wrong-signer"));

    // ATTACKER signs but declares `buyer` as the from address.
    // MockUSDC should reject: recovered signer != buyer.
    const { v, r, s } = await signAuthorization(usdc.address, attacker, {
      from: buyer.account.address as Address,
      to: x402.address,
      value,
      validAfter: 0n,
      validBefore,
      nonce,
    });

    await assert.rejects(
      x402.write.relayDeposit(
        [listingId, value, buyer.account.address, 0n, validBefore, nonce, v, r, s],
        { account: facilitator.account },
      ),
      /InvalidSignature/,
    );
  });

  it("permissionlessly refunds the original buyer after REFUND_DELAY", async () => {
    const { usdc, x402, listingId } = await deployStack();

    const value = 8_000_000n;
    const validBefore = 2_000_000_000n;
    const nonce = keccak256(toBytes("x402-nonce-refund"));

    const { v, r, s } = await signAuthorization(usdc.address, buyer, {
      from: buyer.account.address as Address,
      to: x402.address,
      value,
      validAfter: 0n,
      validBefore,
      nonce,
    });

    await x402.write.relayDeposit(
      [listingId, value, buyer.account.address, 0n, validBefore, nonce, v, r, s],
      { account: facilitator.account },
    );

    const [relayed] = await publicClient.getContractEvents({
      abi: x402.abi,
      address: x402.address,
      eventName: "DepositRelayed",
      fromBlock: 0n,
      toBlock: "latest",
    });
    const depositId = relayed.args.depositId as `0x${string}`;

    // Fast-forward past the escrow's REFUND_DELAY (14 days).
    await publicClient.request({
      method: "evm_increaseTime" as any,
      params: [Number(14 * 24 * 60 * 60 + 1)] as any,
    });
    await publicClient.request({
      method: "evm_mine" as any,
      params: [] as any,
    });

    const buyerBefore = await usdc.read.balanceOf([buyer.account.address]);
    // Attacker calls the refund — funds should still flow to the original buyer.
    await x402.write.refundToOriginalBuyer([depositId], {
      account: attacker.account,
    });
    const buyerAfter = await usdc.read.balanceOf([buyer.account.address]);
    assert.equal(buyerAfter - buyerBefore, value);
    // originalBuyerOf zeroed after refund.
    assert.equal(
      (await x402.read.originalBuyerOf([depositId])).toLowerCase(),
      "0x0000000000000000000000000000000000000000",
    );
  });

  it("reverts refund for a depositId that was never relayed", async () => {
    const { x402 } = await deployStack();
    const fakeDepositId = keccak256(toBytes("never-relayed"));
    await assert.rejects(
      x402.write.refundToOriginalBuyer([fakeDepositId], {
        account: facilitator.account,
      }),
      /DepositNotRelayed/,
    );
  });
});
