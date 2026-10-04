#!/usr/bin/env bash
# oct4-agent-settlement.sh — fires a fresh 3-party agent-authored happy path
# on Arbitrum Sepolia against the live CosellRegistryV2 + CosellEscrowV2.
#
# Narrative: Coach (DEPLOYER) registers a listing, Concierge (BUYER) deposits
# 1 USDC, deployer (release authority) atomically fans the funds out across
# three recipients.
#
# Expects .env with DEPLOYER_PRIVATE_KEY and BUYER_PRIVATE_KEY.
set -euo pipefail
cd "$(dirname "$0")/.."

source .env
RPC="${ARBITRUM_SEPOLIA_RPC:-https://sepolia-rollup.arbitrum.io/rpc}"

REGISTRY=0x5cda1ae03fd8207cb0c7416ddc899fe89a603ef9
ESCROW=0xce77674ef1f3abcd34370825390f351eb6a8fffd
USDC=0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d

DEPLOYER=$(cast wallet address "$DEPLOYER_PRIVATE_KEY")
BUYER=$(cast wallet address "$BUYER_PRIVATE_KEY")
BURNER=0x000000000000000000000000000000000000D15C

PRODUCT_ID="kajota-mesh-oct4-agent-$(date +%s)"
SHARES="[2000,3000,5000]"
RECIPIENTS="[$BUYER,$DEPLOYER,$BURNER]"

echo "=== Oct 4 agent-authored settlement — Arbitrum Sepolia ==="
echo "  Coach (registrant):     $DEPLOYER"
echo "  Concierge (buyer):      $BUYER"
echo "  Recipient #3 (burner):  $BURNER"
echo "  Shares:                 20 / 30 / 50 bps = $SHARES"
echo "  Product id:             $PRODUCT_ID"
echo

# 0. Precompute listingId
LISTING_ID=$(cast call $REGISTRY \
  "computeListingId(string,address,address[],uint16[])(bytes32)" \
  "$PRODUCT_ID" "$DEPLOYER" "$RECIPIENTS" "$SHARES" --rpc-url "$RPC")
echo "Precomputed listingId: $LISTING_ID"
echo

# 1. Coach registers the listing
echo "[1/4] Coach registering listing on CosellRegistryV2…"
TX1=$(cast send $REGISTRY \
  "register(string,address[],uint16[],string)" \
  "$PRODUCT_ID" "$RECIPIENTS" "$SHARES" "USDC" \
  --rpc-url "$RPC" --private-key "$DEPLOYER_PRIVATE_KEY" --json | jq -r '.transactionHash')
echo "   tx1: $TX1"
echo "        https://sepolia.arbiscan.io/tx/$TX1"
echo

# 2. Concierge approves 1 USDC to the escrow
echo "[2/4] Concierge approving 1 USDC spend to CosellEscrowV2…"
TX2=$(cast send $USDC \
  "approve(address,uint256)" $ESCROW 1000000 \
  --rpc-url "$RPC" --private-key "$BUYER_PRIVATE_KEY" --json | jq -r '.transactionHash')
echo "   tx2: $TX2"
echo "        https://sepolia.arbiscan.io/tx/$TX2"
echo

# 3. Concierge deposits 1 USDC into the listing
echo "[3/4] Concierge depositing 1 USDC into escrow…"
TX3_JSON=$(cast send $ESCROW \
  "deposit(bytes32,uint256)" "$LISTING_ID" 1000000 \
  --rpc-url "$RPC" --private-key "$BUYER_PRIVATE_KEY" --json)
TX3=$(echo "$TX3_JSON" | jq -r '.transactionHash')
# Pull Deposited event's depositId (first indexed topic after the event sig)
# Deposited(bytes32 indexed depositId, bytes32 indexed listingId, address indexed buyer, uint256 grossAmount)
DEPOSIT_ID=$(echo "$TX3_JSON" | jq -r '.logs[] | select(.address | ascii_downcase == "'"$(echo $ESCROW | tr A-F a-f)"'") | .topics[1]' | head -1)
echo "   tx3: $TX3"
echo "        https://sepolia.arbiscan.io/tx/$TX3"
echo "   depositId: $DEPOSIT_ID"
echo

# 4. Release authority (deployer) atomically fans out
echo "[4/4] Release authority firing atomic 3-way fan-out…"
TX4=$(cast send $ESCROW \
  "release(bytes32)" "$DEPOSIT_ID" \
  --rpc-url "$RPC" --private-key "$DEPLOYER_PRIVATE_KEY" --json | jq -r '.transactionHash')
echo "   tx4: $TX4"
echo "        https://sepolia.arbiscan.io/tx/$TX4"
echo

echo "=== Done. All 4 tx on Arbiscan ==="
echo "  Register: https://sepolia.arbiscan.io/tx/$TX1"
echo "  Approve:  https://sepolia.arbiscan.io/tx/$TX2"
echo "  Deposit:  https://sepolia.arbiscan.io/tx/$TX3"
echo "  Release:  https://sepolia.arbiscan.io/tx/$TX4"
echo
echo "  Listing:  $LISTING_ID"
echo "  Deposit:  $DEPOSIT_ID"
echo "  Product:  $PRODUCT_ID"
