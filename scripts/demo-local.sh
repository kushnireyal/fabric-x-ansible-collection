#!/usr/bin/env bash
# demo-local.sh — spin up a local Fabric-X-EVM stack and run the USDC replay workload.
#
# Usage:
#   scripts/demo-local.sh --evm-repo PATH [--evm-branch BRANCH] \
#     [--warm] [--perf-sweep] [--skip-teardown] [--quiet] [--dry-run]
#
# Flags:
#   --evm-repo PATH      path to local fabric-x-evm repo checkout (required)
#   --evm-branch BRANCH  branch/ref to check out in EVM_REPO before running
#                        (default: use current checkout as-is)
#   --warm               skip Fabric-X network setup; reuse the running stack.
#                        Only restarts the EVM gateway if the image SHA changed.
#                        Implies --skip-teardown. Requires a prior run with --skip-teardown.
#   --perf-sweep         run all worker configurations (processingWorkers=[1,4,8] x
#                        submittingWorkers=[4,8,16,24]) and report a full results table.
#                        Takes ~12x longer than a single run.
#   --skip-teardown      leave the stack running after the test
#   --quiet              suppress intermediate output; print only section headers and final summary
#                        on failure the last 50 lines of the run log are printed to stderr
#   --dry-run            print commands without executing them

set -euo pipefail

# ─── defaults ────────────────────────────────────────────────────────────────
EVM_REPO=""
EVM_BRANCH=""
WARM=false
PERF_SWEEP=false
SKIP_TEARDOWN=false
QUIET=false
DRY_RUN=false

# ─── argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --evm-repo)      EVM_REPO="$2"; shift 2 ;;
        --evm-branch)    EVM_BRANCH="$2"; shift 2 ;;
        --warm)          WARM=true; SKIP_TEARDOWN=true; shift ;;
        --perf-sweep)    PERF_SWEEP=true; shift ;;
        --skip-teardown) SKIP_TEARDOWN=true; shift ;;
        --quiet)         QUIET=true; shift ;;
        --dry-run)       DRY_RUN=true; shift ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$EVM_REPO" ]]; then
    echo "error: --evm-repo is required" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLECTION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── quiet-mode setup ─────────────────────────────────────────────────────────
QUIET_LOG=""
if [[ "$QUIET" == true && "$DRY_RUN" != true ]]; then
    QUIET_LOG="$(mktemp /tmp/demo-local-quiet-$$.XXXXXX.log)"
    trap '
        exit_code=$?
        if [[ $exit_code -ne 0 ]]; then
            echo "=== Last 50 lines of run log ===" >&2
            tail -50 "$QUIET_LOG" >&2
        fi
        rm -f "$QUIET_LOG"
    ' EXIT
fi

# ─── helpers ──────────────────────────────────────────────────────────────────
section() {
    echo ""
    echo "=== $* ==="
}

# Verbose print: stdout in normal mode, quiet log in quiet mode.
vecho() {
    if [[ "$QUIET" == true && -n "$QUIET_LOG" ]]; then
        echo "$*" >> "$QUIET_LOG"
    else
        echo "$*"
    fi
}

run() {
    vecho "+ $*"
    if [[ "$DRY_RUN" != true ]]; then
        if [[ "$QUIET" == true && -n "$QUIET_LOG" ]]; then
            "$@" >> "$QUIET_LOG" 2>&1
        else
            "$@"
        fi
    fi
}

run_in_dir() {
    local dir="$1"; shift
    vecho "+ (cd $dir && $*)"
    if [[ "$DRY_RUN" != true ]]; then
        if [[ "$QUIET" == true && -n "$QUIET_LOG" ]]; then
            (cd "$dir" && "$@") >> "$QUIET_LOG" 2>&1
        else
            (cd "$dir" && "$@")
        fi
    fi
}

# ─── step 1: prerequisites ────────────────────────────────────────────────────
section "Checking prerequisites"

missing=()
for cmd in docker go; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
done
# Ansible may live in the collection's venv or on PATH.
if [[ ! -x "$COLLECTION_DIR/.venv/bin/ansible-playbook" ]] && ! command -v ansible-playbook &>/dev/null; then
    missing+=(ansible)
fi
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "error: missing required commands: ${missing[*]}" >&2
    exit 1
fi

if [[ "$(uname)" == "Darwin" ]] && [[ -z "${LOCAL_ANSIBLE_HOST:-}" ]]; then
    echo "error: LOCAL_ANSIBLE_HOST must be set on macOS (e.g. export LOCAL_ANSIBLE_HOST=host.docker.internal)" >&2
    exit 1
fi

if [[ ! -d "$EVM_REPO" ]]; then
    echo "error: --evm-repo path does not exist: $EVM_REPO" >&2
    exit 1
fi

# ─── step 2: teardown any existing stack ──────────────────────────────────────
if [[ "$WARM" != true ]]; then
    section "Tearing down any existing local stack"
    rm -f /tmp/usdc-replay-*.log 2>/dev/null || true
    run_in_dir "$COLLECTION_DIR" make teardown || true
    # Wipe all generated state — make setup regenerates this entirely.
    # Removing just pgdata is insufficient; stale CA state anywhere under out/
    # causes authentication failures when setup generates fresh crypto material.
    run rm -rf "${COLLECTION_DIR}/out"
fi

# ─── step 2.5: checkout requested EVM branch ─────────────────────────────────
if [[ -n "$EVM_BRANCH" ]]; then
    section "Checking out EVM branch: $EVM_BRANCH"
    run_in_dir "$EVM_REPO" git fetch origin
    run_in_dir "$EVM_REPO" git checkout "$EVM_BRANCH"
    run_in_dir "$EVM_REPO" git reset --hard "origin/$EVM_BRANCH"
fi

# ─── step 3: build EVM image if needed ───────────────────────────────────────
section "Building EVM image"
IMAGE_CHANGED=true
if [[ "$DRY_RUN" != true ]]; then
    EVM_SHA=$(git -C "$EVM_REPO" rev-parse --short HEAD)
    # Compare :dev digest to this SHA's digest to detect if a restart is needed.
    dev_id=$(docker inspect fabric-x-evm:dev --format '{{.Id}}' 2>/dev/null || echo "none")
    sha_id=$(docker inspect "fabric-x-evm:${EVM_SHA}" --format '{{.Id}}' 2>/dev/null || echo "")
    if [[ -n "$sha_id" && "$dev_id" == "$sha_id" ]]; then
        IMAGE_CHANGED=false
        vecho "fabric-x-evm:dev already at ${EVM_SHA}; skipping build and restart"
    else
        if [[ -z "$sha_id" ]]; then
            run_in_dir "$EVM_REPO" make build-image IMAGE_TAG="$EVM_SHA"
        else
            vecho "fabric-x-evm:${EVM_SHA} already built; skipping build"
        fi
        run docker tag "fabric-x-evm:${EVM_SHA}" fabric-x-evm:dev
    fi
else
    EVM_SHA="dryrun"
    run_in_dir "$EVM_REPO" make build-image IMAGE_TAG="$EVM_SHA"
    run docker tag "fabric-x-evm:${EVM_SHA}" fabric-x-evm:dev
fi

# ─── warm mode: verify stack health and restart gateway if image changed ──────
if [[ "$WARM" == true ]]; then
    section "Warm mode: checking stack health"
    GATEWAY_URL="http://localhost:8546"
    if [[ "$DRY_RUN" != true ]]; then
        response=$(curl -s --max-time 5 -X POST "$GATEWAY_URL" \
            -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null || true)
        if ! echo "$response" | grep -q '"result"'; then
            echo "error: stack is not running — run without --warm first (add --skip-teardown to leave it up)" >&2
            exit 1
        fi
        vecho "Stack healthy: $response"
    fi
    if [[ "$IMAGE_CHANGED" == true ]]; then
        section "Warm mode: restarting gateway (new image: ${EVM_SHA})"
        run_in_dir "$COLLECTION_DIR" env ANSIBLE_FORKS=2 DOCKER_TIMEOUT=300 \
            TARGET_HOSTS=evm_gateways make restart
    else
        vecho "Warm mode: gateway image unchanged (${EVM_SHA}); skipping restart"
    fi
fi

# ─── step 4: setup, start, init ───────────────────────────────────────────────
if [[ "$WARM" != true ]]; then
    section "Setting up local stack"
    run_in_dir "$COLLECTION_DIR" env ANSIBLE_FORKS=2 DOCKER_TIMEOUT=300 make setup
    run_in_dir "$COLLECTION_DIR" env ANSIBLE_FORKS=2 DOCKER_TIMEOUT=300 make start
    run_in_dir "$COLLECTION_DIR" env ANSIBLE_FORKS=2 DOCKER_TIMEOUT=300 make init
fi

# ─── step 5: wait for gateway health ─────────────────────────────────────────
section "Waiting for gateway health (timeout 60s)"
GATEWAY_URL="http://localhost:8546"
POLL_TIMEOUT=60
elapsed=0
while true; do
    response=$(curl -s --max-time 2 -X POST "$GATEWAY_URL" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null || true)
    if echo "$response" | grep -q '"result"'; then
        vecho "Gateway healthy: $response"
        break
    fi
    if [[ "$elapsed" -ge "$POLL_TIMEOUT" ]]; then
        echo "error: gateway did not become healthy within ${POLL_TIMEOUT}s" >&2
        exit 1
    fi
    sleep 2
    elapsed=$((elapsed + 2))
done

# ─── step 5.5: print Grafana links ───────────────────────────────────────────
section "Grafana dashboards (live during run)"
if [[ "$DRY_RUN" != true ]]; then
    GRAFANA_BASE="https://localhost:3000"
    START_MS=$(( $(date +%s) * 1000 ))
    echo "  Committer: ${GRAFANA_BASE}/d/UDdpyzz7zav2?from=${START_MS}&to=now&refresh=5s"
    echo "  Orderer:   ${GRAFANA_BASE}/dashboards"
fi

# ─── step 5.6: generate host-side fabx config for the test process ───────────
# NewFabricXTestHarnessWithFactory loads FABX_CONFIG_PATH to find orderers/committer.
# The container config uses /config/... paths and host.docker.internal hostnames.
# The test process runs on the macOS host, so it needs host-relative paths and
# localhost ports (Docker Desktop maps container ports to 127.0.0.1 on the host).
GATEWAY_CONFIG_DIR="${COLLECTION_DIR}/out/local-deployment/evm-gateway-local-1/config"
FABX_LOCAL_CONFIG="$(mktemp /tmp/fabx-local-$$.yaml)"
if [[ "$DRY_RUN" != true ]]; then
    cat > "$FABX_LOCAL_CONFIG" <<FABXCFG
network:
  protocol: fabric-x
  channel: arma
  namespace: evmns1
  ns-version: "1.0"
  chain-id: 4011

loadgen:
  # /metrics endpoint scraped by Prometheus (job evm_loadgen.test_process in
  # examples/inventory/local/fabric-x.yaml). Read by integration/perf TestMain.
  metrics-addr: "0.0.0.0:9092"

gateway:
  listen: "0.0.0.0:8546"
  worker-count: 4
  sync-timeout: 5m

  identity:
    msp-id: Org1MSP
    msp-dir: ${GATEWAY_CONFIG_DIR}/users/User1@org1.example.com/msp

  database:
    connection-string: "file:/tmp/fabx-local-test-gateway-$$.db"
    trie-path: ""

  orderers:
    - endpoint: { host: ${LOCAL_ANSIBLE_HOST}, port: 7050 }
      tls:
        mode: mtls
        cert-path: ${GATEWAY_CONFIG_DIR}/tls/client.crt
        key-path: ${GATEWAY_CONFIG_DIR}/tls/client.key
        ca-cert-paths:
          - ${GATEWAY_CONFIG_DIR}/tls/orderer/orderer-router-1/ca.crt
    - endpoint: { host: ${LOCAL_ANSIBLE_HOST}, port: 7150 }
      tls:
        mode: mtls
        cert-path: ${GATEWAY_CONFIG_DIR}/tls/client.crt
        key-path: ${GATEWAY_CONFIG_DIR}/tls/client.key
        ca-cert-paths:
          - ${GATEWAY_CONFIG_DIR}/tls/orderer/orderer-router-2/ca.crt
    - endpoint: { host: ${LOCAL_ANSIBLE_HOST}, port: 7250 }
      tls:
        mode: mtls
        cert-path: ${GATEWAY_CONFIG_DIR}/tls/client.crt
        key-path: ${GATEWAY_CONFIG_DIR}/tls/client.key
        ca-cert-paths:
          - ${GATEWAY_CONFIG_DIR}/tls/orderer/orderer-router-3/ca.crt
    - endpoint: { host: ${LOCAL_ANSIBLE_HOST}, port: 7350 }
      tls:
        mode: mtls
        cert-path: ${GATEWAY_CONFIG_DIR}/tls/client.crt
        key-path: ${GATEWAY_CONFIG_DIR}/tls/client.key
        ca-cert-paths:
          - ${GATEWAY_CONFIG_DIR}/tls/orderer/orderer-router-4/ca.crt

  committer:
    endpoint: { host: ${LOCAL_ANSIBLE_HOST}, port: 5130 }
    tls:
      mode: mtls
      cert-path: ${GATEWAY_CONFIG_DIR}/tls/client.crt
      key-path: ${GATEWAY_CONFIG_DIR}/tls/client.key
      ca-cert-paths:
        - ${GATEWAY_CONFIG_DIR}/tls/sidecar/ca.crt

endorsers:
  - name: Org1
    identity:
      msp-id: Org1MSP
      msp-dir: ${GATEWAY_CONFIG_DIR}/peers/evm-gateway-local-1.org1.example.com/msp
    committer:
      endpoint: { host: ${LOCAL_ANSIBLE_HOST}, port: 5130 }
      tls:
        mode: mtls
        cert-path: ${GATEWAY_CONFIG_DIR}/tls/client.crt
        key-path: ${GATEWAY_CONFIG_DIR}/tls/client.key
        ca-cert-paths:
          - ${GATEWAY_CONFIG_DIR}/tls/sidecar/ca.crt
    database:
      database: sqlite
      connection-string: "file:/tmp/fabx-local-test-endorser-$$.db"
FABXCFG
    vecho "Generated test config: $FABX_LOCAL_CONFIG"
    trap "rm -f '$FABX_LOCAL_CONFIG' /tmp/fabx-local-test-gateway-$$.db /tmp/fabx-local-test-endorser-$$.db" EXIT
fi

# ─── step 6: run USDC workload ────────────────────────────────────────────────
if [[ "$PERF_SWEEP" == true ]]; then
    section "Running USDC workload — performance sweep (all worker configurations)"
    TEST_NAME='^TestReplayJSONDatasetPerformance$'
else
    section "Running USDC workload"
    TEST_NAME='^TestReplayJSONDataset$'
fi
WORKLOAD_LOG="$(mktemp /tmp/usdc-replay-$$.XXXXXX.log)"

# Strip the "    file.go:N: " prefix that go test -v adds to t.Logf output.
# Use awk (with fflush) instead of sed to avoid block-buffering in the pipe;
# sed buffers up to 4 KB which hides progress lines for ~80 s at 2 s intervals.
STRIP_AWK='{sub(/^[[:space:]]*[A-Za-z_][^[:space:]]*:[0-9][0-9]*: /, ""); print; fflush()}'
if [[ "$DRY_RUN" == true ]]; then
    echo "+ (cd $EVM_REPO && FABX_CONFIG_PATH=<generated> go test -v -count=1 -run '$TEST_NAME' -timeout 0 ./integration/perf/)"
elif [[ "$QUIET" == true ]]; then
    # Capture full output to workload log and quiet log; stream progress lines to stdout.
    (cd "$EVM_REPO" && FABX_CONFIG_PATH="$FABX_LOCAL_CONFIG" go test -v -count=1 -run "$TEST_NAME" \
        -timeout 0 ./integration/perf/) \
        2>&1 | awk "$STRIP_AWK" | tee -a "$QUIET_LOG" | tee "$WORKLOAD_LOG" | awk '/Progress: /{print; fflush()}'
else
    (cd "$EVM_REPO" && FABX_CONFIG_PATH="$FABX_LOCAL_CONFIG" go test -v -count=1 -run "$TEST_NAME" \
        -timeout 0 ./integration/perf/) \
        2>&1 | awk "$STRIP_AWK" | tee "$WORKLOAD_LOG"
fi

# ─── step 7: parse and print summary ─────────────────────────────────────────
section "Summary"
if [[ "$DRY_RUN" != true ]]; then
    if [[ "$PERF_SWEEP" == true ]]; then
        echo ""
        printf "%-4s %-4s %-15s %-12s %-10s\n" "PW" "SW" "Throughput" "Failures" "Fail%"
        printf "%-4s %-4s %-15s %-12s %-10s\n" "----" "----" "----------" "--------" "-----"
        while IFS= read -r line; do
            pw=$(echo "$line"  | grep -oE 'pw=[0-9]+'              | cut -d= -f2)
            sw=$(echo "$line"  | grep -oE 'sw=[0-9]+'              | cut -d= -f2)
            tps=$(echo "$line" | grep -oE 'throughput=[0-9.]+' | cut -d= -f2)
            fail=$(echo "$line"| grep -oE 'failed=[0-9]+'          | head -1 | cut -d= -f2)
            tot=$(echo "$line" | grep -oE 'total=[0-9]+'           | cut -d= -f2)
            if [[ -n "$tot" && "$tot" -gt 0 ]]; then
                failpct=$(awk "BEGIN{printf \"%.2f\", (${fail:-0}*100)/${tot}}")
            else
                failpct="n/a"
            fi
            printf "%-4s %-4s %-15s %-12s %-10s\n" "$pw" "$sw" "${tps} tx/s" "${fail:-0}/${tot:-?}" "${failpct}%"
        done < <(grep -oE 'PerfResult: pw=[0-9]+ sw=[0-9]+ throughput=[0-9.]+ failed=[0-9]+ total=[0-9]+' \
            "$WORKLOAD_LOG" 2>/dev/null || true)
    else
        config=$(grep -oE 'Config: processingWorkers=[0-9]+ submittingWorkers=[0-9]+' "$WORKLOAD_LOG" \
            | tail -1 | sed 's/Config: //' || true)
        final=$(grep "Replay complete:" "$WORKLOAD_LOG" | tail -1 || true)

        success=$(echo "$final" | grep -oE '[0-9]+ successful' | grep -oE '[0-9]+' || echo 0)
        failed=$(echo "$final"  | grep -oE '[0-9]+ failed'     | grep -oE '[0-9]+' || echo 0)
        skipped=$(echo "$final" | grep -oE '[0-9]+ skipped'    | grep -oE '[0-9]+' || echo 0)
        total=$(( success + failed + skipped ))

        # Last reported overall throughput (cumulative at end of run).
        # Progress lines (every 2s) use "NNN.NN tx/s (overall)"; fall back to the
        # final "Result: Throughput=NNN.NN tx/s" line when all txs complete within
        # a single 2s tick and no progress lines are emitted (e.g. fast queue impls).
        overall_tps=$(grep -oE '[0-9]+\.[0-9]+ tx/s \(overall\)' "$WORKLOAD_LOG" \
            | grep -oE '^[0-9]+\.[0-9]+' | tail -1 || true)
        if [[ -z "$overall_tps" ]]; then
            overall_tps=$(grep -oE 'Throughput=[0-9]+\.[0-9]+ tx/s' "$WORKLOAD_LOG" \
                | grep -oE '[0-9]+\.[0-9]+' | tail -1 || echo "0.00")
        fi
        # Highest recent (windowed) throughput seen during the run;
        # falls back to overall when no windowed samples exist.
        peak_tps=$(grep -oE '[0-9]+\.[0-9]+ tx/s \(recent\)' "$WORKLOAD_LOG" \
            | grep -oE '^[0-9]+\.[0-9]+' | sort -n | tail -1 || true)
        if [[ -z "$peak_tps" ]]; then
            peak_tps="$overall_tps"
        fi

        if [[ "$total" -gt 0 ]]; then
            success_rate=$(( success * 100 / total ))
        else
            success_rate=0
        fi

        stability=$(grep -oE 'TPS stability \([0-9]+ samples\).*' "$WORKLOAD_LOG" | tail -1 || true)

        [[ -n "$config" ]] && echo "Config:        $config"
        echo "Transactions:  ${success} successful, ${failed} failed, ${skipped} skipped"
        echo "Peak TPS:      ${peak_tps} tx/s"
        echo "Overall TPS:   ${overall_tps} tx/s"
        echo "Success rate:  ${success_rate}%"
        [[ -n "$stability" ]] && echo "$stability"
    fi
fi

# ─── step 8: teardown ─────────────────────────────────────────────────────────
if [[ "$SKIP_TEARDOWN" != true ]]; then
    section "Tearing down local stack"
    rm -f /tmp/usdc-replay-*.log 2>/dev/null || true
    run_in_dir "$COLLECTION_DIR" make teardown
fi

# ─── step 9: exit code ────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == true ]]; then
    echo ""
    echo "(dry-run complete)"
    exit 0
fi

if [[ "$PERF_SWEEP" == true ]]; then
    echo ""
    echo "Performance sweep complete."
    exit 0
fi

if [[ "${success_rate:-0}" -lt 95 ]]; then
    echo "error: success rate ${success_rate:-0}% is below the 95% threshold" >&2
    exit 1
fi

echo ""
echo "Demo passed (success rate ${success_rate}%)."
