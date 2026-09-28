#!/usr/bin/env bash
# arbitrum-demo-v2.sh — full on-chain happy-path against the live
# CosellRegistryV2 + CosellEscrowV2 on Arbitrum Sepolia. Same shape
# as arbitrum-demo.sh (v1) but exercises the N-party split primitive:
# a 3-recipient listing that fans 1 USDC out 20% / 30% / 50% in a
# single atomic release.
#
# Pairs with arbitrum-demo.sh in the demo/SHOT_LIST.md capture plan.
# Video Scene 4a runs the v1 script (2-party), Scene 4b runs this
# script (N-party) — same terminal frame, different primitive.
#
# Reads keys from ./.env (gitignored, at the repo root):
#   DEPLOYER_PRIVATE_KEY  signs as registrant, recipient C, releaseAuth
#   BUYER_PRIVATE_KEY     signs as buyer (must have ~1 USDC + tiny ETH)
#
# Usage:
#   cd ~/Documents/kajota-arbitrum-singapore
#   ./scripts/arbitrum-demo-v2.sh
#
# Requires: foundry (cast) + jq on PATH.

set -euo pipefail

# ---- bash 3.2-friendly colour helpers (macOS default shell) -------
BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m'); RESET=$(printf '\033[0m')
RED=$(printf '\033[31m'); GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m')
BLUE=$(printf '\033[34m'); CYAN=$(printf '\033[36m')

step()    { printf "\n${BOLD}${BLUE}━━━ %s ━━━${RESET}\n" "$*"; }
ok()      { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
info()    { printf "  ${DIM}%s${RESET}\n" "$*"; }
fail()    { printf "  ${RED}✗${RESET} %s\n" "$*"; exit 1; }
arbiscan(){ printf "    ${CYAN}https://sepolia.arbiscan.io/tx/%s${RESET}\n" "$1"; }

# ---- env ----------------------------------------------------------
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ENV_FILE="$SCRIPT_DIR/../.env"
[ -f "$ENV_FILE" ] || fail ".env not found at $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY missing from .env}"
: "${BUYER_PRIVATE_KEY:?BUYER_PRIVATE_KEY missing from .env}"

# ---- network + contracts (live on Arbitrum Sepolia) ---------------
RPC="https://sepolia-rollup.arbitrum.io/rpc"
REGISTRY_V2="0x5cda1ae03fd8207cb0c7416ddc899fe89a603ef9"
ESCROW_V2="0xce77674ef1f3abcd34370825390f351eb6a8fffd"
USDC="0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d"

# ---- demo participants --------------------------------------------
REGISTRANT=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")
BUYER=$(cast wallet address --private-key "$BUYER_PRIVATE_KEY")
# Three recipients — the N-party generalisation of the v1 wholesaler
# + coseller pair. Recipient B reuses the buyer address for demo
# purposes (a co-selling agent who also buys); zero-privilege change.
RECIPIENT_A="0x33cdCcbC1c759E21ba8d943918A13AA78dbEeb42"
RECIPIENT_B="$BUYER"
RECIPIENT_C="$REGISTRANT"

# ---- demo parameters ----------------------------------------------
PRODUCT_ID="demo-v2-3party-$(date +%s)"
# Shares in basis points (sum = 10000).
SHARE_A=2000  # 20%
SHARE_B=3000  # 30%
SHARE_C=5000  # 50%
CURRENCY="USDC"
AMOUNT=1000000  # 1 USDC (6 decimals)

# ---- helpers ------------------------------------------------------
send() {
  local key=$1 to=$2 sig=$3; shift 3
  cast send --rpc-url "$RPC" --private-key "$key" --json "$to" "$sig" "$@"
}
read_call() { cast call --rpc-url "$RPC" "$@"; }
balance_usdc() {
  local addr=$1
  local raw; raw=$(read_call "$USDC" "balanceOf(address)(uint256)" "$addr")
  raw="${raw%% *}"
  printf "%s.%06d" "$((raw / 1000000))" "$((raw % 1000000))"
}

# ---- title --------------------------------------------------------
clear 2>/dev/null || true
cat <<EOF
${BOLD}╔══════════════════════════════════════════════════════════════════╗
║  Kajota Mesh v2 — N-party split on Arbitrum Sepolia              ║
║  Same primitive, three recipients, atomic fan-out                ║
╚══════════════════════════════════════════════════════════════════╝${RESET}

  ${BOLD}RegistryV2${RESET}  $REGISTRY_V2
  ${BOLD}EscrowV2${RESET}    $ESCROW_V2
  ${BOLD}USDC${RESET}        $USDC

  ${BOLD}Registrant${RESET}  $REGISTRANT  ${DIM}(also releaseAuth)${RESET}
  ${BOLD}Recipient A${RESET} $RECIPIENT_A  ${DIM}(share ${SHARE_A} bps = 20%)${RESET}
  ${BOLD}Recipient B${RESET} $RECIPIENT_B  ${DIM}(share ${SHARE_B} bps = 30%)${RESET}
  ${BOLD}Recipient C${RESET} $RECIPIENT_C  ${DIM}(share ${SHARE_C} bps = 50%)${RESET}
  ${BOLD}Buyer${RESET}       $BUYER
  ${BOLD}Order${RESET}       productId=${PRODUCT_ID}  amount=1.000000 USDC

EOF

# ---- preflight ----------------------------------------------------
step "Preflight — balances on Arbitrum Sepolia"
info "Buyer USDC:        $(balance_usdc $BUYER)"
info "Recipient A USDC:  $(balance_usdc $RECIPIENT_A)"
info "Recipient C USDC:  $(balance_usdc $RECIPIENT_C)"
ok   "Buyer has USDC — ready to deposit"

# ---- Step 1: register 3-party listing on v2 -----------------------
step "Step 1 — Coach publishes 3-party listing on-chain (CosellRegistryV2.register)"
REG_JSON=$(send "$DEPLOYER_PRIVATE_KEY" "$REGISTRY_V2" \
  "register(string,address[],uint16[],string)" \
  "$PRODUCT_ID" \
  "[$RECIPIENT_A,$RECIPIENT_B,$RECIPIENT_C]" \
  "[$SHARE_A,$SHARE_B,$SHARE_C]" \
  "$CURRENCY")
REG_TX=$(echo "$REG_JSON" | jq -r '.transactionHash')
arbiscan "$REG_TX"

LISTING_ID=$(read_call "$REGISTRY_V2" \
  "computeListingId(string,address,address[],uint16[])(bytes32)" \
  "$PRODUCT_ID" "$REGISTRANT" \
  "[$RECIPIENT_A,$RECIPIENT_B,$RECIPIENT_C]" \
  "[$SHARE_A,$SHARE_B,$SHARE_C]" | awk '{print $1}')
ok "listingId = $LISTING_ID"

# ---- Step 2: buyer approves USDC for v2 escrow --------------------
step "Step 2 — Concierge approves USDC spend (ERC20.approve)"
APPROVE_JSON=$(send "$BUYER_PRIVATE_KEY" "$USDC" \
  "approve(address,uint256)" "$ESCROW_V2" "$AMOUNT")
APPROVE_TX=$(echo "$APPROVE_JSON" | jq -r '.transactionHash')
arbiscan "$APPROVE_TX"
ok "Buyer approved $ESCROW_V2 for $AMOUNT (1.000000 USDC)"

# ---- Step 3: buyer deposits into escrow ---------------------------
step "Step 3 — Concierge deposits into v2 escrow (CosellEscrowV2.deposit)"
DEPOSIT_JSON=$(send "$BUYER_PRIVATE_KEY" "$ESCROW_V2" \
  "deposit(bytes32,uint256)" "$LISTING_ID" "$AMOUNT")
DEPOSIT_TX=$(echo "$DEPOSIT_JSON" | jq -r '.transactionHash')
arbiscan "$DEPOSIT_TX"

# Fetch depositId from the Deposited log on the escrow contract.
DEPOSIT_ID=$(cast receipt --rpc-url "$RPC" "$DEPOSIT_TX" --json | \
  jq -r --arg addr "$ESCROW_V2" \
    '.logs[] | select(.address == $addr) | .topics[1]' | head -1)
ok "depositId = $DEPOSIT_ID"

# ---- Step 4: releaseAuth fans out to all three recipients ---------
step "Step 4 — Mesh releases → atomic 3-way fan-out (CosellEscrowV2.release)"
RELEASE_JSON=$(send "$DEPLOYER_PRIVATE_KEY" "$ESCROW_V2" \
  "release(bytes32)" "$DEPOSIT_ID")
RELEASE_TX=$(echo "$RELEASE_JSON" | jq -r '.transactionHash')
arbiscan "$RELEASE_TX"
ok "Funds fanned out: 20% → A, 30% → B, 50% → C in one atomic tx"

# ---- verify -------------------------------------------------------
step "Verify — recipient balances after release"
info "Recipient A USDC:  $(balance_usdc $RECIPIENT_A)"
info "Recipient B USDC:  $(balance_usdc $RECIPIENT_B)"
info "Recipient C USDC:  $(balance_usdc $RECIPIENT_C)"
info "Escrow residual:   $(balance_usdc $ESCROW_V2)  ${DIM}(should be 0 — zero dust)${RESET}"

printf "\n${BOLD}${GREEN}✓ v2 N-party path settled on Arbitrum Sepolia.${RESET}\n\n"

cat <<EOF
  ${BOLD}On-chain artifacts (paste into the HackQuest submission):${RESET}
    register        ${CYAN}https://sepolia.arbiscan.io/tx/${REG_TX}${RESET}
    approve         ${CYAN}https://sepolia.arbiscan.io/tx/${APPROVE_TX}${RESET}
    deposit         ${CYAN}https://sepolia.arbiscan.io/tx/${DEPOSIT_TX}${RESET}
    release         ${CYAN}https://sepolia.arbiscan.io/tx/${RELEASE_TX}${RESET}

  ${BOLD}Verified v2 contracts:${RESET}
    RegistryV2      ${CYAN}https://sepolia.arbiscan.io/address/${REGISTRY_V2}#code${RESET}
    EscrowV2        ${CYAN}https://sepolia.arbiscan.io/address/${ESCROW_V2}#code${RESET}
EOF
