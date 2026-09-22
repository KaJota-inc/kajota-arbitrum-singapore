import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { network } from "hardhat";
import { getAddress } from "viem";

/**
 * Unit tests for AgentIdentityBinding — the ERC-8004 hop from Mantle
 * (where the Coach agent's identity lives) to Arbitrum (where the
 * settlement runs).
 */
describe("AgentIdentityBinding", async () => {
  const { viem } = await network.create();
  const [operator, other] = await viem.getWalletClients();

  const same = (a: string, b: string) => assert.equal(getAddress(a), getAddress(b));

  const deploy = async () => await viem.deployContract("AgentIdentityBinding");

  // ERC-8004 IdentityRegistry as it lives on Mantle Sepolia today.
  const HOME_REGISTRY = "0x8004A818BFB912233c491871b3d84c89A494BD9e" as const;
  const HOME_CHAIN_ID = 5003n; // Mantle Sepolia
  const AGENT_ID = 303n; // Coach agent (matches app.json extra.coachAgentId)
  const ATTESTATION =
    "0x000000000000000000000000000000000000000000000000000000000000c0ac";

  describe("bindAgent", () => {
    it("stores a fresh binding and emits AgentBound", async () => {
      const c = await deploy();
      await c.write.bindAgent(
        [AGENT_ID, HOME_REGISTRY, Number(HOME_CHAIN_ID), ATTESTATION],
        { account: operator.account },
      );
      const b = await c.read.bindingOf([operator.account.address]);
      assert.equal(b.agentId, AGENT_ID);
      same(b.homeRegistry, HOME_REGISTRY);
      assert.equal(b.homeChainId, HOME_CHAIN_ID);
      assert.equal(b.attestationHash, ATTESTATION);
      assert.equal(b.active, true);
      assert.notEqual(b.boundAt, 0n);
    });

    it("hasActiveBinding returns true for a bound operator", async () => {
      const c = await deploy();
      await c.write.bindAgent(
        [AGENT_ID, HOME_REGISTRY, Number(HOME_CHAIN_ID), ATTESTATION],
        { account: operator.account },
      );
      assert.equal(await c.read.hasActiveBinding([operator.account.address]), true);
      assert.equal(await c.read.hasActiveBinding([other.account.address]), false);
    });

    it("reverts ZeroAgentId / ZeroHomeRegistry / ZeroHomeChainId", async () => {
      const c = await deploy();
      await assert.rejects(
        c.write.bindAgent(
          [0n, HOME_REGISTRY, Number(HOME_CHAIN_ID), ATTESTATION],
          { account: operator.account },
        ),
        /ZeroAgentId/,
      );
      await assert.rejects(
        c.write.bindAgent(
          [AGENT_ID, "0x0000000000000000000000000000000000000000", Number(HOME_CHAIN_ID), ATTESTATION],
          { account: operator.account },
        ),
        /ZeroHomeRegistry/,
      );
      await assert.rejects(
        c.write.bindAgent(
          [AGENT_ID, HOME_REGISTRY, 0, ATTESTATION],
          { account: operator.account },
        ),
        /ZeroHomeChainId/,
      );
    });

    it("reverts BindingAlreadyExists on a second bind without revoke", async () => {
      const c = await deploy();
      await c.write.bindAgent(
        [AGENT_ID, HOME_REGISTRY, Number(HOME_CHAIN_ID), ATTESTATION],
        { account: operator.account },
      );
      await assert.rejects(
        c.write.bindAgent(
          [AGENT_ID + 1n, HOME_REGISTRY, Number(HOME_CHAIN_ID), ATTESTATION],
          { account: operator.account },
        ),
        /BindingAlreadyExists/,
      );
    });
  });

  describe("updateBinding", () => {
    it("rotates identity in place", async () => {
      const c = await deploy();
      await c.write.bindAgent(
        [AGENT_ID, HOME_REGISTRY, Number(HOME_CHAIN_ID), ATTESTATION],
        { account: operator.account },
      );
      const NEW_ID = AGENT_ID + 7n;
      await c.write.updateBinding(
        [NEW_ID, HOME_REGISTRY, Number(HOME_CHAIN_ID), ATTESTATION],
        { account: operator.account },
      );
      const b = await c.read.bindingOf([operator.account.address]);
      assert.equal(b.agentId, NEW_ID);
    });

    it("reverts NoBindingForOperator when no active binding exists", async () => {
      const c = await deploy();
      await assert.rejects(
        c.write.updateBinding(
          [AGENT_ID, HOME_REGISTRY, Number(HOME_CHAIN_ID), ATTESTATION],
          { account: operator.account },
        ),
        /NoBindingForOperator/,
      );
    });
  });

  describe("revokeBinding", () => {
    it("flips active=false and stops hasActiveBinding", async () => {
      const c = await deploy();
      await c.write.bindAgent(
        [AGENT_ID, HOME_REGISTRY, Number(HOME_CHAIN_ID), ATTESTATION],
        { account: operator.account },
      );
      await c.write.revokeBinding({ account: operator.account });
      assert.equal(await c.read.hasActiveBinding([operator.account.address]), false);
      // The stored binding row is still there — only the active flag flips.
      const b = await c.read.bindingOf([operator.account.address]);
      assert.equal(b.active, false);
      assert.equal(b.agentId, AGENT_ID);
    });

    it("allows re-bind after revoke", async () => {
      const c = await deploy();
      await c.write.bindAgent(
        [AGENT_ID, HOME_REGISTRY, Number(HOME_CHAIN_ID), ATTESTATION],
        { account: operator.account },
      );
      await c.write.revokeBinding({ account: operator.account });
      // Fresh bind should succeed.
      await c.write.bindAgent(
        [AGENT_ID + 42n, HOME_REGISTRY, Number(HOME_CHAIN_ID), ATTESTATION],
        { account: operator.account },
      );
      const b = await c.read.bindingOf([operator.account.address]);
      assert.equal(b.agentId, AGENT_ID + 42n);
      assert.equal(b.active, true);
    });

    it("reverts NoBindingForOperator when caller was never bound", async () => {
      const c = await deploy();
      await assert.rejects(
        c.write.revokeBinding({ account: other.account }),
        /NoBindingForOperator/,
      );
    });
  });
});
