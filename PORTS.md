# Port map — Blockchain Inventory System

Each logical node = **2 containers** sharing the node's network identity but
binding **different ports**, so nothing collides. Host-side uniqueness comes
from the published ports chosen by `deploy.sh`.

## Container ports (same on every node)

| Process | Container port | Protocol | Reachable from |
|---|---|---|---|
| Python backend (FastAPI) | **8000** | HTTP/JSON | external clients (`/api/v1/auth`, `/users`, `/chain`, `/simbehaviour`, `/health`, …) AND the co-located Elixir engine (`POST /api/v1/python_call`). One socket, routed by URL path — no split needed. |
| Elixir `ClusterListener` | **4000** | Erlang-term TCP (`packet: 4` framing) | peer Elixir nodes only |
| Elixir `HTTPListener` | **6000** | HTTP/JSON | co-located Python backend only (`POST /api/v1/simbehaviour` mode forwarding). **Internal-only** — no host port exposure; communication uses Docker internal networking.

The Elixir image **never binds 8000**. An old `EXPOSE 8000` in its Dockerfile was a leftover; the Dockerfile now has **no EXPOSE statements** since ports 4000 (ClusterListener) and 6000 (HTTPListener) are internal-only, communicated via Docker internal networking only. `ELIXIR_HTTP_PORT` is set per node but used only for intra-container routing.

## Host ports in the local Compose deployment

**Only Python API ports are published on the host** — all Elixir internal communication uses Docker internal networking with no host exposure.

| Node | Python API (host → 8000) |
|---|---|---|
| node_a | **8001** |
| node_b | **8002** |
| node_c | **8003** |
| node_d | **8004** |

## External deployment

For a multi-host deployment, `PEERS` must contain the validator ID and
reachable gossip address for every other node, using the form
`id@host:port`. The exact public ports depend on the deployment firewall and
must not be confused with the local Compose mapping above.

## Local `docker-compose.yml`

Same container ports (8000 / 4000 / 6000 per node); host mappings are
**8001..8004 → 8000 for the Python backends only**. Elixir cluster gossip
(port 4000) and simbehaviour listener (port 6000) use Docker internal
networking only — no host port exposure.

## Simbehaviour endpoints (testing only, per-node Python API)

- `POST /api/v1/simbehaviour/healthy` — normal behaviour (default)
- `POST /api/v1/simbehaviour/noclients` — talks to peers, 503 to clients
- `POST /api/v1/simbehaviour/noresponse` — 503 to everyone except simbehaviour/health
- `POST /api/v1/simbehaviour/bizantine` — drops client txs, forges proposals/votes
- `GET /api/v1/simbehaviour` — current mode

Example: `curl -X POST http://<vps-ip>:8001/api/v1/simbehaviour/noclients` — accessed via Python API port, forwarded internally to Elixir HTTPListener
