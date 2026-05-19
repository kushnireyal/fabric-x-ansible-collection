#!/bin/bash
# EVM Gateway Staging Deployment
#
# Prerequisites:
#   - Must be run ON dectrust8.vpc.cloud9.ibm.com (the staging jump host)
#   - Passwordless SSH access from dectrust8 to dectrust4, dectrust5, dectrust6, dectrust7
#   - Fabric-X network (orderers dectrust1–4, committer-sidecar on dectrust4,
#     coordinator/query-service on dectrust6) already running
#   - Docker 20+ and Go 1.21+ on dectrust5–7
#   - Internet access from dectrust5–7 to clone github.com/hyperledger/fabric-x-evm
#
# Usage:  bash scripts/deploy-evm-staging.sh [--evm-branch BRANCH]
#   --evm-branch BRANCH  fabric-x-evm branch/ref to build and deploy (default: main)
# Result: EVM gateways on dectrust5:8545 (evmns1), dectrust6:8545 (evmns2),
#         dectrust7:8545 (evmns3) with namespaces created on channel arma.
set -euo pipefail

# ---------------------------------------------------------------------------
EVM_BRANCH="main"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --evm-branch) EVM_BRANCH="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
HOSTS=(dectrust5 dectrust6 dectrust7)
NAMESPACES=(evmns1 evmns2 evmns3)

CHANNEL=arma
MSP_ID=Org1MSP
ORDERER_PORT=7050
COMMITTER_HOST=dectrust4.vpc.cloud9.ibm.com
COMMITTER_PORT=5130
QUERY_HOST=dectrust4.vpc.cloud9.ibm.com
QUERY_PORT=5140
CHAIN_ID=4011

# Local paths on dectrust8 (this host).
STAGING_DIR=/data/staging-deployment
TLS_DIR=${STAGING_DIR}/committer-sidecar/config/tls
MSP_DIR=${STAGING_DIR}/committer-sidecar/config/msp
TLS_CERT=${TLS_DIR}/server.crt
TLS_KEY=${TLS_DIR}/server.key
TLS_CA=${TLS_DIR}/ca.crt
# Orderer TLS CA — extracted from config block in Step 0c.
# ORDERER_CA_LOCAL: temp path on dectrust8; ORDERER_CA: deployed path on each EVM VM.
ORDERER_CA_LOCAL=/tmp/orderer-tls-ca.crt
ORDERER_CA=/data/orderer-tls-ca.crt
# Identity directory on each EVM VM: world-readable copy so the container
# process can read them regardless of Docker userns-remap or DAC restrictions.
IDENTITY_DIR=/data/evm-identity

# ---------------------------------------------------------------------------
log()     { echo "[$(date +'%H:%M:%S')] $*"; }
section() { echo; echo "=== $* ==="; }
# ---------------------------------------------------------------------------

section "STEP 0a: Fetch TLS/MSP from dectrust4 if absent locally"

if [ ! -f "${TLS_CA}" ]; then
  log "TLS/MSP not found locally — fetching from dectrust4..."
  mkdir -p "${TLS_DIR}" "${MSP_DIR}"
  ssh dectrust4.vpc.cloud9.ibm.com \
    "tar czf - -C /data/staging-deployment/committer-sidecar/config tls msp" \
    | tar xzf - -C "${STAGING_DIR}/committer-sidecar/config/"
  log "TLS/MSP fetched from dectrust4"
else
  log "TLS/MSP already present at ${TLS_DIR}"
fi

section "STEP 0b: Preflight checks on dectrust8"

for path in "${TLS_CA}" "${TLS_CERT}" "${TLS_KEY}" "${MSP_DIR}"; do
  [ -e "$path" ] && log "OK: $path" || { log "MISSING: $path"; exit 1; }
done

section "STEP 0c: Extract orderer TLS CA from config-block.pb.bin on dectrust4"

# Extract all unique PEM certs embedded in the protobuf config block to build
# a CA bundle the gateways can use to verify orderer TLS — the orderer CA differs
# from the committer-sidecar CA so we cannot reuse ${TLS_CA} here.
CONFIG_BLOCK_PATH=$(ssh dectrust4.vpc.cloud9.ibm.com \
  'find /data -name config-block.pb.bin 2>/dev/null | head -1')
log "Config block located at: ${CONFIG_BLOCK_PATH}"
[ -n "${CONFIG_BLOCK_PATH}" ] || { log "ERROR: config-block.pb.bin not found on dectrust4"; exit 1; }

ssh dectrust4.vpc.cloud9.ibm.com python3 - "${CONFIG_BLOCK_PATH}" <<'PYEOF' > "${ORDERER_CA_LOCAL}"
import re, sys

with open(sys.argv[1], 'rb') as f:
    data = f.read()

pattern = re.compile(b'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', re.DOTALL)
seen = set()
for cert_bytes in pattern.findall(data):
    try:
        cert_str = cert_bytes.decode('ascii').strip()
    except UnicodeDecodeError:
        continue
    if cert_str not in seen:
        seen.add(cert_str)
        print(cert_str)
        print()

sys.stderr.write(f'Extracted {len(seen)} unique certs from config block\n')
PYEOF

CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "${ORDERER_CA_LOCAL}" || true)
log "Extracted ${CERT_COUNT} certs from config block → ${ORDERER_CA_LOCAL}"
[ "$CERT_COUNT" -gt 0 ] || { log "ERROR: No certs extracted from config block"; exit 1; }

# ---------------------------------------------------------------------------
section "STEP 1: Build fabric-x-evm image on each EVM VM (parallel, branch: ${EVM_BRANCH})"

build_pids=()
for host in "${HOSTS[@]}"; do
  (
    # Pass EVM_BRANCH as $1 so the single-quoted heredoc can use it.
    ssh "${host}.vpc.cloud9.ibm.com" bash -s -- "$EVM_BRANCH" <<'BUILD'
set -e
EVM_BRANCH="$1"
cd /data
[ -d fabric-x-evm ] || git clone https://github.com/hyperledger/fabric-x-evm.git 2>&1
cd fabric-x-evm
git fetch 2>&1
git checkout "$EVM_BRANCH" 2>&1
git reset --hard "origin/$EVM_BRANCH" 2>&1
EVM_SHA=$(git rev-parse --short HEAD)
if docker image inspect "fabric-x-evm:${EVM_SHA}" &>/dev/null; then
    echo "fabric-x-evm:${EVM_SHA} already exists; skipping build"
else
    make build-image IMAGE_TAG="${EVM_SHA}" 2>&1 | tail -5
fi
docker tag "fabric-x-evm:${EVM_SHA}" fabric-x-evm:dev
echo "BUILD_OK sha=${EVM_SHA}"
BUILD
  ) 2>&1 | sed "s/^/[build:${host}] /" &
  build_pids+=($!)
done

build_ok=true
for i in "${!HOSTS[@]}"; do
  if wait "${build_pids[$i]}"; then
    log "build on ${HOSTS[$i]}: OK"
  else
    log "build on ${HOSTS[$i]}: FAILED"
    build_ok=false
  fi
done
$build_ok || { log "Build failures — aborting"; exit 1; }

# Resolve the SHA now that all hosts are on the correct branch.
EVM_SHA=$(ssh "dectrust5.vpc.cloud9.ibm.com" \
    "git -C /data/fabric-x-evm rev-parse --short HEAD" 2>/dev/null || echo "")
log "EVM SHA: ${EVM_SHA}"

# Build fxconfig binary on dectrust5 (repo already cloned above) and install on dectrust8.
log "Building fxconfig binary on dectrust5..."
ssh dectrust5.vpc.cloud9.ibm.com 'bash -s' <<'FXBUILD'
set -e
cd /data/fabric-x-evm
go build -o /tmp/fxconfig-bin github.com/hyperledger/fabric-x/tools/fxconfig 2>&1
echo FXCONFIG_BUILD_OK
FXBUILD
scp -q dectrust5.vpc.cloud9.ibm.com:/tmp/fxconfig-bin /tmp/fxconfig
chmod +x /tmp/fxconfig
log "fxconfig installed at /tmp/fxconfig"

# ---------------------------------------------------------------------------
section "STEP 2: Distribute TLS/MSP and orderer CA to EVM VMs"

for host in "${HOSTS[@]}"; do
  ssh "${host}.vpc.cloud9.ibm.com" \
    "mkdir -p /data/staging-deployment/committer-sidecar/config/tls \
               /data/staging-deployment/committer-sidecar/config/msp"
  scp -q "${TLS_CA}" "${TLS_CERT}" "${TLS_KEY}" \
    "${host}.vpc.cloud9.ibm.com:/data/staging-deployment/committer-sidecar/config/tls/"
  scp -rq "${MSP_DIR}" \
    "${host}.vpc.cloud9.ibm.com:/data/staging-deployment/committer-sidecar/config/"
  scp -q "${ORDERER_CA_LOCAL}" "${host}.vpc.cloud9.ibm.com:${ORDERER_CA}"
  ssh "${host}.vpc.cloud9.ibm.com" "chmod 644 ${ORDERER_CA}"
  log "TLS/MSP + orderer CA distributed to ${host}"
done

# Make a world-readable copy of MSP + TLS on each EVM VM so the container
# process can read them regardless of Docker user namespace remapping.
for host in "${HOSTS[@]}"; do
  ssh "${host}.vpc.cloud9.ibm.com" "
    rm -rf ${IDENTITY_DIR}
    mkdir -p ${IDENTITY_DIR}
    cp -rp /data/staging-deployment/committer-sidecar/config/msp ${IDENTITY_DIR}/msp
    cp -rp /data/staging-deployment/committer-sidecar/config/tls  ${IDENTITY_DIR}/tls
    chmod -R a+r ${IDENTITY_DIR}
    find ${IDENTITY_DIR} -type d -exec chmod a+x {} \\;
  "
  log "Identity copy (world-readable) created on ${host}"
done

# ---------------------------------------------------------------------------
section "STEP 3: Write gateway config files"

write_config() {
  local n=$1 ns=$2
  # All identity paths point to the world-readable copy under /data/evm-identity/
  # so the container process can read them regardless of Docker userns-remap.
  local id_msp="${IDENTITY_DIR}/msp"
  local id_cert="${IDENTITY_DIR}/tls/server.crt"
  local id_key="${IDENTITY_DIR}/tls/server.key"
  local id_ca="${IDENTITY_DIR}/tls/ca.crt"
  cat <<YAMLEOF
network:
  protocol: fabric-x
  channel: ${CHANNEL}
  namespace: ${ns}
  ns-version: "1.0"
  chain-id: ${CHAIN_ID}

gateway:
  listen: "0.0.0.0:8545"

  identity:
    msp-id: ${MSP_ID}
    msp-dir: ${id_msp}

  database:
    connection-string: "file:/data/gateway-${n}.db"
    trie-path: "/data/gateway-trie-${n}"

  orderers:
    - endpoint:
        host: dectrust1.vpc.cloud9.ibm.com
        port: ${ORDERER_PORT}
      tls:
        mode: mtls
        cert-path: ${id_cert}
        key-path: ${id_key}
        ca-cert-paths:
          - ${ORDERER_CA}
    - endpoint:
        host: dectrust2.vpc.cloud9.ibm.com
        port: ${ORDERER_PORT}
      tls:
        mode: mtls
        cert-path: ${id_cert}
        key-path: ${id_key}
        ca-cert-paths:
          - ${ORDERER_CA}
    - endpoint:
        host: dectrust3.vpc.cloud9.ibm.com
        port: ${ORDERER_PORT}
      tls:
        mode: mtls
        cert-path: ${id_cert}
        key-path: ${id_key}
        ca-cert-paths:
          - ${ORDERER_CA}
    - endpoint:
        host: dectrust4.vpc.cloud9.ibm.com
        port: ${ORDERER_PORT}
      tls:
        mode: mtls
        cert-path: ${id_cert}
        key-path: ${id_key}
        ca-cert-paths:
          - ${ORDERER_CA}

  committer:
    endpoint:
      host: ${COMMITTER_HOST}
      port: ${COMMITTER_PORT}
    tls:
      mode: mtls
      cert-path: ${id_cert}
      key-path: ${id_key}
      ca-cert-paths:
        - ${id_ca}

  sync-timeout: 5m
  worker-count: 8

endorsers:
  - name: org1
    identity:
      msp-id: ${MSP_ID}
      msp-dir: ${id_msp}
    committer:
      endpoint:
        host: ${COMMITTER_HOST}
        port: ${COMMITTER_PORT}
      tls:
        mode: mtls
        cert-path: ${id_cert}
        key-path: ${id_key}
        ca-cert-paths:
          - ${id_ca}
    database:
      database: "sqlite"
      connection-string: "file:/data/endorser-${n}.db"
YAMLEOF
}

for i in "${!HOSTS[@]}"; do
  host="${HOSTS[$i]}"
  ns="${NAMESPACES[$i]}"
  n=$((i + 1))
  local_cfg="/tmp/evm-config-${n}.yaml"
  remote_cfg="/data/fabric-x-evm-config-${n}.yaml"

  write_config "$n" "$ns" > "$local_cfg"
  scp -q "$local_cfg" "${host}.vpc.cloud9.ibm.com:${remote_cfg}"
  ssh "${host}.vpc.cloud9.ibm.com" "chmod 644 ${remote_cfg}"
  log "Config written → ${host}:${remote_cfg}"

  # Write a test-process config: same network/orderer/committer/identity but with
  # temp DB paths so the test process doesn't share SQLite files with the container.
  local_test_cfg="/tmp/evm-test-config-${n}.yaml"
  sed \
    -e "s|file:/data/gateway-${n}\.db|file:/tmp/test-gateway-${n}.db|g" \
    -e "s|trie-path: \"/data/gateway-trie-${n}\"|trie-path: \"/tmp/test-gateway-trie-${n}\"|g" \
    -e "s|file:/data/endorser-${n}\.db|file:/tmp/test-endorser-${n}.db?mode=memory\&cache=shared|g" \
    "$local_cfg" > "$local_test_cfg"
  scp -q "$local_test_cfg" "${host}.vpc.cloud9.ibm.com:/data/fabric-x-evm-test-config-${n}.yaml"
  ssh "${host}.vpc.cloud9.ibm.com" "chmod 644 /data/fabric-x-evm-test-config-${n}.yaml"
  log "Test config written → ${host}:/data/fabric-x-evm-test-config-${n}.yaml"
done

echo
echo "=== Rendered config for gateway 1 (dectrust5 / evmns1) ==="
cat /tmp/evm-config-1.yaml

# ---------------------------------------------------------------------------
section "STEP 4: Create namespaces via fxconfig (runs on dectrust8)"

cat > /tmp/fxconfig-staging.yaml <<FXEOF
logging:
  level: info

msp:
  localMspID: ${MSP_ID}
  configPath: ${MSP_DIR}

orderer:
  address: dectrust1.vpc.cloud9.ibm.com:${ORDERER_PORT}
  channel: ${CHANNEL}
  tls:
    enabled: true
    clientCert: ${TLS_CERT}
    clientKey: ${TLS_KEY}
    rootCerts:
      - ${ORDERER_CA_LOCAL}

queries:
  address: ${QUERY_HOST}:${QUERY_PORT}
  tls:
    enabled: true
    clientCert: ${TLS_CERT}
    clientKey: ${TLS_KEY}
    rootCerts:
      - ${TLS_CA}

notifications:
  address: ${COMMITTER_HOST}:${COMMITTER_PORT}
  tls:
    enabled: true
    clientCert: ${TLS_CERT}
    clientKey: ${TLS_KEY}
    rootCerts:
      - ${TLS_CA}
  connectionTimeout: 30s
  waitingTimeout: 60s
FXEOF

for ns in evmns1 evmns2 evmns3; do
  echo "--- namespace create: ${ns} ---"
  if /tmp/fxconfig namespace create "${ns}" \
       --policy="OR('Org1MSP.member')" \
       --endorse --submit --wait \
       --config=/tmp/fxconfig-staging.yaml 2>&1; then
    log "NAMESPACE_OK: ${ns}"
  else
    log "NAMESPACE_RESULT: ${ns} — see output above (may already exist)"
  fi
done

# ---------------------------------------------------------------------------
section "STEP 5: Start EVM gateway containers (parallel)"

# Note: --security-opt label=disable bypasses SELinux labeling on RHEL 9,
# allowing the container to read host-mounted files without relabeling.

start_pids=()
for i in "${!HOSTS[@]}"; do
  host="${HOSTS[$i]}"
  n=$((i + 1))
  (
    ssh "${host}.vpc.cloud9.ibm.com" bash -s <<STARTEOF
set -e
# Skip restart if the running container already uses this exact image.
running_img=\$(docker inspect evm-gateway --format '{{.Config.Image}}' 2>/dev/null || echo '')
if [ "\$running_img" = "fabric-x-evm:${EVM_SHA}" ]; then
    echo "Gateway already running fabric-x-evm:${EVM_SHA}; skipping restart"
    exit 0
fi
# Quick sanity check: can we read the config file at all?
echo "Config perms: \$(ls -la /data/fabric-x-evm-config-${n}.yaml)"

docker rm -f evm-gateway 2>/dev/null && echo "Removed existing container" || true

# :z on bind mounts sets the svirt_sandbox_file_t SELinux label so the container
# process can read the files. --security-opt label=disable is belt-and-suspenders.
# Overlapping mounts: /data (rw,z) first, then /data/staging-deployment (ro,z) overlays it.
docker run -d \\
  --name evm-gateway \\
  --restart unless-stopped \\
  --network host \\
  --security-opt label=disable \\
  --user 0:0 \\
  -v /data:/data:z \\
  -v /data/staging-deployment:/data/staging-deployment:ro,z \\
  fabric-x-evm:dev \\
  start --config /data/fabric-x-evm-config-${n}.yaml
echo CONTAINER_STARTED
STARTEOF
  ) 2>&1 | sed "s/^/[start:${host}] /" &
  start_pids+=($!)
done

for pid in "${start_pids[@]}"; do wait "$pid" || true; done
log "All containers launched; waiting 30s for initialization..."
sleep 30

# ---------------------------------------------------------------------------
section "Gateway startup logs (last 15 lines each)"

for host in "${HOSTS[@]}"; do
  echo "--- ${host} ---"
  ssh "${host}.vpc.cloud9.ibm.com" "docker logs evm-gateway 2>&1 | tail -15" || echo "(log fetch failed)"
done

# ---------------------------------------------------------------------------
section "STEP 6: JSON-RPC health check"

all_healthy=true
for host in "${HOSTS[@]}"; do
  printf "%s: " "$host"
  result=$(curl -sf \
    -X POST "http://${host}.vpc.cloud9.ibm.com:8545" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    --max-time 10 2>&1) || result="HEALTH_CHECK_FAILED"
  echo "$result"
  [[ "$result" == *"result"* ]] || all_healthy=false
done

# ---------------------------------------------------------------------------
section "DEPLOYMENT SUMMARY"
echo "  Builds:     dectrust5 OK  dectrust6 OK  dectrust7 OK"
echo "  Namespaces: evmns1 (dectrust5)  evmns2 (dectrust6)  evmns3 (dectrust7)"
echo "  Configs:    /data/fabric-x-evm-config-{1,2,3}.yaml"
if $all_healthy; then
  echo "  Health:     ALL HEALTHY"
else
  echo "  Health:     SOME FAILURES — review logs above"
fi
echo
echo "Ready for workload review."
