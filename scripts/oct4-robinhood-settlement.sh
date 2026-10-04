#!/usr/bin/env bash
# oct4-robinhood-settlement.sh — fires the same agent-authored 3-party
# happy path on Robinhood Chain testnet (chainId 46630), proving the
# primitive is byte-identical across both reserved-slot lanes.
#
# USDC on Robinhood is a MockUSDC with public mint; we mint 1 USDC to the
# buyer here so this script is self-contained.
set -euo pipefail
cd "$(dirname "$0")/.."

source .env
RPC="${ROBINHOOD_TESTNET_RPC:-https://rpc.testnet.chain.robinhood.com}"

REGISTRY=0x69a2dceca723b3ae335806cfae22e2ffea51fc58
ESCROW=0x7a6fef53c85bd7ffc70c16d21b73f3125258a95c
USDC=0xfce6bd68d8d6f858d447f537d206c1e354b44315  # MockUSDC on Robinhood (public mint)

DEPLOYER=$(cast wallet address "$DEPLOYER_PRIVATE_KEY")
BUYER=$(cast wallet address "$BUYER_PRIVATE_KEY")
BURNER=0x000000000000000000000000000000000000D15C

PRODUCT_ID="kajota-mesh-oct4-robinhood-$(date +%s)"
SHARES="[2000,3000,5000]"
RECIPIENTS="[$BUYER,$DEPLOYER,$BURNER]"

echo "=== Oct 4 agent-authored settlement — Robinhood Chain testnet ==="
echo "  Coach (registrant):     $DEPLOYER"
echo "  Concierge (buyer):      $BUYER"
echo "  Recipient #3 (burner):  $BURNER"
echo "  Shares:                 20 / 30 / 50 bps"
echo "  Product id:             $PRODUCT_ID"
echo

# Precompute listingId
LISTING_ID=$(cast call $REGISTRY \
  "computeListingId(string,address,address[],uint16[])(bytes32)" \
  "$PRODUCT_ID" "$DEPLOYER" "$RECIPIENTS" "$SHARES" --rpc-url "$RPC")
echo "listingId: $LISTING_ID"
echo

# 0. Mint 1 USDC to Concierge via the mock's public mint (idempotent to top up)
echo "[0/5] Minting 1 USDC to Concierge via MockUSDC.mint…"
TX0=$(cast send $USDC "mint(address,uint256)" "$BUYER" 1000000 \
  --rpc-url "$RPC" --private-key "$BUYER_PRIVATE_KEY" --json | jq -r '.transactionHash')
echo "   tx0: $TX0"
echo

# 1. Coach registers
echo "[1/5] Coach registering listing on Robinhood RegistryV2…"
TX1=$(cast send $REGISTRY \
  "register(string,address[],uint16[],string)" \
  "$PRODUCT_ID" "$RECIPIENTS" "$SHARES" "USDC" \
  --rpc-url "$RPC" --private-key "$DEPLOYER_PRIVATE_KEY" --json | jq -r '.transactionHash')
echo "   tx1: $TX1"
echo

# 2. Concierge approves 1 USDC
echo "[2/5] Concierge approving 1 USDC spend to EscrowV2…"
TX2=$(cast send $USDC "approve(address,uint256)" $ESCROW 1000000 \
  --rpc-url "$RPC" --private-key "$BUYER_PRIVATE_KEY" --json | jq -r '.transactionHash')
echo "   tx2: $TX2"
echo

# 3. Concierge deposits
echo "[3/5] Concierge depositing 1 USDC into escrow…"
TX3_JSON=$(cast send $ESCROW "deposit(bytes32,uint256)" "$LISTING_ID" 1000000 \
  --rpc-url "$RPC" --private-key "$BUYER_PRIVATE_KEY" --json)
TX3=$(echo "$TX3_JSON" | jq -r '.transactionHash')
DEPOSIT_ID=$(echo "$TX3_JSON" | jq -r '.logs[] | select(.address | ascii_downcase == "'"$(echo $ESCROW | tr A-F a-f)"'") | .topics[1]' | head -1)
echo "   tx3: $TX3"
echo "   depositId: $DEPOSIT_ID"
echo

# 4. Release authority fans out atomically
echo "[4/5] Release authority firing atomic 3-way fan-out…"
TX4=$(cast send $ESCROW "release(bytes32)" "$DEPOSIT_ID" \
  --rpc-url "$RPC" --private-key "$DEPLOYER_PRIVATE_KEY" --json | jq -r '.transactionHash')
echo "   tx4: $TX4"
echo

echo "=== Done. All 5 tx on Robinhood Blockscout ==="
EXPL=https://explorer.testnet.chain.robinhood.com/tx
echo "  Mint:     $EXPL/$TX0"
echo "  Register: $EXPL/$TX1"
echo "  Approve:  $EXPL/$TX2"
echo "  Deposit:  $EXPL/$TX3"
echo "  Release:  $EXPL/$TX4"
