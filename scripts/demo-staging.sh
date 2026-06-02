#!/usr/bin/env bash
# demo-staging.sh — run the USDC ERC-20 replay workload across the 3 staging EVM
# gateway replicas (dectrust5–7) and report per-replica and aggregate TPS.
#
# Must be run from dectrust8.vpc.cloud9.ibm.com (the staging control node).
# SSH keys must allow passwordless access to dectrust5–7 from this host.
#
# Usage:
#   scripts/demo-staging.sh [--evm-branch BRANCH] [--skip-deploy] [--skip-teardown] \
#     [--wrap-count N] [--perf-sweep] [--dry-run]
#
# Flags:
#   --evm-branch BRANCH  fabric-x-evm branch/ref to deploy and run (default: main)
#   --skip-deploy    assume gateways are already running; skip deploy-evm-staging.sh
#   --skip-teardown  leave evm-gateway containers running after the test
#   --wrap-count N   replay the dataset window N times for stability measurement (default: 1)
#   --perf-sweep     run all worker configurations (processingWorkers=[1,4,8] x
#                    submittingWorkers=[4,8,16,24]) and report a full results table.
#                    Takes ~12x longer than a single run.
#   --quiet          suppress intermediate output; print only section headers and final summary
#                    on failure the last 50 lines of the run log are printed to stderr
#   --dry-run        print commands without executing them
#
# Exit codes:
#   0 — success rate >= 95% across all replicas
#   1 — success rate below threshold, or any step failed

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
HOSTS=(
  dectrust5.vpc.cloud9.ibm.com
  dectrust6.vpc.cloud9.ibm.com
  dectrust7.vpc.cloud9.ibm.com
)
EVM_DIR=/data/fabric-x-evm
TESTDATA_DIR=${EVM_DIR}/integration/perf/testdata
RPC_PORT=8545
HEALTH_POLL_TIMEOUT=60

# ---------------------------------------------------------------------------
# Defaults
EVM_BRANCH="main"
SKIP_DEPLOY=false
SKIP_TEARDOWN=false
DRY_RUN=false
QUIET=false
WRAP_COUNT=1
PERF_SWEEP=false
SUBMITTING_WORKERS=8
PROCESSING_WORKERS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --evm-branch)          EVM_BRANCH="$2"; shift 2 ;;
    --skip-evm-deploy)         SKIP_DEPLOY=true; shift ;;
    --skip-evm-teardown)       SKIP_TEARDOWN=true; shift ;;
    --wrap-count)          WRAP_COUNT="$2"; shift 2 ;;
    --perf-sweep)          PERF_SWEEP=true; shift ;;
    --submitting-workers)  SUBMITTING_WORKERS="$2"; shift 2 ;;
    --processing-workers)  PROCESSING_WORKERS="$2"; shift 2 ;;
    --quiet)               QUIET=true; shift ;;
    --dry-run)             DRY_RUN=true; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAIT_TIMEOUT=3600  # upper bound for the dectrust8 wait loop; go test itself runs with -timeout 0
[[ "$PERF_SWEEP" == true ]] && RUN_TEST=TestReplayJSONDatasetPerformance || RUN_TEST=TestReplayJSONDataset

# ---------------------------------------------------------------------------
log()     { echo "[$(date +'%H:%M:%S')] $*"; }
section() { echo; echo "=== $* ==="; }

# ─── quiet-mode setup ────────────────────────────────────────────────────────
QUIET_LOG=""
if [[ "$QUIET" == true && "$DRY_RUN" != true ]]; then
  QUIET_LOG="$(mktemp /tmp/demo-staging-quiet-$$.XXXXXX.log)"
  trap '
    exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
      echo "=== Last 50 lines of run log ===" >&2
      tail -50 "$QUIET_LOG" >&2
    fi
    rm -f "$QUIET_LOG"
  ' EXIT
fi

# vlog: verbose log — goes to quiet log in quiet mode, stdout otherwise.
vlog() {
  if [[ "$QUIET" == true && -n "$QUIET_LOG" ]]; then
    echo "[$(date +'%H:%M:%S')] $*" >> "$QUIET_LOG"
  else
    log "$@"
  fi
}

# vrun: run a command routing its output to quiet log in quiet mode.
vrun() {
  if [[ "$QUIET" == true && -n "$QUIET_LOG" ]]; then
    "$@" >> "$QUIET_LOG" 2>&1
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
section "STEP 0: Preflight — SSH connectivity and testdata presence"

for i in "${!HOSTS[@]}"; do
  host="${HOSTS[$i]}"

  if [[ "$DRY_RUN" != true ]]; then
    ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" true 2>/dev/null \
      || { log "ERROR: Cannot SSH to $host — check key authentication"; exit 1; }
    vlog "SSH OK: $host"

    # These files are NOT in the git repo; they must be generated on each VM.
    # See 'Generating testdata on staging VMs' in integration/perf/USDC_deployment.md.
    missing=()
    for f in \
      "${TESTDATA_DIR}/USDC_dataset.json.gz" \
      "${TESTDATA_DIR}/USDC_contract.json" \
      "${EVM_DIR}/integration/contracts/USDC_fiattokenv2_2.gen.go"
    do
      ssh "$host" "[ -f '$f' ]" 2>/dev/null || missing+=("$f")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
      log "ERROR: Missing required files on ${host}:"
      for f in "${missing[@]}"; do log "  $f"; done
      log ""
      log "  These files are excluded from the git repo and must be generated on each VM."
      log "  See 'Generating testdata on staging VMs' in integration/perf/USDC_deployment.md."
      exit 1
    fi
    vlog "Testdata OK: $host"

    # Verify the FABX_CONFIG_PATH config generated by deploy-evm-staging.sh.
    # Required when --skip-deploy is used; generated by STEP 1 otherwise.
    n=$((i + 1))
    test_cfg="/data/fabric-x-evm-test-config-${n}.yaml"
    if ! ssh "$host" "[ -f '$test_cfg' ]" 2>/dev/null; then
      if [[ "$SKIP_DEPLOY" == true ]]; then
        log "ERROR: Test config missing on ${host}: ${test_cfg}"
        log "  Run deploy-evm-staging.sh first (or omit --skip-deploy)"
        exit 1
      else
        vlog "Test config not yet present on ${host} (will be generated during deployment)"
      fi
    else
      vlog "Test config OK: $host"
    fi
  else
    echo "+ [check SSH + testdata on $host]"
  fi
done

# ---------------------------------------------------------------------------
section "STEP 1: Deploy EVM gateways"

if [[ "$SKIP_DEPLOY" == true ]]; then
  vlog "Skipping deployment (--skip-deploy)"
else
  echo "+ bash $SCRIPT_DIR/deploy-evm-staging.sh --evm-branch $EVM_BRANCH"
  [[ "$DRY_RUN" != true ]] && vrun bash "$SCRIPT_DIR/deploy-evm-staging.sh" --evm-branch "$EVM_BRANCH"
fi

# ---------------------------------------------------------------------------
section "STEP 2: Wait for gateway health checks (timeout ${HEALTH_POLL_TIMEOUT}s)"

for host in "${HOSTS[@]}"; do
  if [[ "$DRY_RUN" == true ]]; then
    echo "+ [poll http://$host:$RPC_PORT until eth_blockNumber responds]"; continue
  fi
  elapsed=0
  while true; do
    result=$(curl -sf --max-time 2 -X POST "http://${host}:${RPC_PORT}" \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null || true)
    if echo "$result" | grep -q '"result"'; then
      vlog "$host healthy: $result"
      break
    fi
    if [[ "$elapsed" -ge "$HEALTH_POLL_TIMEOUT" ]]; then
      log "ERROR: $host did not respond within ${HEALTH_POLL_TIMEOUT}s"
      [[ "$SKIP_DEPLOY" == true ]] && log "  (hint: --skip-deploy requires gateways to be running; omit it or add --skip-teardown to the prior run)"
      exit 1
    fi
    sleep 2; elapsed=$((elapsed + 2))
  done
done

# ---------------------------------------------------------------------------
# Record block height from each deployed gateway container before the workload.
# After the workload we compare: a zero delta means the test wasn't hitting Fabric-X.
declare -A block_before
if [[ "$DRY_RUN" != true ]]; then
  for host in "${HOSTS[@]}"; do
    h=$(curl -sf --max-time 5 -X POST "http://${host}:${RPC_PORT}" \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null || true)
    hex=$(echo "$h" | grep -oE '"result":"0x[0-9a-fA-F]+"' | grep -oE '0x[0-9a-fA-F]+' || echo "0x0")
    block_before[$host]=$(printf '%d' "$hex" 2>/dev/null || echo 0)
    vlog "Block height before workload on $host: ${block_before[$host]}"
  done
fi

# ---------------------------------------------------------------------------
section "Grafana dashboards (live during run)"
if [[ "$DRY_RUN" != true ]]; then
  GRAFANA_BASE="https://10.0.0.6:3000"
  START_MS=$(( $(date +%s) * 1000 ))
  echo "  Committer: ${GRAFANA_BASE}/d/UDdpyzz7zav2?from=${START_MS}&to=now&refresh=5s"
  echo "  Orderer:   ${GRAFANA_BASE}/dashboards"
fi

# ---------------------------------------------------------------------------
section "STEP 3: Launch workload on each replica in parallel"

launched_hosts=()
launched_pids=()

# Phase 3a: sync EVM repos in parallel so all replicas start at the same time.
# git fetch origin can be slow (fetching from GitHub over IBM Cloud); running
# them sequentially means replicas start minutes apart.
if [[ "$DRY_RUN" != true ]]; then
  sync_tmpdir=$(mktemp -d)
  sync_bgpids=()
  for i in "${!HOSTS[@]}"; do
    host="${HOSTS[$i]}"
    n=$((i + 1))
    if [[ "$QUIET" == true && -n "$QUIET_LOG" ]]; then
      (ssh "$host" "
        cd ${EVM_DIR}
        git fetch origin 2>&1
        git checkout ${EVM_BRANCH} 2>&1
        git reset --hard origin/${EVM_BRANCH} 2>&1
      " >> "$QUIET_LOG" 2>&1 || log "WARNING: could not sync EVM repo on $host") &
    else
      (ssh "$host" "
        cd ${EVM_DIR}
        git fetch origin 2>&1
        git checkout ${EVM_BRANCH} 2>&1
        git reset --hard origin/${EVM_BRANCH} 2>&1
      " 2>&1 | sed "s/^/[sync:${host}] /" || log "WARNING: could not sync EVM repo on $host") &
    fi
    sync_bgpids+=($!)
  done
  log "Waiting for git syncs to complete on all replicas..."
  for pid in "${sync_bgpids[@]}"; do wait "$pid" || true; done
  log "All replicas synced."
  rm -rf "$sync_tmpdir"
fi

# Phase 3b: launch all test processes at (nearly) the same time.
for i in "${!HOSTS[@]}"; do
  host="${HOSTS[$i]}"
  n=$((i + 1))
  remote_log="/tmp/perf-replica-${n}.log"

  echo "+ ssh $host 'nohup PERF_LOOP_MODE=${PERF_LOOP_MODE:-closed} PERF_FOREVER=${PERF_FOREVER:-0} PERF_DURATION=${PERF_DURATION:-} PERF_REPLAY_WRAP_COUNT=${WRAP_COUNT} PERF_SUBMITTING_WORKERS=${SUBMITTING_WORKERS} PERF_PROCESSING_WORKERS=${PROCESSING_WORKERS} go test -v -tags perf -run ^${RUN_TEST}\$ -timeout 0 ./integration/perf/ > $remote_log 2>&1 &'"
  if [[ "$DRY_RUN" != true ]]; then
    # >/dev/null 2>&1 at the nohup level detaches bash-c from the SSH channel's
    # stdout fd. Without it, the SSH channel stays open until the go test finishes
    # (bash-c inherits the channel fd), blocking this pid=$(...) for the test duration.
    # go test output is still captured via the inner redirect > ${remote_log} 2>&1.
    pid=$(ssh "$host" "nohup bash -c 'cd ${EVM_DIR} && PERF_LOOP_MODE=${PERF_LOOP_MODE:-closed} PERF_FOREVER=${PERF_FOREVER:-0} PERF_DURATION=${PERF_DURATION:-} PERF_REPLAY_WRAP_COUNT=${WRAP_COUNT} PERF_SUBMITTING_WORKERS=${SUBMITTING_WORKERS} PERF_PROCESSING_WORKERS=${PROCESSING_WORKERS} FABX_CONFIG_PATH=/data/fabric-x-evm-test-config-${n}.yaml go test -v -count=1 -tags perf \
      -run ^${RUN_TEST}\$ -timeout 0 \
      ./integration/perf/ > ${remote_log} 2>&1' >/dev/null 2>&1 & echo \$!")
    launched_hosts+=("$host")
    launched_pids+=("$pid")
    vlog "Replica $n launched on $host (PID $pid) → $remote_log"
  fi
done

# ---------------------------------------------------------------------------
section "STEP 4: Wait for workload completion (up to ${WAIT_TIMEOUT}s)"

if [[ "$DRY_RUN" != true ]]; then
  elapsed=0
  next_progress=10  # print progress every 10 seconds
  while [[ "$elapsed" -lt "$WAIT_TIMEOUT" ]]; do
    all_done=true
    for i in "${!launched_hosts[@]}"; do
      if ssh "${launched_hosts[$i]}" "kill -0 ${launched_pids[$i]} 2>/dev/null"; then
        all_done=false
      fi
    done
    if $all_done; then
      vlog "All replicas finished after ${elapsed}s"
      break
    fi
    sleep 5; elapsed=$((elapsed + 5))
    vlog "Waiting... ${elapsed}s / ${WAIT_TIMEOUT}s"

    # Print progress and block heights every 10 seconds.
    if [[ "$elapsed" -ge "$next_progress" ]]; then
      for i in "${!launched_hosts[@]}"; do
        n=$((i + 1))
        host="${launched_hosts[$i]}"
        progress=$(ssh "$host" \
          "grep -oE 'Progress: .*' /tmp/perf-replica-${n}.log 2>/dev/null | tail -1" 2>/dev/null || true)
        [[ -n "$progress" ]] && echo "[replica $n] $progress"
        h=$(curl -sf --max-time 2 -X POST "http://${host}:${RPC_PORT}" \
          -H "Content-Type: application/json" \
          -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null || true)
        hex=$(echo "$h" | grep -oE '"result":"0x[0-9a-fA-F]+"' | grep -oE '0x[0-9a-fA-F]+' || echo "0x0")
        block_now=$(printf '%d' "$hex" 2>/dev/null || echo 0)
        echo "[replica $n] namespace blocks: $((block_now - ${block_before[$host]:-0})) (height $block_now)"
      done
      next_progress=$((next_progress + 10))
    fi
  done
fi

# ---------------------------------------------------------------------------
# Block-height + receipt-status check: verify real Fabric-X activity AND correct EVM execution.
#
# Two levels of proof:
#   1. Block-height delta > 0  → transactions were committed to the real Fabric-X blockchain
#   2. Receipt status = 0x1    → EVM execution actually succeeded (not just committed with revert)
#
# If status = 0x0 despite being committed, the most likely cause is the blockNumber=0 bug in
# endorser/versioned_db_wrapper.go (NewSnapshot(0) reads empty state → USDC transfers revert).
# Fix: rebase on main (commit 605e744) so NewSnapshot(0) resolves to the latest committed block.
if [[ "$DRY_RUN" != true ]]; then
  echo
  echo "Fabric-X verification (block-height delta + receipt status):"
  fabric_x_active=true
  evm_success=true
  for host in "${HOSTS[@]}"; do
    # --- block-height delta ---
    h=$(curl -sf --max-time 5 -X POST "http://${host}:${RPC_PORT}" \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null || true)
    hex=$(echo "$h" | grep -oE '"result":"0x[0-9a-fA-F]+"' | grep -oE '0x[0-9a-fA-F]+' || echo "0x0")
    block_after=$(printf '%d' "$hex" 2>/dev/null || echo 0)
    before=${block_before[$host]:-0}
    delta=$((block_after - before))
    if [[ "$delta" -eq 0 ]]; then
      fabric_x_active=false
    fi

    # --- sample receipt status from the last committed block ---
    # Get the latest block with transactions; check up to 5 tx receipts.
    receipt_ok=0; receipt_fail=0; receipt_checked=0
    for blk_dec in $(seq "$block_after" -1 "$((block_after > 5 ? block_after - 5 : 1))"); do
      blk_hex=$(printf '0x%x' "$blk_dec")
      blk_resp=$(curl -sf --max-time 3 -X POST "http://${host}:${RPC_PORT}" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"${blk_hex}\",false],\"id\":1}" 2>/dev/null || true)
      tx_hashes=$(echo "$blk_resp" | grep -oE '"0x[0-9a-fA-F]{64}"' | tr -d '"' | head -5)
      for txhash in $tx_hashes; do
        rec=$(curl -sf --max-time 3 -X POST "http://${host}:${RPC_PORT}" \
          -H "Content-Type: application/json" \
          -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionReceipt\",\"params\":[\"${txhash}\"],\"id\":1}" 2>/dev/null || true)
        status_val=$(echo "$rec" | grep -oE '"status":"0x[01]"' | grep -oE '0x[01]' || echo "")
        if [[ "$status_val" == "0x1" ]]; then
          receipt_ok=$((receipt_ok + 1))
        elif [[ "$status_val" == "0x0" ]]; then
          receipt_fail=$((receipt_fail + 1))
          evm_success=false
        fi
        receipt_checked=$((receipt_checked + 1))
        [[ "$receipt_checked" -ge 5 ]] && break 2
      done
    done

    printf "  %-38s blocks: before=%-6d after=%-6d delta=%-5d  receipts: ok=%d fail=%d\n" \
      "$host" "$before" "$block_after" "$delta" "$receipt_ok" "$receipt_fail"
  done

  if [[ "$fabric_x_active" == false ]]; then
    echo "  WARNING: one or more replicas show zero block-height delta"
    echo "           → test may not be using the real Fabric-X backend"
    echo "           Check that FABX_CONFIG_PATH is set and points to a valid staging config"
  fi
  if [[ "$evm_success" == false ]]; then
    echo "  WARNING: one or more sampled receipts have status=0x0 (EVM execution failed)"
    echo "           → transactions were committed to Fabric-X but EVM transfers reverted"
    echo "           Most likely cause: endorser/versioned_db_wrapper.go NewSnapshot(0) bug"
    echo "           Fix: rebase fabric-x-evm on main (commit 605e744)"
  fi
  if [[ "$fabric_x_active" == true && "$evm_success" == true ]]; then
    echo "  OK: blocks advanced and sampled receipts all show status=0x1 (EVM execution succeeded)"
  fi
fi

# ---------------------------------------------------------------------------
section "STEP 5: Collect logs from replicas"

for i in "${!HOSTS[@]}"; do
  host="${HOSTS[$i]}"
  n=$((i + 1))
  local_log="/tmp/perf-staging-replica-${n}.log"

  if [[ "$QUIET" != true ]]; then
    echo "+ scp $host:/tmp/perf-replica-${n}.log $local_log"
  fi
  if [[ "$DRY_RUN" != true ]]; then
    rm -f "$local_log"
    scp -q "$host:/tmp/perf-replica-${n}.log" "$local_log" \
      || log "WARNING: Could not fetch log from $host — results may be incomplete"
  fi
done

# ---------------------------------------------------------------------------
section "STEP 6: Results"

if [[ "$DRY_RUN" != true ]]; then
  if [[ "$PERF_SWEEP" == true ]]; then
    # ── Perf-sweep: per-config table across all replicas ──────────────────
    printf "\n%-4s %-4s" "PW" "SW"
    for i in "${!HOSTS[@]}"; do
      printf " %-18s" "Replica $((i+1)) TPS"
    done
    printf " %-14s\n" "Aggregate"
    printf "%-4s %-4s" "----" "----"
    for i in "${!HOSTS[@]}"; do
      printf " %-18s" "------------------"
    done
    printf " %-14s\n" "--------------"

    for pw in 1 4 8; do
      for sw in 4 8 16 24; do
        printf "%-4s %-4s" "$pw" "$sw"
        agg_tps=0
        for i in "${!HOSTS[@]}"; do
          n=$((i + 1))
          rlog="/tmp/perf-staging-replica-${n}.log"
          tps=$(grep -oE "PerfResult: pw=${pw} sw=${sw} throughput=[0-9]+\.[0-9]+" "$rlog" 2>/dev/null \
            | grep -oE 'throughput=[0-9]+\.[0-9]+' | cut -d= -f2 | tail -1 || echo "0.00")
          printf " %-18s" "${tps} tx/s"
          agg_tps=$(awk "BEGIN { printf \"%d\", $agg_tps + $tps }")
        done
        printf " ~%-13s\n" "${agg_tps} tx/s"
      done
    done

    echo
    echo "────────────────────────────────────────────────────────────────────────────"
    echo "Performance sweep complete across ${#HOSTS[@]} replicas."
    echo "────────────────────────────────────────────────────────────────────────────"
  else
    # ── Regular run: per-replica table ────────────────────────────────────
    aggregate_tps=0
    total_success=0
    total_failed=0

    config=$(grep -oE 'Config: processingWorkers=[0-9]+ submittingWorkers=[0-9]+' \
      "/tmp/perf-staging-replica-1.log" 2>/dev/null | tail -1 | sed 's/Config: //' || true)
    [[ -n "$config" ]] && echo "Config: $config"

    printf "\n%-10s %-35s %-12s %-10s %-15s\n" \
      "Replica" "Host" "Successful" "Failed" "TPS (overall)"
    printf "%-10s %-35s %-12s %-10s %-15s\n" \
      "-------" "----" "----------" "------" "-------------"

    for i in "${!HOSTS[@]}"; do
      host="${HOSTS[$i]}"
      n=$((i + 1))
      local_log="/tmp/perf-staging-replica-${n}.log"

      replay_line=$(grep "Replay complete:" "$local_log" 2>/dev/null | tail -1 || true)
      success=$(echo "$replay_line" | grep -oE '[0-9]+ successful' | grep -oE '[0-9]+' || echo 0)
      failed=$(echo "$replay_line"  | grep -oE '[0-9]+ failed'    | grep -oE '[0-9]+' || echo 0)

      peak_tps=$(grep -oE '[0-9]+\.[0-9]+ tx/s \(overall\)' "$local_log" 2>/dev/null \
        | grep -oE '^[0-9]+\.[0-9]+' | sort -n | tail -1 || echo "0.00")

      stability=$(grep -oE 'TPS stability \([0-9]+ samples\).*' "$local_log" 2>/dev/null \
        | tail -1 || true)

      printf "%-10s %-35s %-12s %-10s %-15s\n" \
        "$n" "$host" "${success:-0}" "${failed:-0}" "$peak_tps"
      if [[ -n "$stability" ]]; then
        printf "           %s\n" "$stability"
      fi

      total_success=$((total_success + ${success:-0}))
      total_failed=$((total_failed  + ${failed:-0}))
      aggregate_tps=$(awk "BEGIN { printf \"%d\", $aggregate_tps + $peak_tps }")
    done

    echo
    echo "────────────────────────────────────────────────────────────────────────────"
    echo "Aggregate TPS : ~${aggregate_tps} tx/s across ${#HOSTS[@]} replicas"
    echo "Total         : ${total_success} successful, ${total_failed} failed"
    echo "────────────────────────────────────────────────────────────────────────────"
  fi
fi

# ---------------------------------------------------------------------------
section "STEP 7: Teardown"

if [[ "$SKIP_TEARDOWN" == true ]]; then
  vlog "Skipping teardown (--skip-teardown)"
else
  for host in "${HOSTS[@]}"; do
    if [[ "$QUIET" != true ]]; then
      echo "+ ssh $host 'docker rm -f evm-gateway'"
    fi
    [[ "$DRY_RUN" != true ]] && \
      vrun ssh "$host" "docker rm -f evm-gateway 2>/dev/null && echo 'stopped on $host' || true"
  done
fi

# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
  echo; echo "(dry-run complete)"; exit 0
fi

if [[ "$PERF_SWEEP" == true ]]; then
  echo
  echo "Performance sweep complete."
  exit 0
fi

echo
total=$((total_success + total_failed))
if [[ "$total" -gt 0 ]]; then
  success_rate=$(( total_success * 100 / total ))
else
  success_rate=0
fi

if [[ "$success_rate" -lt 95 ]]; then
  log "FAIL: success rate ${success_rate}% is below the 95% threshold"
  exit 1
fi

echo "Demo passed: ~${aggregate_tps} tx/s aggregate, ${success_rate}% success rate."
