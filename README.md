# Kajota Mesh — Arbitrum Open House Singapore 2026

> **TL;DR.** Agentic social-commerce settlement on Arbitrum. **Kajota Coach** drafts on-chain co-sell listings via a multi-turn AI agent. **Kajota Concierge** runs the buy-side flow. **Mesh** settles the trade trustlessly on Arbitrum, atomically splitting USDC between wholesaler and co-seller the moment delivery is verified.

> **Status — active submission.** Submission window closes **Oct 4, 2026 15:59 Asia/Singapore**. Prize pool $115K USDC (Overall $70K + Promising Products $15K + Grants $30K). Contracts live and verified on Arbitrum Sepolia; deployment on any Arbitrum chain — including Sepolia — satisfies the buildathon deployment requirement.

**HackQuest project page:** [arbitrum-singapore.hackquest.io/projects/Kajota-Mesh](https://arbitrum-singapore.hackquest.io/projects/Kajota-Mesh)

## The problem

African micro-commerce runs on WhatsApp + Telegram groups where wholesalers list goods, micro-distributors ("co-sellers") promote them to their followers, and commission gets paid via off-chain bookkeeping. The status quo requires the co-seller to trust three things, all of which break in practice:

1. The wholesaler won't quietly change the commission split after a high-volume month.
2. The platform's accounting will report cumulative volume honestly.
3. A scheduled payout job actually runs and pays — and doesn't get "delayed for review."

Mesh removes (1) and (3) by moving the trust-critical primitives on-chain. Coach + Concierge are the AI layer; Mesh is the settlement layer.

## What's deployed on Arbitrum Sepolia

| Contract | Purpose | Address |
|---|---|---|
| `CosellRegistry` | Immutable per-listing record of `{productId, wholesaler, coseller, commissionBps, currency}` — deactivate-only, no retroactive edit. Source verified. | [`0xfce6bd68d8d6f858d447f537d206c1e354b44315`](https://sepolia.arbiscan.io/address/0xfce6bd68d8d6f858d447f537d206c1e354b44315#code) |
| `CosellEscrow` | Receives USDC, auto-splits at release. `release()` callable only by `releaseAuth`; `refund()` callable by buyer after timeout. Source verified. | [`0x599869cef2e4c52e2c9074caaf8f9fb0cb191776`](https://sepolia.arbiscan.io/address/0x599869cef2e4c52e2c9074caaf8f9fb0cb191776#code) |
| Circle USDC | Native testnet USDC (6-decimal). | [`0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d`](https://sepolia.arbiscan.io/token/0x75faf114eafb1bdbe2f0316df893fd58ce46aa4d) |

Manifest: [`deployments/421614.json`](deployments/421614.json).

Both contracts verified on **Arbiscan + Sourcify** — click the `0x…#code` links above to read the Solidity source rendered by the explorer.

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

Reproducible via `./scripts/arbitrum-demo.sh` against the live contracts. One full Coach→Concierge→Mesh cycle with 1 USDC deposited and atomically split 10%/90% — Arbiscan-verifiable:

| Step | Actor | Action | Arbiscan |
|---|---|---|---|
| 1 | Wholesaler (Coach) | `CosellRegistry.register` — publishes the listing on-chain | [tx](https://sepolia.arbiscan.io/tx/0xe0a272cd898917d18afb3126d7f8aebdc6fa09b511c6590f4070388b6624c881) |
| 2 | Buyer (Concierge) | `USDC.approve` — grants the escrow spend allowance | [tx](https://sepolia.arbiscan.io/tx/0xdd026528ffd09823a7d19dc5307276a1a4d711daf04d298c5b2cdad7cec12a96) |
| 3 | Buyer (Concierge) | `CosellEscrow.deposit` — moves USDC into escrow | [tx](https://sepolia.arbiscan.io/tx/0x99955fe772f2d04a1352536f80d17740f88439d06e72f3dbe287e5ecbd919a44) |
| 4 | `releaseAuth` (Mesh) | `CosellEscrow.release` — atomic 10%/90% split, no human in the loop | [tx](https://sepolia.arbiscan.io/tx/0xc96a1075e2ba8768a8d6abaf9f5b49fbc296409cf6be76b2c3e8ef06cc4646a8) |

Balance delta (USDC, 6-decimal):

| Wallet | Before | After | Δ |
|---|---|---|---|
| Buyer `0xB15E…7380` | 20.000000 | 19.000000 | −1.000000 |
| Coseller `0x33cd…eb42` | 0.000000 | 0.100000 | +0.100000 (10% commission) |
| Wholesaler `0xe10C…24A4` | 0.000000 | 0.900000 | +0.900000 (90% remainder) |

## Judging-criteria mapping

| Criterion | Where to look |
|---|---|
| Smart contract quality | 58 unit tests across 4 contracts (`pnpm test`). OpenZeppelin 5.1, EVM Cancun, ReentrancyGuard on transfers, prefix-bound Chainlink callbacks. Both production contracts verified on Arbiscan + Sourcify. |
| Product-market fit | Sister-app Kajota is a Nigerian social-commerce app with co-sellers using off-chain commission splits today. Mesh is the path to remove the trust dependency on the platform. |
| Innovation / creativity | Multi-agent (Coach + Concierge) commerce loop where the on-chain registry IS the negotiation surface between the agents. Not "AI generates code that touches a chain" — agents are first-class participants in a settled-on-chain trade. |
| Real problem-solving | Solves a verifiable problem (commission-split trust) for a verifiable user base. Arbitrum's low fees + USDC native make this economically viable for Africa-scale ticket sizes ($5-$50 trades). |

## Repo layout

```
kajota-arbitrum-singapore/
├── contracts/
│   ├── CosellRegistry.sol          deployed + verified
│   ├── CosellEscrow.sol            deployed + verified
│   ├── CosellShipmentVerifier.sol  Chainlink Functions consumer
│   ├── KajotaEscrow.sol            generalised escrow primitive
│   └── test/                       Mock USDC + Functions router
├── test/                           58 unit tests across the 4 contracts
├── scripts/
│   ├── deploy.ts                   hardhat deploy → deployments/<chainId>.json
│   ├── arbitrum-demo.sh            on-chain happy-path reproducer (demo video source)
│   └── chainlink-attestation-source.js
├── deployments/
│   └── 421614.json                 live Arbitrum Sepolia addresses + deployer
├── hardhat.config.ts               Solidity 0.8.24, EVM Cancun, arbitrumSepolia network
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

# Run the test suite — 58 unit tests across 4 contracts
pnpm test

# Compile
pnpm compile

# Deploy to Arbitrum Sepolia (fill DEPLOYER_PRIVATE_KEY in .env first;
# fund the EOA with ~0.0001 Arbitrum Sepolia ETH)
cp .env.example .env
pnpm deploy:arbitrum-sepolia

# Verify on Arbiscan (fill ARBISCAN_API_KEY in .env)
pnpm verify:registry
pnpm verify:escrow

# Reproduce the on-chain happy path end-to-end
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
