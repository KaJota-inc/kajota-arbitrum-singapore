# Kajota Mesh — Arbitrum Open House Singapore 2026

> **Kajota Mesh is the atomic escrow + commission-split settlement primitive for commerce agents on Arbitrum.** USDC in, N-party split out, one tx. Registry semantics are deactivate-only so an agent that drafted a listing can't retroactively cut its counterparty's share after volume lands.
>
> Four composable contracts around the primitive: **v1** (2-party split) · **v2** (N-party split, additive) · **AgentIdentityBinding** (ERC-8004 cross-chain hop) · **X402DepositFacilitator** (gasless deposits via EIP-3009). Settles in either **Circle USDC** or **Paxos USDG** against the same shared registry. **97 unit tests · live and verified on both Arbitrum Sepolia and Robinhood Chain testnet · 17 deployed-and-verified contracts across the two chains.**
>
> Coach (sell-side drafting agent) and Concierge (buy-side purchase agent) are the **reference integration** below — proof the primitive plugs into real agents. Bring your own.

> **Status — active submission.** Submission window closes **Oct 4, 2026 15:59 Asia/Singapore**. Prize pool $115K USDC (Overall $70K + Promising Products $15K + Grants $30K). Arbitrum Sepolia deployment satisfies the buildathon deployment rule.

**Live demo:** [**kajota-mesh.vercel.app**](https://kajota-mesh.vercel.app) — hero reads live Arb Sepolia state via viem (`listings`, `deposits`, `USDC settled`, `recipients fanned out` — direct from the chain via `getLogs`, no indexer). Connect any wallet, register a listing on `CosellRegistryV2` from your own address, see the tx on Arbiscan in two seconds. No USDC required (gas only; Alchemy Sepolia faucet dispenses in 10 s).

**Oct 4 — first agent-authored settlement.** Fired a fresh 3-party happy path with distinct caller-role separation: Coach (sell-side drafter) registered the listing, Concierge (buy-side purchaser) deposited 1 USDC, release authority atomically fanned the funds out across three recipients, zero dust retained. All four txs on-chain:

- Coach registers listing: [`0x07b1…6dd2`](https://sepolia.arbiscan.io/tx/0x07b1930248fec948e8c46a810bdec270177937181da549a306cfb9cecaa86dd2)
- Concierge approves USDC: [`0xeabd…df5e`](https://sepolia.arbiscan.io/tx/0xeabdcb5213ea6ab1cf62bfc665213e749d788e028515d08440b148a5decbdf5e)
- Concierge deposits 1 USDC: [`0xf667…98be`](https://sepolia.arbiscan.io/tx/0xf6674b803b264274c34c9142142a062f6cd792aa07a8968c9f9e7abdc1a198be)
- Release authority atomic fan-out: [`0x1b42…033b`](https://sepolia.arbiscan.io/tx/0x1b42ee6b0b39d99bf205d25e0bed0a1cd82843b9e99ce0de8eddfa9a20d4033b)

Reproducible: [`./scripts/oct4-agent-settlement.sh`](scripts/oct4-agent-settlement.sh) — fires the same 4-tx flow with distinct caller roles against the live contracts.

**Oct 4 — the same primitive, re-fired on Robinhood Chain testnet (chainId 46630).** Byte-identical bytecode on the reserved-slot lane. Mint 1 USDC via MockUSDC, Coach registers, Concierge deposits, release authority fans out — all in a single `./scripts/oct4-robinhood-settlement.sh` run. Receipts:

- Mint 1 USDC: [`0x668c…52ef`](https://explorer.testnet.chain.robinhood.com/tx/0x668c284e2efe9cdeef39f2f472e238c0d09727c6ae769818330361e6fe2452ef)
- Register: [`0x9365…33df`](https://explorer.testnet.chain.robinhood.com/tx/0x936563f81f657430c683efedf0aace68119096bbb7083a5b96773bd7d9e933df)
- Approve + deposit: [`0x56b1…e6f4`](https://explorer.testnet.chain.robinhood.com/tx/0x56b1f7bca471c54bfeeea9428fe767010d7057e9845eba01e50a8a420c88e6f4) / [`0x6f4e…892a`](https://explorer.testnet.chain.robinhood.com/tx/0x6f4e973c5157b72dcd4ea8bcb87dea6a6823631a1aa837944bbb2bfbe644892a)
- Release: [`0xfe61…c9d9`](https://explorer.testnet.chain.robinhood.com/tx/0xfe611e11f020b9b550e8e66df21fdd363c6aff4e58e373a7d98035ccff7bc9d9)

The reserved-slot lane isn't just claimed — it's exercised with a full end-to-end settlement in the same session as the Arbitrum run.

**HackQuest project page:** [arbitrum-singapore.hackquest.io/projects/Kajota-Mesh](https://arbitrum-singapore.hackquest.io/projects/Kajota-Mesh) · **Stack:** Solidity 0.8.24 · OpenZeppelin 5.1 · viem · Hardhat 3 · Chainlink Functions

## The problem

African micro-commerce runs on WhatsApp + Telegram groups where wholesalers list goods, micro-distributors ("co-sellers") promote them to their followers, and commission gets paid via off-chain bookkeeping. The status quo requires the co-seller to trust three things, all of which break in practice:

1. The wholesaler won't quietly change the commission split after a high-volume month.
2. The platform's accounting will report cumulative volume honestly.
3. A scheduled payout job actually runs and pays — and doesn't get "delayed for review."

Mesh removes (1) and (3) by moving the trust-critical primitives on-chain. Coach + Concierge are the AI layer; Mesh is the settlement layer.

## What's deployed on Arbitrum Sepolia

All eight contracts of the extended primitive are live and source-verified on **Arbiscan + Sourcify** — click any `0x…#code` link to read the Solidity as-deployed.

| Contract | Purpose | Address |
|---|---|---|
| `CosellRegistry` (v1) | Immutable per-listing record of `{productId, wholesaler, coseller, commissionBps, currency}` — deactivate-only, no retroactive edit. | [`0xfce6bd68d8d6f858d447f537d206c1e354b44315`](https://sepolia.arbiscan.io/address/0xfce6bd68d8d6f858d447f537d206c1e354b44315#code) |
| `CosellEscrow` (v1) | Receives USDC, auto-splits at release. `release()` callable only by `releaseAuth`; `refund()` callable by buyer after timeout. | [`0x599869cef2e4c52e2c9074caaf8f9fb0cb191776`](https://sepolia.arbiscan.io/address/0x599869cef2e4c52e2c9074caaf8f9fb0cb191776#code) |
| `CosellRegistryV2` | N-party generalisation of v1 — up to 16 recipients with an arbitrary share table that must sum to exactly 10000 basis points. Additive; v1 is not touched. | [`0x5cda1ae03fd8207cb0c7416ddc899fe89a603ef9`](https://sepolia.arbiscan.io/address/0x5cda1ae03fd8207cb0c7416ddc899fe89a603ef9#code) |
| `CosellEscrowV2` | N-party fan-out at release. Rounding remainder falls to the last recipient by convention; zero dust retained by the escrow. | [`0xce77674ef1f3abcd34370825390f351eb6a8fffd`](https://sepolia.arbiscan.io/address/0xce77674ef1f3abcd34370825390f351eb6a8fffd#code) |
| `AgentIdentityBinding` | Records `(agentId, homeRegistry, homeChainId, attestationHash)` per caller EOA — the on-chain hop from Arbitrum Sepolia to Coach's **ERC-8004** identity on Mantle Sepolia. | [`0x716d9c1229d38ec6f6cd7a5edd781e757a73f629`](https://sepolia.arbiscan.io/address/0x716d9c1229d38ec6f6cd7a5edd781e757a73f629#code) |
| `X402DepositFacilitator` | Server-side of the **x402** gasless-deposit flow. Consumes an EIP-3009 `TransferWithAuthorization` from the buyer, pulls USDC, calls `CosellEscrowV2.deposit` in one relay. See [`docs/X402.md`](docs/X402.md). | [`0xdbae565ce0be455e859cd8ff42aec8ad30bbbcf9`](https://sepolia.arbiscan.io/address/0xdbae565ce0be455e859cd8ff42aec8ad30bbbcf9#code) |
| `CosellEscrowV2` (USDG) | Paxos USDG-flavored v2 escrow — same code, different settlement token. Registers against the shared `CosellRegistryV2`. | [`0xfc82984e0282af934dca6c38d715235d491303c2`](https://sepolia.arbiscan.io/address/0xfc82984e0282af934dca6c38d715235d491303c2#code) |
| `X402DepositFacilitator` (USDG) | Paxos USDG-flavored x402 facilitator, wired to the USDG escrow. EIP-3009 works identically to USDC's — Paxos ships the same spec. | [`0x15f42a9f92ab72ec67fb4298f9a95a476382d0ac`](https://sepolia.arbiscan.io/address/0x15f42a9f92ab72ec67fb4298f9a95a476382d0ac#code) |
| Circle USDC | Native Arbitrum Sepolia USDC (6-decimal). | [`0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d`](https://sepolia.arbiscan.io/token/0x75faf114eafb1bdbe2f0316df893fd58ce46aa4d) |
| Paxos USDG | Native Arbitrum Sepolia USDG (6-decimal). Standard ERC-20 + EIP-3009 + EIP-2612. | [`0xFFC95faa3d63Cde504a05B567C600B78C0b41892`](https://sepolia.arbiscan.io/token/0xFFC95faa3d63Cde504a05B567C600B78C0b41892) |

Manifest: [`deployments/421614.json`](deployments/421614.json). `KajotaEscrow` (single-recipient + dispute path) is additionally live on Robinhood Chain testnet (section below).

## Also live on Robinhood Chain Testnet (chainId 46630)

Deployed Oct 2, 2026 — same source, same OpenZeppelin 5.1 toolchain, same test suite. Reserved-slot lane per the buildathon's Prizes & Judging page (*"At minimum 1 of 3 prizes is reserved for a project building on Robinhood Chain"*). All nine contracts source-verified on **Sourcify** against chain 46630.

| Contract | Purpose | Address |
|---|---|---|
| `MockUSDC` (6-decimal) | Mock ERC-20 used in place of Circle USDC (not yet native on Robinhood testnet). Standard decimals + mint for testnet use. | [`0xfce6…44315`](https://explorer.testnet.chain.robinhood.com/address/0xfce6bd68d8d6f858d447f537d206c1e354b44315) |
| `CosellRegistry` (v1) | Same as Arbitrum Sepolia. | [`0x5998…91776`](https://explorer.testnet.chain.robinhood.com/address/0x599869cef2e4c52e2c9074caaf8f9fb0cb191776) |
| `CosellEscrow` (v1) | Same as Arbitrum Sepolia. | [`0xd509…4148`](https://explorer.testnet.chain.robinhood.com/address/0xd5090ebc41c8869fdf821cc5ef49f23b7baf4148) |
| `CosellRegistryV2` | Same as Arbitrum Sepolia. | [`0x69a2…1fc58`](https://explorer.testnet.chain.robinhood.com/address/0x69a2dceca723b3ae335806cfae22e2ffea51fc58) |
| `CosellEscrowV2` (MockUSDC) | v2 escrow wired to the MockUSDC above. | [`0x7a6f…a95c`](https://explorer.testnet.chain.robinhood.com/address/0x7a6fef53c85bd7ffc70c16d21b73f3125258a95c) |
| `KajotaEscrow` | Single-recipient + dispute path. | [`0x11b7…80ef`](https://explorer.testnet.chain.robinhood.com/address/0x11b7b2dd613d81f9ac1eceb7a57b3feba4d580ef) |
| `AgentIdentityBinding` | ERC-8004 cross-chain hop. | [`0x6d92…ea58`](https://explorer.testnet.chain.robinhood.com/address/0x6d92991047f82d38347e33c24c8a24e3c65dea58) |
| `X402DepositFacilitator` (MockUSDC) | x402 facilitator wired to MockUSDC + v2 escrow. | [`0xaad4…63fa5`](https://explorer.testnet.chain.robinhood.com/address/0xaad4f90c1eba70b3c70b7d2d6f21c6ab46763fa5) |
| `CosellEscrowV2` (**USDG**) | v2 escrow wired to Paxos' canonical USDG on Robinhood testnet. | [`0x9eae…4ea6`](https://explorer.testnet.chain.robinhood.com/address/0x9eae832c96cdb5655122adfff76da05cc2a24ea6) |
| `X402DepositFacilitator` (**USDG**) | x402 facilitator wired to USDG. | [`0xd36e…78b3`](https://explorer.testnet.chain.robinhood.com/address/0xd36e3e9ede45077b8d5b9b4e6839c66cdbb378b3) |
| Paxos USDG | Canonical USDG on Robinhood testnet (6-decimal, EIP-3009 + EIP-2612). | [`0x7E95…802F`](https://explorer.testnet.chain.robinhood.com/address/0x7E955252E15c84f5768B83c41a71F9eba181802F) |

Manifest: [`deployments/46630.json`](deployments/46630.json). Combined deploy gas across both USDC-flavored and USDG-flavored stacks: **~0.00009 ETH** on Robinhood testnet.

## The primitive, extended

The verified v1 pair settles two-party trades. The rest of the stack **extends the primitive without touching v1** — each new contract is additive; nothing in the verified deploy changes shape.

| Contract | What it adds | Tests |
|---|---|---|
| `CosellRegistryV2` + `CosellEscrowV2` | N-party split, 2..16 recipients, shares must sum to exactly 10000 basis points, atomic fan-out at release. Rounding remainder falls to the last recipient by convention; zero dust retained by the escrow. | +24 |
| `AgentIdentityBinding` | Records `(agentId, homeRegistry, homeChainId, attestationHash)` on the settlement chain so a judge reading an Arbitrum tx can correlate the caller's EOA to its **ERC-8004** identity on Mantle Sepolia. Metadata, not proof — verifiers resolve against the home chain. | +9 |
| `X402DepositFacilitator` | Server-side settlement for the **x402** flow. Buyer signs one EIP-3009 `TransferWithAuthorization` (Circle's canonical domain); any facilitator relays; the buyer never touches ETH. Refund path forwards permissionlessly to the recorded original buyer. See [`docs/X402.md`](docs/X402.md). | +6 |
| `KajotaEscrow` | Single-recipient escrow with a full dispute path (`raiseDispute` / `resolveDispute`), timeout refund, and Chainlink Functions resolver hook. Reused verbatim from the ETHGlobal NY build — layered story rather than a duplicate primitive. | (baseline) |

All four compile against the same OpenZeppelin 5.1 + Solidity 0.8.24 + EVM Cancun toolchain. `MockUSDC` (test-only, `contracts/test/`) implements EIP-3009 byte-for-byte compatible with Circle's canonical domain so the x402 unit tests double as smoke tests for the real-USDC path on Arbitrum Sepolia.

**Multi-stablecoin settlement.** Because both escrow and facilitator take an `IERC20` at construction, the same code deploys against any standard 6-decimal stablecoin. Two token variants are live and verified on Arbitrum Sepolia today: the Circle USDC pair (addresses above) and a Paxos USDG pair (`CosellEscrowV2 → 0xfc82984e…` + `X402DepositFacilitator → 0x15f42a9f…`). The v2 registry is shared across both — a listing can settle in whichever token the buyer signs an authorization for. Operational note for production users: Paxos' `ASSET_PROTECTION_ROLE` can freeze balances via `isFrozen(address)`, so an escrow holding USDG carries a distinct trust surface from one holding USDC. Not a concern for testnet demos; worth naming for anyone forking the primitive.

## Agentic chain

```
┌────────────────────────────────────────────────────────────┐
│  Kajota Coach Agent v2 — multi-turn LLM drafting agent     │
│  github.com/KaJota-inc/kajota-coach                        │
│                                                             │
│   wholesaler chats →  agent drafts CosellListing →         │
│   wholesaler confirms → `publishListing` tool fires        │
└──────────────────────────┬─────────────────────────────────┘
                           │  mints on Arbitrum Sepolia
                           ▼
┌────────────────────────────────────────────────────────────┐
│  CosellRegistry        (Arbitrum Sepolia, this repo)        │
│                                                             │
│   register(productId, wholesaler, coseller, bps, currency) │
│   → listingId = keccak256(productId, wholesaler, coseller) │
└──────────────────────────┬─────────────────────────────────┘
                           │  referenced by listingId
                           ▼
┌────────────────────────────────────────────────────────────┐
│  Kajota Concierge Agent — buy-side autonomous flow         │
│  github.com/KaJota-inc/kajota-mobile-backend (hackathon)   │
│                                                             │
│   buyer says "I want X" → agent identifies listing →       │
│   walks pay-in (LI.FI cross-chain) → calls escrow.deposit  │
└──────────────────────────┬─────────────────────────────────┘
                           │  USDC into escrow
                           ▼
┌────────────────────────────────────────────────────────────┐
│  CosellEscrow         (Arbitrum Sepolia, this repo)         │
│                                                             │
│   deposit(listingId, gross)  ← buyer transfers USDC        │
│   release(depositId)         ← releaseAuth                 │
│                              ↓                              │
│   coseller wallet gets commissionBps share                 │
│   wholesaler gets remainder, atomically                    │
└────────────────────────────────────────────────────────────┘
```

**Why this is agentic, not just "AI + a chain":**

- **Two agents in conversation with each other** — Coach (sell-side) and Concierge (buy-side) negotiate via the on-chain Registry as a coordination surface. Neither needs to trust the other; they just trust what the registry says.
- **The agents take real on-chain actions, not just suggestions.** Coach's `publishListing` tool issues an Arbitrum tx via a wholesaler-signed wallet. Concierge's `executePurchase` tool issues a `CosellEscrow.deposit` tx via the buyer's wallet.
- **Smart-contract-level guardrails for agent autonomy.** Even if Coach mis-drafts a commission split, the registry's `deactivate-only` semantics mean the wholesaler can't retroactively reduce it after a high-volume month. The chain is the safety layer for the agents.

## Live on-chain happy path — Arbitrum Sepolia

Reproducible via `./scripts/arbitrum-demo.sh` against the live contracts. One full Coach→Concierge→Mesh cycle with 1 USDC deposited and atomically split 10%/90% — Arbiscan-verifiable. Re-run Sep 21, 2026 at 25.15 s wall time:

| Step | Actor | Action | Arbiscan |
|---|---|---|---|
| 1 | Wholesaler (Coach) | `CosellRegistry.register` — publishes the listing on-chain | [tx](https://sepolia.arbiscan.io/tx/0x9c3696db895ae404e39e83b32336ed481b2f8d11b648e6fe20c75eb9f261afed) |
| 2 | Buyer (Concierge) | `USDC.approve` — grants the escrow spend allowance | [tx](https://sepolia.arbiscan.io/tx/0xcedfab5127841b8b565b813991799eb9e76223cf412cb68a0a6bedf401ecc151) |
| 3 | Buyer (Concierge) | `CosellEscrow.deposit` — moves USDC into escrow | [tx](https://sepolia.arbiscan.io/tx/0x6976e867e143dff8244e7b846a79be742b8b08998a9b8b76277e4d2098a46c88) |
| 4 | `releaseAuth` (Mesh) | `CosellEscrow.release` — atomic 10%/90% split, no human in the loop | [tx](https://sepolia.arbiscan.io/tx/0xf9d5674cf29ff2e577cd7d3d81605efd8d2820075610ab13ee3d8f5170060e42) |

Balance delta (USDC, 6-decimal):

| Wallet | Before | After | Δ |
|---|---|---|---|
| Buyer `0xB15E…7380` | 15.000000 | 14.000000 | −1.000000 |
| Coseller `0x33cd…eb42` | 0.500000 | 0.600000 | +0.100000 (10% commission) |
| Wholesaler `0xe10C…24A4` | 4.500000 | 5.400000 | +0.900000 (90% remainder) |

*Starting balances reflect residual from prior demo runs against the same live contracts. Δ is what matters: 10% / 90% split, atomic, no reserve retained by escrow.*

## Live on-chain happy path — v2 N-party split

Same happy path against `CosellRegistryV2` + `CosellEscrowV2`, this time with **three recipients** on a 20% / 30% / 50% share table. Ran Sep 22, 2026 on Arbitrum Sepolia:

| Step | Actor | Action | Arbiscan |
|---|---|---|---|
| 1 | Registrant (Coach) | `CosellRegistryV2.register` — publishes a 3-party listing (shares 2000 / 3000 / 5000 bps) | [tx](https://sepolia.arbiscan.io/tx/0xf151179e23b3efc57bc796887c41ecff8ee57c03124c46d852096fb3a14e2ae2) |
| 2 | Buyer | `USDC.approve` — grants the v2 escrow the spend allowance | [tx](https://sepolia.arbiscan.io/tx/0x02dca68a5178a1ac0bd549468af4e637be2174aae5717c853869a14bd75ea706) |
| 3 | Buyer | `CosellEscrowV2.deposit` — 1 USDC into escrow | [tx](https://sepolia.arbiscan.io/tx/0xd746b3fa63c7379d717877b5bb85640a403ac1bea4adae761a20b1f4def60d28) |
| 4 | `releaseAuth` | `CosellEscrowV2.release` — atomic 3-way fan-out, zero dust | [tx](https://sepolia.arbiscan.io/tx/0xf803675ed70fb88292817a471ac9ebabbe62f887c07ff6786df7b09da7f2d6f3) |

Balance delta (USDC, 6-decimal, 1 USDC deposited):

| Wallet | Share | Received |
|---|---|---|
| Recipient A `0x33cd…eb42` | 20% | +0.200000 |
| Recipient B `0xB15E…7380` | 30% | +0.300000 |
| Recipient C (registrant) `0xe10C…24A4` | 50% | +0.500000 |
| **Sum** |  | **+1.000000** — zero dust retained in the escrow |

## Judging-criteria mapping

| Criterion | Where to look |
|---|---|
| Smart contract quality | 97 unit tests across 7 contracts (`pnpm test`), all green. Solidity 0.8.24 + EVM Cancun, OpenZeppelin 5.1, `ReentrancyGuard` on every value-moving path, prefix-bound Chainlink Functions callbacks, deactivate-only registry semantics (no retroactive edits after volume lands), sum-to-10000 basis-point invariant on N-party shares, per-signer nonce map on EIP-3009 auths, mainnet-chainId guardrail in the deploy script. Both v1 production contracts source-verified on **Arbiscan + Sourcify** — click `#code` on any address link and read the Solidity as-deployed. Reproducible on-chain happy path (`./scripts/arbitrum-demo.sh`) with four Arbiscan tx links below. |
| Product-market fit | Mesh's primitive shape — atomic N-party split at release — maps cleanly onto three commerce agent surfaces already shipping USDC on Arbitrum: (a) co-selling / affiliate flows where a wholesaler agent and a distributor agent must trust the split before any human sees the money, (b) refund pipelines where a dispute agent must be able to move funds without gaining the ability to keep them, and (c) recurring settlements from autonomous purchase agents. Reference integration proof: [`kajota-coach`](https://github.com/KaJota-inc/kajota-coach) already ships a multi-turn drafting agent with a `publishListing` tool that signs `CosellRegistry.register` against these contracts. |
| Innovation / creativity | Two design decisions that don't show up in most commerce-escrow primitives: **(1) The split is on the release action, not the deposit.** `CosellEscrow.release` takes zero arguments — the split is fully determined by the registry snapshot recorded at deposit time. An agent controlling `releaseAuth` can trigger the release but cannot influence who gets what. **(2) The registry is a coordination surface between adversarial agents.** A drafting agent (Coach) and a purchase agent (Concierge) never need to trust each other's inputs; they only need to trust the registry's immutability. That flips the trust model of most "AI in commerce" pitches from "trust the agent" to "trust the contract, not the agent." |
| Real problem-solving | Kajota is a live Nigerian social-commerce app with real co-sellers doing off-chain commission splits today; the pain isn't hypothetical. USDC-native + $0.01-tier Arbitrum fees make sub-$1 commissions on $5–$50 trades economically viable — mainnet Ethereum settlement would consume the split. Deploying to Arbitrum isn't decorative: at this ticket size the L2's cost floor is the reason the primitive is possible at all. |

## Positioning vs adjacent Arbitrum work

Adjacent projects on prior Arbitrum Open House podiums:

- **Pact Network** (Open House London Agentic, 3rd) — risk layer for agentic payments. **Different problem:** Pact assesses counterparty and execution risk *before* funds move; Mesh atomically enforces the agreed split *when* funds move. They stack — a Pact-gated flow that uses Mesh for the settlement leg loses no property of either. Mesh is not trying to price risk.
- **Fangorn** (Open House NYC, 2nd) — data commerce primitives for the agentic web, built with Stylus + ERC-8004 + x402. **Different vertical, overlapping toolkit:** Fangorn's primitives compensate agents for producing data; Mesh's primitive settles commerce that agents *coordinate on humans' behalf* — different sender-vs-recipient shape entirely. Where we borrow from Fangorn's toolkit we do so honestly and cite the file: `AgentIdentityBinding` gives Mesh an ERC-8004 cross-chain hop to Coach's Mantle identity, and `X402DepositFacilitator` implements the server-side of the x402 gasless-deposit path (see [docs/X402.md](docs/X402.md)). Stylus is parked pending a proper Arbitrum-Rust cycle.
- **TradeVerus / CapricornDEX / Denaria** (London Open) — trading infrastructure. **Different vertical entirely.**

Adjacent projects also in this Singapore field:

- **Debit Llama** — "a subscription-first alternative to x402 for agents", with account abstraction, zk-proofs, and MCP server integration. Also settles USDG on Arbitrum. **Different shape:** Debit Llama is *pull-payment / recurring debit* — the buyer pre-authorizes a stream the merchant can draw from. Mesh is *one-shot atomic settlement with an N-party split* — one deposit fans to multiple recipients when a delivery condition is met. Both belong in the "agentic payment infra" bucket; the primitives compose (a Debit Llama pull could fund a Mesh escrow, atomically distributed on release), but they're solving different problems. Debit Llama does not implement multi-party fee splits or a coordination-surface registry.
- **StewardPay** — text-message-first RWA purchase agent on Robinhood Chain, USDG-native. **Different vertical:** Steward turns "text `Buy AAPL with 0.5 USDG`" into a stock purchase; the settlement leg is a single-recipient DEX trade, not a multi-party commerce split. No overlap on the fee-split or N-party dimension.

Mesh's specific slice: **atomic escrow with a contract-enforced N-party fee split, coordinated by an on-chain registry that adversarial commerce agents can both trust.** As of this scouting pass (Sep 28, 2026) no other project in the Singapore field sits on that slice.

## Repo layout

```
kajota-arbitrum-singapore/
├── contracts/
│   ├── CosellRegistry.sol           v1 · deployed + verified
│   ├── CosellEscrow.sol             v1 · deployed + verified
│   ├── CosellRegistryV2.sol         v2 · N-party split (additive)
│   ├── CosellEscrowV2.sol           v2 · N-party fan-out
│   ├── AgentIdentityBinding.sol     ERC-8004 cross-chain hop
│   ├── X402DepositFacilitator.sol   EIP-3009 gasless deposit
│   ├── KajotaEscrow.sol             single-recipient + dispute path
│   ├── CosellShipmentVerifier.sol   Chainlink Functions consumer
│   └── test/                        MockUSDC (EIP-3009-aware) + Functions router
├── test/                            97 unit tests across 7 contracts
├── scripts/
│   ├── deploy.ts                    full-stack deploy → deployments/<chainId>.json
│   ├── arbitrum-demo.sh             on-chain happy-path reproducer (demo video source)
│   └── chainlink-attestation-source.js
├── deployments/
│   └── 421614.json                  live Arbitrum Sepolia addresses + deployer
├── docs/
│   └── X402.md                      HTTP 402 → X-PAYMENT round-trip
├── hardhat.config.ts                Solidity 0.8.24, EVM Cancun, arbitrumSepolia + robinhoodTestnet
└── package.json
```

## Sister repos (the AI layer of the agentic chain)

- **Coach Agent v2** (sell-side drafting agent) — [`KaJota-inc/kajota-coach`](https://github.com/KaJota-inc/kajota-coach)
- **Concierge Agent + mobile** (buy-side autonomous flow) — [`KaJota-inc/kajota-mobile-backend`](https://github.com/KaJota-inc/kajota-mobile-backend) + [`KaJota-inc/kajota`](https://github.com/KaJota-inc/kajota). The Arbitrum integration lives on `hackathon/arbitrum-london`; the same contract addresses are reused for the Singapore entry.
- **Original Mesh multi-chain repo** (Ethereum / Base / Mantle Sepolia) — [`KaJota-inc/kajota-mesh`](https://github.com/KaJota-inc/kajota-mesh) (branch `hackathon/arbitrum-london`; same contracts and deployment).

## Running locally

```bash
# Hardhat 3 requires Node ≥ 22.13.0.
nvm use 22

# Install deps
pnpm install

# Run the test suite — 97 unit tests across 7 contracts
pnpm test

# Compile
pnpm compile

# Deploy the full stack (7 contracts: v1 pair, v2 pair, KajotaEscrow,
# AgentIdentityBinding, X402DepositFacilitator) to Arbitrum Sepolia.
# Fill DEPLOYER_PRIVATE_KEY in .env; fund the EOA with a tiny amount
# of Arbitrum Sepolia ETH first.
cp .env.example .env
pnpm deploy:arbitrum-sepolia

# Same script, Robinhood Chain testnet (the reserved-slot lane per
# the buildathon's Prizes & Judging page). chainId 46630 — a
# guardrail in deploy.ts refuses mainnet (4663) explicitly.
pnpm deploy:robinhood-testnet

# Verify v1 on Arbiscan (fill ARBISCAN_API_KEY in .env).
pnpm verify:registry
pnpm verify:escrow

# Reproduce the v1 on-chain happy path end-to-end.
# (fill BUYER_PRIVATE_KEY for a wallet with ≥1 testnet USDC)
./scripts/arbitrum-demo.sh
```

## License

MIT.
<!-- kajota-hub-note -->
## KaJota infrastructure

Part of the [KaJota](https://github.com/KaJota-inc) project. KaJota's Render web
services are consolidated onto a single always-on instance —
**[kajota-hub](https://kajota-hub.onrender.com)** — to stop free-tier
instance-hour exhaustion. If a service from this repo moved there, its live URL
is now a path on the hub (e.g. `/coach-okx`, `/mesh-okx`, `/concierge`,
`/slack`, `/mesh-skill`, `/witness`); see `HUB_MIGRATION.md` where present.
