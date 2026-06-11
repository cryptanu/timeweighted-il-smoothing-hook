#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need forge
need cast
need curl
need jq

DEST_CHAIN_ID="${TIMEWEIGHTED_DESTINATION_CHAIN_ID:-1301}"
DEST_RPC="${UNICHAIN_SEPOLIA_RPC_URL:?UNICHAIN_SEPOLIA_RPC_URL missing}"
LASNA_RPC="${REACTIVE_LASNA_RPC_URL:-https://lasna-rpc.rnk.dev/}"
HOOK="${TIMEWEIGHTED_HOOK:?TIMEWEIGHTED_HOOK missing}"
TOKEN="${TIMEWEIGHTED_TOKEN:?TIMEWEIGHTED_TOKEN missing}"
POOL_ID="${TIMEWEIGHTED_POOL_ID:?TIMEWEIGHTED_POOL_ID missing}"
CALLBACK_PROXY="${TIMEWEIGHTED_CALLBACK_PROXY:?TIMEWEIGHTED_CALLBACK_PROXY missing}"
RVM_SENDER="${TIMEWEIGHTED_RVM_SENDER:?TIMEWEIGHTED_RVM_SENDER missing}"
RSC="${TIMEWEIGHTED_RSC:-}"
PRIVATE_KEY="${PRIVATE_KEY:?PRIVATE_KEY missing}"

DEST_EXPLORER="${DEST_EXPLORER:-https://sepolia.uniscan.xyz/tx}"
LASNA_EXPLORER="${LASNA_EXPLORER:-https://lasna.reactscan.net/tx}"
SQRT_2_X96="112045541949572279837463876454"
REQUEST_EVENT_SIG="ReactiveSettlementRequested(bytes32,bytes32,address,uint160,uint256)"
EXEC_EVENT_SIG="ReactiveSettlementExecuted(address,bytes32,address,uint256)"
RUN_LOG="logs/reactive-demo-$(date +%Y%m%d-%H%M%S).log"

tx_url() {
  local explorer="$1"
  local tx="$2"
  [[ -n "$tx" && "$tx" != "null" ]] && printf "%s/%s" "$explorer" "$tx" || printf "not-found"
}

rpc() {
  local method="$1"
  local params="$2"
  curl -sS "$LASNA_RPC" \
    -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}"
}

hex_to_dec() {
  local value="$1"
  if [[ "$value" == 0x* ]]; then
    printf "%d" "$((16#${value#0x}))"
  else
    printf "%d" "$value"
  fi
}

dec_to_hex() {
  printf "0x%x" "$1"
}

print_section() {
  printf "\n%s\n" "================================================================================"
  printf "%s\n" "$1"
  printf "%s\n" "================================================================================"
}

print_section "TimeWeighted IL Smoothing Hook - Reactive demo"
cat <<EOF
User story:
  1. A long-tenured LP has already supplied liquidity.
  2. Price moves against the LP, creating impermanent loss.
  3. The hook calculates the LP's tenure tier and expected IL reimbursement.
  4. A pool-scoped origin event asks Reactive Network to settle the position.
  5. Lasna RVM observes that event and emits a callback payload.
  6. The Unichain callback proxy calls the hook.
  7. The LP receives the smoothing reserve payout and the position is closed.

Contracts and network:
  Hook:             $HOOK
  Reserve token:    $TOKEN
  Pool ID:          $POOL_ID
  Callback proxy:   $CALLBACK_PROXY
  RVM sender:       $RVM_SENDER
  RSC:              ${RSC:-not-set}
  Destination RPC:  $DEST_RPC
  Lasna RPC:        $LASNA_RPC
EOF

print_section "Pre-flight: prove Reactive integration is wired"
if [[ -z "$RSC" || "$RSC" == "0x0000000000000000000000000000000000000000" ]]; then
  echo "TIMEWEIGHTED_RSC is not set. The project integrates Reactive, but this run cannot prove Lasna without the RSC address."
  exit 1
fi

HOOK_PROXY="$(cast call "$HOOK" 'callbackProxy()(address)' --rpc-url "$DEST_RPC")"
HOOK_RVM="$(cast call "$HOOK" 'reactiveSender()(address)' --rpc-url "$DEST_RPC")"
echo "Hook callbackProxy(): $HOOK_PROXY"
echo "Hook reactiveSender(): $HOOK_RVM"
if [[ "${HOOK_PROXY,,}" != "${CALLBACK_PROXY,,}" ]]; then
  echo "Warning: hook callbackProxy does not match .env. The script will configure it during the origin phase."
fi
if [[ "${HOOK_RVM,,}" != "${RVM_SENDER,,}" ]]; then
  echo "Warning: hook reactiveSender does not match .env. The script will configure it during the origin phase."
fi

print_section "Phase 1: origin-chain setup and event emission"
echo "Running Forge broadcast. This configures auth, funds the reserve, records a Tier 3 demo LP position, and emits ReactiveSettlementRequested."
forge script script/ReactiveE2ETimeWeighted.s.sol \
  --rpc-url "$DEST_RPC" \
  --broadcast \
  --skip-simulation \
  --private-key "$PRIVATE_KEY" \
  -vvv | tee "$RUN_LOG"

BROADCAST_JSON="broadcast/ReactiveE2ETimeWeighted.s.sol/${DEST_CHAIN_ID}/run-latest.json"
if [[ ! -f "$BROADCAST_JSON" ]]; then
  echo "Broadcast file not found: $BROADCAST_JSON" >&2
  exit 1
fi

mapfile -t HASHES < <(jq -r '.transactions[] | select(.hash != null) | .hash' "$BROADCAST_JSON")
if (( ${#HASHES[@]} < 5 )); then
  echo "Expected at least 5 broadcast txs, found ${#HASHES[@]} in $BROADCAST_JSON" >&2
  exit 1
fi

CONFIGURE_TX="${HASHES[0]}"
APPROVE_TX="${HASHES[1]}"
FUND_TX="${HASHES[2]}"
RECORD_TX="${HASHES[3]}"
ORIGIN_TX="${HASHES[4]}"

echo "Configure hook Reactive auth:      $(tx_url "$DEST_EXPLORER" "$CONFIGURE_TX")"
echo "Approve reserve token:            $(tx_url "$DEST_EXPLORER" "$APPROVE_TX")"
echo "Fund smoothing reserve:           $(tx_url "$DEST_EXPLORER" "$FUND_TX")"
echo "Record Tier 3 LP position:        $(tx_url "$DEST_EXPLORER" "$RECORD_TX")"
echo "Origin ReactiveSettlementRequested: $(tx_url "$DEST_EXPLORER" "$ORIGIN_TX")"

ORIGIN_RECEIPT="$(cast receipt "$ORIGIN_TX" --json --rpc-url "$DEST_RPC")"
ORIGIN_BLOCK_HEX="$(jq -r '.blockNumber' <<<"$ORIGIN_RECEIPT")"
ORIGIN_BLOCK="$(hex_to_dec "$ORIGIN_BLOCK_HEX")"
REQUEST_TOPIC0="$(cast keccak "$REQUEST_EVENT_SIG")"
POSITION_KEY="$(jq -r --arg topic "$REQUEST_TOPIC0" '.logs[] | select(.topics[0] == $topic) | .topics[2]' <<<"$ORIGIN_RECEIPT" | tail -n 1)"

if [[ -z "$POSITION_KEY" || "$POSITION_KEY" == "null" ]]; then
  echo "Could not decode position key from origin event." >&2
  exit 1
fi

echo "Origin block:                      $ORIGIN_BLOCK"
echo "Demo position key:                 $POSITION_KEY"

PREVIEW_BEFORE="$(cast call "$HOOK" 'previewPayout(bytes32,uint160)(uint256,uint256,uint256,uint256)' "$POSITION_KEY" "$SQRT_2_X96" --rpc-url "$DEST_RPC")"
echo "User-facing payout preview before relay:"
echo "  (totalIL, requestedPayout, actualPayout, smoothingFactorBps) = $PREVIEW_BEFORE"

print_section "Phase 2: Lasna RVM proof"
echo "Polling RNK near the RVM tail for a transaction whose refTx is the origin event."
RVM_TX=""
for attempt in $(seq 1 40); do
  VM_JSON="$(rpc rnk_getVm "[\"$RVM_SENDER\"]")"
  LAST_RAW="$(jq -r '.result.lastTxNumber // .result.last_tx_number // .result.last // empty' <<<"$VM_JSON")"
  if [[ -n "$LAST_RAW" && "$LAST_RAW" != "null" ]]; then
    LAST_DEC="$(hex_to_dec "$LAST_RAW")"
    START_DEC=$(( LAST_DEC > 96 ? LAST_DEC - 96 : 0 ))
    TXS_JSON="$(rpc rnk_getTransactions "[\"$RVM_SENDER\",\"$(dec_to_hex "$START_DEC")\",\"0x80\"]")"
    RVM_TX="$(jq -r --arg origin "${ORIGIN_TX,,}" '
      (.result.transactions // .result // [])
      | map(select(((.refTx // .ref_tx // .referenceTx // .reference_tx // "") | ascii_downcase) == $origin))
      | last
      | (.hash // .txHash // .tx_hash // "")
    ' <<<"$TXS_JSON")"
    if [[ -n "$RVM_TX" && "$RVM_TX" != "null" ]]; then
      break
    fi
  fi
  echo "  attempt $attempt: RVM tx not visible yet; waiting 15s"
  sleep 15
done

if [[ -n "$RVM_TX" && "$RVM_TX" != "null" ]]; then
  echo "Lasna RVM processed origin event:  $(tx_url "$LASNA_EXPLORER" "$RVM_TX")"
else
  echo "Lasna RVM tx not found in polling window."
  echo "Do not claim a completed Reactive relay until this appears."
fi

print_section "Phase 3: destination callback proof"
echo "Polling Unichain for ReactiveSettlementExecuted(positionKey=$POSITION_KEY)."
CALLBACK_TX=""
EXEC_TOPIC0="$(cast keccak "$EXEC_EVENT_SIG")"
FROM_BLOCK="$ORIGIN_BLOCK"
for attempt in $(seq 1 40); do
  LATEST_BLOCK="$(cast block-number --rpc-url "$DEST_RPC")"
  LOGS_JSON="$(cast logs --json --rpc-url "$DEST_RPC" --from-block "$FROM_BLOCK" --to-block "$LATEST_BLOCK" --address "$HOOK" "$EXEC_EVENT_SIG" || true)"
  CALLBACK_TX="$(jq -r --arg topic "$EXEC_TOPIC0" --arg key "$POSITION_KEY" '
    map(select(.topics[0] == $topic and .topics[2] == $key))
    | last
    | (.transactionHash // .transaction_hash // "")
  ' <<<"${LOGS_JSON:-[]}")"
  if [[ -n "$CALLBACK_TX" && "$CALLBACK_TX" != "null" ]]; then
    break
  fi
  echo "  attempt $attempt: destination callback not visible yet; waiting 15s"
  sleep 15
done

if [[ -n "$CALLBACK_TX" && "$CALLBACK_TX" != "null" ]]; then
  echo "Destination callback settlement:   $(tx_url "$DEST_EXPLORER" "$CALLBACK_TX")"
  CALLBACK_RECEIPT="$(cast receipt "$CALLBACK_TX" --json --rpc-url "$DEST_RPC")"
  echo "Destination callback status:       $(jq -r '.status' <<<"$CALLBACK_RECEIPT")"
else
  echo "Destination callback tx not found in polling window."
  echo "Do not claim final settlement until the callback transaction appears."
fi

print_section "Phase 4: final user-facing state"
PREVIEW_AFTER="$(cast call "$HOOK" 'previewPayout(bytes32,uint160)(uint256,uint256,uint256,uint256)' "$POSITION_KEY" "$SQRT_2_X96" --rpc-url "$DEST_RPC")"
RESERVE_AFTER="$(cast call "$HOOK" 'reserve()(uint256,uint256,uint256,uint256,uint256)' --rpc-url "$DEST_RPC")"
echo "Position preview after relay:"
echo "  (totalIL, requestedPayout, actualPayout, smoothingFactorBps) = $PREVIEW_AFTER"
echo "Reserve state after relay:"
echo "  (totalBalance, morphoDeposited, totalShares, lastMorphoSync, accruedYield) = $RESERVE_AFTER"

print_section "Demo proof summary"
echo "Origin setup/configure tx:         $(tx_url "$DEST_EXPLORER" "$CONFIGURE_TX")"
echo "Origin reserve funding tx:         $(tx_url "$DEST_EXPLORER" "$FUND_TX")"
echo "Origin LP position tx:             $(tx_url "$DEST_EXPLORER" "$RECORD_TX")"
echo "Origin Reactive request tx:        $(tx_url "$DEST_EXPLORER" "$ORIGIN_TX")"
echo "Lasna RVM tx:                      $(tx_url "$LASNA_EXPLORER" "$RVM_TX")"
echo "Destination callback tx:           $(tx_url "$DEST_EXPLORER" "$CALLBACK_TX")"
echo "Raw run log:                       $RUN_LOG"
