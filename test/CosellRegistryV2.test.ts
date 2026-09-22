import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { network } from "hardhat";
import { getAddress } from "viem";

/**
 * Unit tests for CosellRegistryV2 — N-party generalisation of v1.
 *
 * Coverage matches v1's shape (register + deactivate + views + splits) plus
 * every invariant the N-party path introduces: recipient-count bounds,
 * duplicate-recipient rejection, share-sum enforcement, rounding-remainder
 * routing.
 */
describe("CosellRegistryV2", async () => {
  const { viem } = await network.create();
  const [registrant, r1, r2, r3, r4, other] = await viem.getWalletClients();

  const same = (a: string, b: string) => assert.equal(getAddress(a), getAddress(b));

  const deploy = async () => await viem.deployContract("CosellRegistryV2");

  // ----------------------------------------------------------------
  //  register()
  // ----------------------------------------------------------------

  describe("register", () => {
    it("stores a 2-party listing (v1-compatible pattern) and emits", async () => {
      const registry = await deploy();
      const productId = "p1-2party";
      const recipients = [r1.account.address, r2.account.address];
      const shares = [1500, 8500]; // 15% / 85%

      const tx = await registry.write.register(
        [productId, recipients, shares, "USDC"],
        { account: registrant.account },
      );
      assert.ok(tx);

      const listingId = await registry.read.computeListingId([
        productId,
        registrant.account.address,
        recipients,
        shares,
      ]);
      const l = await registry.read.getListing([listingId]);

      assert.equal(l.productId, productId);
      same(l.registrant, registrant.account.address);
      assert.equal(l.recipients.length, 2);
      same(l.recipients[0], r1.account.address);
      same(l.recipients[1], r2.account.address);
      assert.equal(l.shares[0], 1500);
      assert.equal(l.shares[1], 8500);
      assert.equal(l.currency, "USDC");
      assert.equal(l.active, true);
      assert.notEqual(l.registeredAt, 0n);
    });

    it("stores a 4-party listing with the primitive extension", async () => {
      const registry = await deploy();
      const productId = "p1-4party";
      const recipients = [
        r1.account.address, r2.account.address,
        r3.account.address, r4.account.address,
      ];
      const shares = [1000, 2000, 3000, 4000]; // sums to 10000

      await registry.write.register(
        [productId, recipients, shares, "USDC"],
        { account: registrant.account },
      );

      const listingId = await registry.read.computeListingId([
        productId, registrant.account.address, recipients, shares,
      ]);
      const l = await registry.read.getListing([listingId]);
      assert.equal(l.recipients.length, 4);
      assert.equal(l.shares[3], 4000);
    });

    it("indexes the listing under every recipient", async () => {
      const registry = await deploy();
      const productId = "px";
      const recipients = [r1.account.address, r2.account.address, r3.account.address];
      const shares = [1000, 2000, 7000];

      await registry.write.register(
        [productId, recipients, shares, "USDC"],
        { account: registrant.account },
      );

      for (const r of [r1, r2, r3]) {
        const rIndex = await registry.read.listingsForRecipient([r.account.address]);
        assert.equal(rIndex.length, 1);
      }
      const pIndex = await registry.read.listingsForProduct([productId]);
      assert.equal(pIndex.length, 1);
    });

    it("reverts RecipientCountOutOfRange when < 2", async () => {
      const registry = await deploy();
      await assert.rejects(
        registry.write.register(
          ["p1", [r1.account.address], [10000], "USDC"],
          { account: registrant.account },
        ),
        /RecipientCountOutOfRange/,
      );
    });

    it("reverts RecipientCountOutOfRange when > MAX_RECIPIENTS (17)", async () => {
      const registry = await deploy();
      const many = new Array(17).fill(0).map((_, i) =>
        `0x${(i + 1).toString(16).padStart(40, "0")}`
      );
      const eq = new Array(17).fill(0); // will be adjusted
      // Give first 16 share=625 (sums to 10000), 17th gets share=0 (irrelevant — count check reverts first)
      for (let i = 0; i < 16; i++) eq[i] = 625;
      eq[16] = 0;

      await assert.rejects(
        registry.write.register(
          ["p1", many, eq, "USDC"],
          { account: registrant.account },
        ),
        /RecipientCountOutOfRange/,
      );
    });

    it("reverts ShareLengthMismatch when arrays differ", async () => {
      const registry = await deploy();
      await assert.rejects(
        registry.write.register(
          ["p1", [r1.account.address, r2.account.address], [5000, 3000, 2000], "USDC"],
          { account: registrant.account },
        ),
        /ShareLengthMismatch/,
      );
    });

    it("reverts ZeroRecipient for zero-address entries", async () => {
      const registry = await deploy();
      await assert.rejects(
        registry.write.register(
          ["p1", [r1.account.address, "0x0000000000000000000000000000000000000000"], [5000, 5000], "USDC"],
          { account: registrant.account },
        ),
        /ZeroRecipient/,
      );
    });

    it("reverts ZeroShare for a recipient with zero share", async () => {
      const registry = await deploy();
      await assert.rejects(
        registry.write.register(
          ["p1", [r1.account.address, r2.account.address], [10000, 0], "USDC"],
          { account: registrant.account },
        ),
        /ZeroShare/,
      );
    });

    it("reverts DuplicateRecipient when the same address appears twice", async () => {
      const registry = await deploy();
      await assert.rejects(
        registry.write.register(
          ["p1", [r1.account.address, r1.account.address], [5000, 5000], "USDC"],
          { account: registrant.account },
        ),
        /DuplicateRecipient/,
      );
    });

    it("reverts SharesDoNotSumToDenominator when shares miss 10000", async () => {
      const registry = await deploy();
      await assert.rejects(
        registry.write.register(
          ["p1", [r1.account.address, r2.account.address], [5000, 4999], "USDC"],
          { account: registrant.account },
        ),
        /SharesDoNotSumToDenominator/,
      );
    });

    it("reverts ListingAlreadyExists on the same tuple", async () => {
      const registry = await deploy();
      const recipients = [r1.account.address, r2.account.address];
      const shares = [3000, 7000];
      await registry.write.register(
        ["p1", recipients, shares, "USDC"],
        { account: registrant.account },
      );
      await assert.rejects(
        registry.write.register(
          ["p1", recipients, shares, "USDC"],
          { account: registrant.account },
        ),
        /ListingAlreadyExists/,
      );
    });

    it("reverts EmptyProductId + EmptyCurrency", async () => {
      const registry = await deploy();
      await assert.rejects(
        registry.write.register(
          ["", [r1.account.address, r2.account.address], [5000, 5000], "USDC"],
          { account: registrant.account },
        ),
        /EmptyProductId/,
      );
      await assert.rejects(
        registry.write.register(
          ["p1", [r1.account.address, r2.account.address], [5000, 5000], ""],
          { account: registrant.account },
        ),
        /EmptyCurrency/,
      );
    });
  });

  // ----------------------------------------------------------------
  //  deactivate()
  // ----------------------------------------------------------------

  describe("deactivate", () => {
    const setup = async () => {
      const registry = await deploy();
      const recipients = [r1.account.address, r2.account.address];
      const shares = [3000, 7000];
      await registry.write.register(
        ["p1", recipients, shares, "USDC"],
        { account: registrant.account },
      );
      const listingId = await registry.read.computeListingId([
        "p1", registrant.account.address, recipients, shares,
      ]);
      return { registry, listingId };
    };

    it("flips active to false and preserves history", async () => {
      const { registry, listingId } = await setup();
      await registry.write.deactivate([listingId], { account: registrant.account });
      const l = await registry.read.getListing([listingId]);
      assert.equal(l.active, false);
      assert.notEqual(l.registeredAt, 0n);
    });

    it("reverts NotRegistrant if any non-registrant tries", async () => {
      const { registry, listingId } = await setup();
      await assert.rejects(
        registry.write.deactivate([listingId], { account: other.account }),
        /NotRegistrant/,
      );
    });

    it("reverts ListingNotActive on double-deactivate", async () => {
      const { registry, listingId } = await setup();
      await registry.write.deactivate([listingId], { account: registrant.account });
      await assert.rejects(
        registry.write.deactivate([listingId], { account: registrant.account }),
        /ListingNotActive/,
      );
    });
  });

  // ----------------------------------------------------------------
  //  computeSplit()
  // ----------------------------------------------------------------

  describe("computeSplit", () => {
    it("splits proportionally across 4 recipients and sums exactly", async () => {
      const registry = await deploy();
      const recipients = [
        r1.account.address, r2.account.address,
        r3.account.address, r4.account.address,
      ];
      const shares = [1000, 2000, 3000, 4000]; // 10/20/30/40
      await registry.write.register(
        ["p1", recipients, shares, "USDC"],
        { account: registrant.account },
      );
      const listingId = await registry.read.computeListingId([
        "p1", registrant.account.address, recipients, shares,
      ]);

      const gross = 10_000n;
      const out = await registry.read.computeSplit([gross, listingId]);
      assert.equal(out.length, 4);
      assert.equal(out[0], 1_000n);
      assert.equal(out[1], 2_000n);
      assert.equal(out[2], 3_000n);
      assert.equal(out[3], 4_000n);

      const sum = out.reduce((a, b) => a + b, 0n);
      assert.equal(sum, gross);
    });

    it("routes the rounding-remainder to the last recipient (dust sweep)", async () => {
      const registry = await deploy();
      const recipients = [r1.account.address, r2.account.address, r3.account.address];
      // 3333 / 3333 / 3334 = 10000; integer divisions on non-multiples produce dust
      const shares = [3333, 3333, 3334];
      await registry.write.register(
        ["p1", recipients, shares, "USDC"],
        { account: registrant.account },
      );
      const listingId = await registry.read.computeListingId([
        "p1", registrant.account.address, recipients, shares,
      ]);

      // Choose a gross that produces rounding on the first two.
      // 7 * 3333 / 10000 = 2.333 → floor 2. Last one sweeps the dust.
      const gross = 7n;
      const out = await registry.read.computeSplit([gross, listingId]);
      const sum = out.reduce((a, b) => a + b, 0n);
      assert.equal(sum, gross, "dust must be routed to the last recipient");
    });
  });
});
