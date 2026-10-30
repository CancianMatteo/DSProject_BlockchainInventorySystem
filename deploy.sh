#!/usr/bin/env bash
set -Eeuo pipefail

# Deploy 4 nodes on a single VPS host (demo deployment).
#
# Nothing identifying your infrastructure is stored in git: the script asks
# interactively for VPS IP, SSH user, SSH password and deployment path (VPS_IP /
# VPS_USER / VPS_PASS / VPS_PATH may also be exported beforehand for non-interactive use).
#
# Host port mapping (every container exposes 8000 for the Python API and 4000
# for the Elixir cluster protocol; the script publishes them on the VPS host):
#   node_a -> 8001 / 4001      node_b -> 8002 / 4002
#   node_c -> 8003 / 4003      node_d -> 8004 / 4004
#
# The 4 Ed25519 validator keypairs and shared secrets are generated once for
# the deployment and provided to every node through protected environment files.

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NODES="node_a node_b node_c node_d"

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

printf '=== Single VPS Deployment (hosts node_a, node_b, node_c, node_d) ===\n'
VPS_IP="${VPS_IP:-}"
VPS_USER="${VPS_USER:-}"
VPS_PASS="${VPS_PASS:-}"
VPS_PATH="${VPS_PATH:-}"
prompt_value VPS_IP 'VPS IP or hostname'
prompt_value VPS_USER 'VPS SSH user'
prompt_value VPS_PASS 'VPS SSH password (empty = key-based auth)' 1
prompt_value VPS_PATH 'VPS deployment path (absolute)'

valid_host "$VPS_IP" || die "VPS_IP is not a valid hostname/IP."
valid_user "$VPS_USER" || die "VPS_USER is not a valid SSH user."
valid_path "$VPS_PATH" || die "VPS_PATH must be an absolute path without '..' segments."

for command in ssh scp tar; do
  need_cmd "$command"
done
if [[ -n "$VPS_PASS" ]]; then
  need_cmd sshpass
fi

[[ -f "$ROOT_DIR/Server_Python/.env" ]] || die "Server_Python/.env was not found."
[[ -f "$ROOT_DIR/Server_Python/Dockerfile" ]] || die "Server_Python/Dockerfile was not found."
[[ -f "$ROOT_DIR/Server_MessagerNode/Dockerfile" ]] || die "Server_MessagerNode/Dockerfile was not found."

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bis-deploy.XXXXXX")"
ARCHIVE="$STAGE_DIR/code.tar.gz"
ENV_BUNDLE="$STAGE_DIR/env-bundle.tar.gz"
trap 'rm -rf "$STAGE_DIR"' EXIT

tar -czf "$ARCHIVE"   --exclude='Server_Python/.venv'   --exclude='Server_Python/.env'   --exclude='Server_MessagerNode/.env'   --exclude='Server_Python/.git'   --exclude='Server_Python/.pytest_cache'   --exclude='Server_Python/**/__pycache__'   --exclude='Server_Python/**/*.pyc'   --exclude='Server_MessagerNode/.git'   --exclude='Server_MessagerNode/_build'   --exclude='Server_MessagerNode/deps'   --exclude='Server_MessagerNode/.elixir_ls'   -C "$ROOT_DIR" Server_Python Server_MessagerNode

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
  suffix="$(node_number "$node")"
  node_env_dir="$SECRET_DIR/env/$node"
  mkdir -p "$node_env_dir"
  chmod 700 "$node_env_dir"
  private_var="${node}_private"
  public_var="${node}_public"
  awk \
    -v node_id="$node" \
    -v suffix="$suffix" \
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
      /^ELIXIR_HOST=/ { next }
      /^ELIXIR_HTTP_PORT=/ { print "ELIXIR_HTTP_PORT=600" suffix; next }
      { print }
    ' "$ROOT_DIR/Server_Python/.env" > "$node_env_dir/.env"
  {
    printf 'VALIDATOR_PRIVATE_KEY=%s\n' "${!private_var}"
    printf 'VALIDATOR_PUBLIC_KEYS=%s\n' "$PUBLIC_KEYS"
    printf 'SERVER_SIGN_PRIVATE_KEY=%s\n' "${!private_var}"
    printf 'SERVER_SIGN_PUBLIC_KEY=%s\n' "${!public_var}"
    printf 'ELIXIR_HOST=%s\n' "bis-messagernode-$node"
    printf 'ELIXIR_HTTP_PORT=600%s\n' "$suffix"
  } >> "$node_env_dir/.env"
  chmod 600 "$node_env_dir/.env"
done

printf '%s' "$PUBLIC_KEYS" > "$SECRET_DIR/node-public-keys.json"
tar -czf "$ENV_BUNDLE" -C "$SECRET_DIR" env initial-admin-password node-public-keys.json

printf 'Copying code and shared cluster material to VPS (%s)...\n' "$VPS_IP"
ssh_wrap "$VPS_USER" "$VPS_IP" "$VPS_PASS" "mkdir -p '$VPS_PATH'"
scp_wrap "$VPS_USER" "$VPS_IP" "$VPS_PASS" "$ARCHIVE" "$VPS_PATH/deploy.tar.gz"
scp_wrap "$VPS_USER" "$VPS_IP" "$VPS_PASS" "$ENV_BUNDLE" "$VPS_PATH/env-bundle.tar.gz"

printf 'Deploying node_a, node_b, node_c, node_d on VPS (%s)...\n' "$VPS_IP"
ssh_wrap "$VPS_USER" "$VPS_IP" "$VPS_PASS" bash -s -- "$VPS_PATH" "$NODES" <<'REMOTE'
set -Eeuo pipefail
umask 077

WDIR="$1"
NODES="$2"
cd "$WDIR"
rm -rf "$WDIR/Server_Python" "$WDIR/Server_MessagerNode"
tar -xzf deploy.tar.gz
rm -f deploy.tar.gz

for command in docker openssl awk grep tail base64 tr; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'Error: required VPS command not found: %s
' "$command" >&2
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
    *) printf 'Error: unknown node %s
' "$1" >&2; exit 1 ;;
  esac
}

if grep -q '^SMTP_HOST=smtp.example.com$' "$ENV_DIR/node_a/.env" || grep -q '^SMTP_PASS=CHANGE_ME_SMTP_PASSWORD$' "$ENV_DIR/node_a/.env"; then
printf 'Warning: SMTP still has example credentials; email-based authentication and alerts will not work until configured.
' >&2
fi

printf '{"node_a":"node_a","node_b":"node_b","node_c":"node_c","node_d":"node_d"}
'   > "$WDIR/Server_MessagerNode/cluster.json"
if [[ ! -f "$WDIR/Server_MessagerNode/mix.lock" ]]; then
  printf '%%{}
' > "$WDIR/Server_MessagerNode/mix.lock"
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

  docker run -d     --name "$backend"     --network bis_cluster     --network-alias "backend-$node"     --restart unless-stopped     --env-file "$ENV_DIR/$node/.env"     --publish "800$suffix:8000"     --volume "bis-data-$node:/data"     bis-python:deploy >/dev/null

  peers=""
  for other in node_a node_b node_c node_d; do
    [[ "$other" == "$node" ]] && continue
    peers="${peers}${other}:4000,"
  done
  peers="${peers%,}"

  docker run -d     --name "$interface"     --network bis_cluster     --network-alias "$node"     --restart unless-stopped     --env NODE_ID="$node"     --env PYTHON_HOST="backend-$node"     --env PYTHON_PORT=8000     --env ELIXIR_HTTP_PORT=600$suffix     --env "PEERS=$peers"     --publish "400$suffix:4000"     --publish "600$suffix:600$suffix"     bis-messagernode:deploy >/dev/null
done

printf 'Waiting for services to start ...
'
for node in $NODES; do
  suffix="$(node_number "$node")"
  backend="bis-python-$node"
  interface="bis-messagernode-$node"

  [[ "$(docker inspect -f '{{.State.Running}}' "$backend")" == true ]] || {
    docker logs "$backend" >&2
    printf 'Error: %s is not running.
' "$backend" >&2
    exit 1
  }
  backend_ready=false
  for attempt in {1..30}; do
    if docker exec "$backend" python -c       'import json, urllib.request; base="http://127.0.0.1:8000/api/v1/health/"; live=json.load(urllib.request.urlopen(base+"live", timeout=5)); ready=json.load(urllib.request.urlopen(base+"ready", timeout=5)); assert live.get("status")=="live", live; assert ready.get("status")=="ready" and ready.get("checks",{}).get("validator_quorum_configured") is True, ready'       >/dev/null 2>&1; then
      backend_ready=true
      break
    fi
    sleep 1
  done
  [[ "$backend_ready" == true ]] || {
      docker logs "$backend" >&2
      printf 'Error: backend health checks failed for %s.
' "$backend" >&2
      exit 1
  }
  docker port "$backend" 8000/tcp | grep -q ":800$suffix$" || {
    printf 'Error: expected host port 800%s is not published for %s.
' "$suffix" "$backend" >&2
    exit 1
  }

  [[ "$(docker inspect -f '{{.State.Running}}' "$interface")" == true ]] || {
    docker logs "$interface" >&2
    printf 'Error: %s is not running.
' "$interface" >&2
    exit 1
  }
  interface_ready=false
  for attempt in {1..30}; do
    if docker logs "$interface" 2>&1 | grep -q 'BFT-PoA Modificato Avviato'; then
      interface_ready=true
      break
    fi
    [[ "$(docker inspect -f '{{.State.Running}}' "$interface")" == true ]] || break
    sleep 1
  done
  [[ "$interface_ready" == true ]] || {
    docker logs "$interface" >&2
    printf 'Error: consensus engine did not start for %s.
' "$interface" >&2
    exit 1
  }
  docker port "$interface" 4000/tcp | grep -q ":400$suffix$" || {
    printf 'Error: expected host port 400%s is not published for %s.
' "$suffix" "$interface" >&2
    exit 1
  }
  printf 'Verified %s: backend :800%s (ready), interface :400%s (consensus engine running).
'     "$node" "$suffix" "$suffix"
done

printf '
Deployment verified. Bootstrap admin password: %s/runtime/initial-admin-password (read it over SSH).
' "$RUNTIME_DIR"
printf 'Note: cross-service consensus calls go through POST /api/v1/python_call (implemented in Server_Python).
'
REMOTE

VPS_PASS=""

cat <<EOF

Deployment completed.
  VPS ($VPS_IP:$VPS_PATH):
    node_a -> Python API :8001 / Elixir Gossip :4001 / Elixir Simbehaviour :6001
    node_b -> Python API :8002 / Elixir Gossip :4002 / Elixir Simbehaviour :6002
    node_c -> Python API :8003 / Elixir Gossip :4003 / Elixir Simbehaviour :6003
    node_d -> Python API :8004 / Elixir Gossip :4004 / Elixir Simbehaviour :6004

SimBehaviour endpoints (per node Python API, testing only):
  POST /api/v1/simbehaviour/healthy     - normal behaviour (default)
  POST /api/v1/simbehaviour/noclients   - talks to peers, ignores clients
  POST /api/v1/simbehaviour/noresponse  - talks to nobody
  POST /api/v1/simbehaviour/bizantine   - drops client txs, forges proposals/votes
Example: curl -X POST http://<vps-ip>:8001/api/v1/simbehaviour/noclients
EOF
