#!/usr/bin/env bash
set -Eeuo pipefail

# Deploy 4 nodes on 2 VPS hosts: node_a + node_b on VPS1, node_c + node_d on VPS2.
#
# Nothing identifying your infrastructure is stored in git: for each VPS the
# script asks interactively for VPS IP, SSH user, SSH password and deployment
# path (VPS1_IP / VPS1_USER / VPS1_PASS / VPS1_PATH and the VPS2_* counterparts
# may also be exported beforehand for non-interactive use).
#
# Host port mapping (every container exposes 8000 for the Python API and 4000
# for the Elixir cluster protocol; the script publishes them on each VPS host):
#   node_a -> 8001 / 4001      node_b -> 8002 / 4002
#   node_c -> 8003 / 4003      node_d -> 8004 / 4004
#
# The 4 Ed25519 validator keypairs and the shared secrets (JWT secret, app
# token, bootstrap admin password) are generated once on VPS1 so the whole
# cluster agrees on NODE_PUBLIC_KEYS. They live only on the VPS hosts (plus a
# transient local temp dir while deploying) and never in git.

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NODES_VPS1="node_a node_b"
NODES_VPS2="node_c node_d"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required local command not found: $1"
}

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=no)

ssh_wrap() {
  local user="$1" host="$2" pass="$3"
  shift 3
  if [[ -n "$pass" ]]; then
    SSHPASS="$pass" sshpass -e ssh "${SSH_OPTS[@]}" "$user@$host" "$@"
  else
    ssh "${SSH_OPTS[@]}" "$user@$host" "$@"
  fi
}

scp_wrap() {
  local user="$1" host="$2" pass="$3" src="$4" dst="$5"
  if [[ -n "$pass" ]]; then
    SSHPASS="$pass" sshpass -e scp -q -O "${SSH_OPTS[@]}" "$src" "$user@$host:$dst"
  else
    scp -q -O "${SSH_OPTS[@]}" "$src" "$user@$host:$dst"
  fi
}

prompt_value() {
  local var="$1" label="$2" silent="${3:-0}" current value
  current="${!var:-}"
  if [[ -n "$current" ]]; then
    printf '%s=%s (from environment)\n' "$var" "$current"
    return 0
  fi
  if [[ "$silent" == 1 ]]; then
    read -rsp "$label: " value
    printf '\n'
  else
    read -rp "$label: " value
  fi
  printf -v "$var" '%s' "$value"
}

valid_host() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
valid_user() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
valid_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ ! "$1" =~ (^|/)\.\.(/|$) ]]
}

printf '=== VPS1 (hosts node_a and node_b) ===\n'
VPS1_IP="${VPS1_IP:-}"
VPS1_USER="${VPS1_USER:-}"
VPS1_PASS="${VPS1_PASS:-}"
VPS1_PATH="${VPS1_PATH:-}"
prompt_value VPS1_IP 'VPS1 IP or hostname'
prompt_value VPS1_USER 'VPS1 SSH user'
prompt_value VPS1_PASS 'VPS1 SSH password (empty = key-based auth)' 1
prompt_value VPS1_PATH 'VPS1 deployment path (absolute)'

printf '=== VPS2 (hosts node_c and node_d) ===\n'
VPS2_IP="${VPS2_IP:-}"
VPS2_USER="${VPS2_USER:-}"
VPS2_PASS="${VPS2_PASS:-}"
VPS2_PATH="${VPS2_PATH:-}"
prompt_value VPS2_IP 'VPS2 IP or hostname'
prompt_value VPS2_USER 'VPS2 SSH user'
prompt_value VPS2_PASS 'VPS2 SSH password (empty = key-based auth)' 1
prompt_value VPS2_PATH 'VPS2 deployment path (absolute)'

valid_host "$VPS1_IP" || die "VPS1_IP is not a valid hostname/IP."
valid_user "$VPS1_USER" || die "VPS1_USER is not a valid SSH user."
valid_path "$VPS1_PATH" || die "VPS1_PATH must be an absolute path without '..' segments."
valid_host "$VPS2_IP" || die "VPS2_IP is not a valid hostname/IP."
valid_user "$VPS2_USER" || die "VPS2_USER is not a valid SSH user."
valid_path "$VPS2_PATH" || die "VPS2_PATH must be an absolute path without '..' segments."

for command in ssh scp tar; do
  need_cmd "$command"
done
if [[ -n "$VPS1_PASS" || -n "$VPS2_PASS" ]]; then
  need_cmd sshpass
fi

[[ -f "$ROOT_DIR/Server_Python/.env.example" ]] || die "Server_Python/.env.example was not found."
[[ -f "$ROOT_DIR/Server_Python/Dockerfile" ]] || die "Server_Python/Dockerfile was not found."
[[ -f "$ROOT_DIR/Server_MessagerNode/Dockerfile" ]] || die "Server_MessagerNode/Dockerfile was not found."

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bis-deploy.XXXXXX")"
ARCHIVE="$STAGE_DIR/code.tar.gz"
ENV_BUNDLE="$STAGE_DIR/env-bundle.tar.gz"
trap 'rm -rf "$STAGE_DIR"' EXIT

tar -czf "$ARCHIVE" \
  --exclude='Server_Python/.venv' \
  --exclude='Server_Python/.env' \
  --exclude='Server_MessagerNode/.env' \
  --exclude='Server_Python/.git' \
  --exclude='Server_Python/.pytest_cache' \
  --exclude='Server_Python/**/__pycache__' \
  --exclude='Server_Python/**/*.pyc' \
  --exclude='Server_MessagerNode/.git' \
  --exclude='Server_MessagerNode/_build' \
  --exclude='Server_MessagerNode/deps' \
  --exclude='Server_MessagerNode/.elixir_ls' \
  -C "$ROOT_DIR" Server_Python Server_MessagerNode

# ---- Shared cluster material (generated once, locally, never in git) ----
need_cmd openssl
SECRET_DIR="$STAGE_DIR/cluster"
mkdir -p "$SECRET_DIR/env" "$SECRET_DIR/keys"
chmod 700 "$STAGE_DIR" "$SECRET_DIR" "$SECRET_DIR/env" "$SECRET_DIR/keys"

node_number() {
  case "$1" in
    node_a) printf '1' ;;
    node_b) printf '2' ;;
    node_c) printf '3' ;;
    node_d) printf '4' ;;
    *) die "Unknown node $1." ;;
  esac
}

for node in node_a node_b node_c node_d; do
  priv_file="$SECRET_DIR/keys/$node.pem"
  openssl genpkey -algorithm ED25519 -out "$priv_file"
  chmod 600 "$priv_file"
  priv="$(openssl pkey -in "$priv_file" -outform DER | tail -c 32 | base64 | tr -d '\n')"
  pub="$(openssl pkey -in "$priv_file" -pubout -outform DER | tail -c 32 | base64 | tr -d '\n')"
  [[ "${#priv}" -eq 44 && "${#pub}" -eq 44 ]] || die "Could not extract an Ed25519 key pair for $node."
  printf -v "${node}_private" '%s' "$priv"
  printf -v "${node}_public" '%s' "$pub"
done

PUBLIC_KEYS="{\"node_a\":\"$node_a_public\",\"node_b\":\"$node_b_public\",\"node_c\":\"$node_c_public\",\"node_d\":\"$node_d_public\"}"
JWT_SECRET="$(openssl rand -base64 48 | tr -d '\n')"
APP_CLIENT_TOKEN="$(openssl rand -base64 32 | tr -d '\n')"
INITIAL_ADMIN_PASSWORD="$(openssl rand -base64 32 | tr -d '\n')"
printf '%s' "$INITIAL_ADMIN_PASSWORD" > "$SECRET_DIR/initial-admin-password"
chmod 600 "$SECRET_DIR/initial-admin-password"

for node in node_a node_b node_c node_d; do
  node_env_dir="$SECRET_DIR/env/$node"
  mkdir -p "$node_env_dir"
  chmod 700 "$node_env_dir"
  private_var="${node}_private"
  public_var="${node}_public"
  awk \
    -v node_id="$node" \
    -v private_key="${!private_var}" \
    -v public_keys="$PUBLIC_KEYS" \
    -v jwt_secret="$JWT_SECRET" \
    -v app_client_token="$APP_CLIENT_TOKEN" \
    -v initial_admin_password="$INITIAL_ADMIN_PASSWORD" \
    '
      /^JWT_SECRET=/ { print "JWT_SECRET=" jwt_secret; next }
      /^NODE_ID=/ { print "NODE_ID=" node_id; next }
      /^NODE_PRIVATE_KEY=/ { print "NODE_PRIVATE_KEY=" private_key; next }
      /^NODE_PUBLIC_KEYS=/ { print "NODE_PUBLIC_KEYS=" public_keys; next }
      /^API_PORT=/ { print "API_PORT=8000"; next }
      /^APP_CLIENT_TOKEN=/ { print "APP_CLIENT_TOKEN=" app_client_token; next }
      /^INITIAL_ADMIN_PASSWORD=/ { print "INITIAL_ADMIN_PASSWORD=" initial_admin_password; next }
      { print }
    ' "$ROOT_DIR/Server_Python/.env.example" > "$node_env_dir/.env"

  {
    printf 'VALIDATOR_PRIVATE_KEY=%s\n' "${!private_var}"
    printf 'VALIDATOR_PUBLIC_KEYS=%s\n' "$PUBLIC_KEYS"
    printf 'SERVER_SIGN_PRIVATE_KEY=%s\n' "${!private_var}"
    printf 'SERVER_SIGN_PUBLIC_KEY=%s\n' "${!public_var}"
    printf 'ELIXIR_HOST=%s\n' "bis-messagernode-$node"
    printf 'ELIXIR_HTTP_PORT=4001\n'
  } >> "$node_env_dir/.env"
  chmod 600 "$node_env_dir/.env"
done

printf '%s' "$PUBLIC_KEYS" > "$SECRET_DIR/node-public-keys.json"
tar -czf "$ENV_BUNDLE" -C "$SECRET_DIR" env initial-admin-password node-public-keys.json

deploy_remote_nodes() {
  local user="$1" host="$2" pass="$3" wdir="$4" nodes="$5"
  ssh_wrap "$user" "$host" "$pass" bash -s -- "$wdir" "$nodes" "$VPS1_IP" "$VPS2_IP" <<'REMOTE'
set -Eeuo pipefail
umask 077

WDIR="$1"
NODES="$2"
VPS1_IP="$3"
VPS2_IP="$4"
cd "$WDIR"
rm -rf "$WDIR/Server_Python" "$WDIR/Server_MessagerNode"
tar -xzf deploy.tar.gz
rm -f deploy.tar.gz

for command in docker openssl awk grep tail base64 tr; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'Error: required VPS command not found: %s\n' "$command" >&2
    exit 1
  }
done
docker info >/dev/null

RUNTIME_DIR="$WDIR/runtime"
ENV_DIR="$RUNTIME_DIR/env"
mkdir -p "$ENV_DIR"
chmod 700 "$RUNTIME_DIR" "$ENV_DIR"
tar -xzf "$WDIR/env-bundle.tar.gz" -C "$RUNTIME_DIR"
rm -f "$WDIR/env-bundle.tar.gz"
chmod 700 "$RUNTIME_DIR/env" "$RUNTIME_DIR/env"/node_*
chmod 600 "$RUNTIME_DIR/env"/node_*/.env "$RUNTIME_DIR/initial-admin-password" "$RUNTIME_DIR/node-public-keys.json"

node_number() {
  case "$1" in
    node_a) printf '1' ;;
    node_b) printf '2' ;;
    node_c) printf '3' ;;
    node_d) printf '4' ;;
    *) printf 'Error: unknown node %s\n' "$1" >&2; exit 1 ;;
  esac
}

if grep -q '^SMTP_HOST=smtp.example.com$' "$WDIR/Server_Python/.env.example" \
|| grep -q '^SMTP_PASS=CHANGE_ME_SMTP_PASSWORD$' "$WDIR/Server_Python/.env.example"; then
printf 'Warning: SMTP still has example credentials; email-based authentication and alerts will not work until configured.\n' >&2
fi

# The interface application reads this file during startup. The consensus peer
# endpoints themselves are supplied with PEERS below.
printf '{"node_a":"node_a","node_b":"node_b","node_c":"node_c","node_d":"node_d"}\n' \
  > "$WDIR/Server_MessagerNode/cluster.json"
if [[ ! -f "$WDIR/Server_MessagerNode/mix.lock" ]]; then
  printf '%%{}\n' > "$WDIR/Server_MessagerNode/mix.lock"
fi

docker network inspect bis_cluster >/dev/null 2>&1 || docker network create bis_cluster >/dev/null
docker build -t bis-python:deploy -f "$WDIR/Server_Python/Dockerfile" "$WDIR/Server_Python"
docker build -t bis-messagernode:deploy -f "$WDIR/Server_MessagerNode/Dockerfile" "$WDIR/Server_MessagerNode"

for node in $NODES; do
  suffix="$(node_number "$node")"
  backend="bis-python-$node"
  interface="bis-messagernode-$node"

  if docker container inspect "$backend" >/dev/null 2>&1; then docker rm -f "$backend" >/dev/null; fi
  if docker container inspect "$interface" >/dev/null 2>&1; then docker rm -f "$interface" >/dev/null; fi
  docker volume create "bis-data-$node" >/dev/null

  docker run -d \
    --name "$backend" \
    --network bis_cluster \
    --network-alias "backend-$node" \
    --restart unless-stopped \
    --env-file "$ENV_DIR/$node/.env" \
    --publish "800$suffix:8000" \
    --volume "bis-data-$node:/data" \
    bis-python:deploy >/dev/null

  case "$node" in
    node_a|node_b) local_vps_ip="$VPS1_IP" ;;
    *) local_vps_ip="$VPS2_IP" ;;
  esac
  peers=""
  for other in node_a node_b node_c node_d; do
    [[ "$other" == "$node" ]] && continue
    n="$(node_number "$other")"
    case "$other" in
      node_a|node_b) other_vps_ip="$VPS1_IP" ;;
      *) other_vps_ip="$VPS2_IP" ;;
    esac
    if [[ "$other_vps_ip" == "$local_vps_ip" ]]; then
      # Same VPS: plain Docker alias on the shared bis_cluster network.
      peers="${peers}${other}:4000,"
    else
      # Other VPS: public IP + the host port published for that node
      # (4001..4004); the Elixir parser supports the "id@host:port" form.
      peers="${peers}${other}@${other_vps_ip}:400${n},"
    fi
  done
  peers="${peers%,}"
  docker run -d \
    --name "$interface" \
    --network bis_cluster \
    --network-alias "$node" \
    --restart unless-stopped \
    --env NODE_ID="$node" \
    --env PYTHON_HOST="backend-$node" \
    --env PYTHON_PORT=8000 \
    --env ELIXIR_HTTP_PORT=4001 \
    --env "PEERS=$peers" \
    --publish "400$suffix:4000" \
    bis-messagernode:deploy >/dev/null
done

printf 'Waiting for services to start ...\n'
for node in $NODES; do
  suffix="$(node_number "$node")"
  backend="bis-python-$node"
  interface="bis-messagernode-$node"

  [[ "$(docker inspect -f '{{.State.Running}}' "$backend")" == true ]] || {
    docker logs "$backend" >&2
    printf 'Error: %s is not running.\n' "$backend" >&2
    exit 1
  }
  backend_ready=false
  for attempt in {1..30}; do
    if docker exec "$backend" python -c \
      'import json, urllib.request; base="http://127.0.0.1:8000/api/v1/health/"; live=json.load(urllib.request.urlopen(base+"live", timeout=5)); ready=json.load(urllib.request.urlopen(base+"ready", timeout=5)); assert live.get("status")=="live", live; assert ready.get("status")=="ready" and ready.get("checks",{}).get("validator_quorum_configured") is True, ready' \
      >/dev/null 2>&1; then
      backend_ready=true
      break
    fi
    sleep 1
  done
  [[ "$backend_ready" == true ]] || {
      docker logs "$backend" >&2
      printf 'Error: backend health checks failed for %s.\n' "$backend" >&2
      exit 1
  }
  docker port "$backend" 8000/tcp | grep -q ":800$suffix$" || {
    printf 'Error: expected host port 800%s is not published for %s.\n' "$suffix" "$backend" >&2
    exit 1
  }

  [[ "$(docker inspect -f '{{.State.Running}}' "$interface")" == true ]] || {
    docker logs "$interface" >&2
    printf 'Error: %s is not running.\n' "$interface" >&2
    exit 1
  }
  interface_ready=false
  for attempt in {1..30}; do
    if docker logs "$interface" 2>&1 | grep -q 'BFT-PoA Avviato'; then
      interface_ready=true
      break
    fi
    [[ "$(docker inspect -f '{{.State.Running}}' "$interface")" == true ]] || break
    sleep 1
  done
  [[ "$interface_ready" == true ]] || {
    docker logs "$interface" >&2
    printf 'Error: consensus engine did not start for %s.\n' "$interface" >&2
    exit 1
  }
  docker port "$interface" 4000/tcp | grep -q ":400$suffix$" || {
    printf 'Error: expected host port 400%s is not published for %s.\n' "$suffix" "$interface" >&2
    exit 1
  }
  printf 'Verified %s: backend :800%s (ready), interface :400%s (consensus engine running).\n' \
    "$node" "$suffix" "$suffix"
done

printf '\nDeployment verified. Bootstrap admin password: %s/runtime/initial-admin-password (read it over SSH).\n' "$RUNTIME_DIR"
printf 'Note: cross-service consensus calls go through POST /api/v1/python_call (implemented in Server_Python).\n'
REMOTE
}

printf 'Copying code and shared cluster material to VPS1 (%s)...\n' "$VPS1_IP"
ssh_wrap "$VPS1_USER" "$VPS1_IP" "$VPS1_PASS" "mkdir -p '$VPS1_PATH'"
scp_wrap "$VPS1_USER" "$VPS1_IP" "$VPS1_PASS" "$ARCHIVE" "$VPS1_PATH/deploy.tar.gz"
scp_wrap "$VPS1_USER" "$VPS1_IP" "$VPS1_PASS" "$ENV_BUNDLE" "$VPS1_PATH/env-bundle.tar.gz"

printf 'Copying code and shared cluster material to VPS2 (%s)...\n' "$VPS2_IP"
ssh_wrap "$VPS2_USER" "$VPS2_IP" "$VPS2_PASS" "mkdir -p '$VPS2_PATH'"
scp_wrap "$VPS2_USER" "$VPS2_IP" "$VPS2_PASS" "$ARCHIVE" "$VPS2_PATH/deploy.tar.gz"
scp_wrap "$VPS2_USER" "$VPS2_IP" "$VPS2_PASS" "$ENV_BUNDLE" "$VPS2_PATH/env-bundle.tar.gz"

printf 'Deploying node_a and node_b on VPS1 (%s)...\n' "$VPS1_IP"
deploy_remote_nodes "$VPS1_USER" "$VPS1_IP" "$VPS1_PASS" "$VPS1_PATH" "$NODES_VPS1"

printf 'Deploying node_c and node_d on VPS2 (%s)...\n' "$VPS2_IP"
deploy_remote_nodes "$VPS2_USER" "$VPS2_IP" "$VPS2_PASS" "$VPS2_PATH" "$NODES_VPS2"

# Passwords are only in shell memory; clear them as soon as they are unused.
VPS1_PASS=""
VPS2_PASS=""

cat <<EOF

Deployment completed.
  VPS1 ($VPS1_IP:$VPS1_PATH): node_a -> :8001/:4001, node_b -> :8002/:4002
  VPS2 ($VPS2_IP:$VPS2_PATH): node_c -> :8003/:4003, node_d -> :8004/:4004

Simulated-health endpoints (per node Python API, testing only):
  POST /api/v1/simhealth/healthy     - normal behaviour (default)
  POST /api/v1/simhealth/noclients   - talks to peers, ignores clients
  POST /api/v1/simhealth/noresponse  - talks to nobody
  POST /api/v1/simhealth/bizantine   - drops client txs, forges proposals/votes
Example: curl -X POST http://<vps-ip>:8001/api/v1/simhealth/noclients
EOF
