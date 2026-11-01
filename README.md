# Blockchain Inventory System

## Requirements

- Docker with the Compose plugin
- Python 3 and OpenSSL (only for the first setup)

## Setup and start

From the project folder, run:

```bash
python3 setup_env.py
docker compose up -d --build
```

Consensus timing and proposal thresholds are configured in these source files:

- [proposal_trigger_service.py](./Server_Python/app/services/proposal_trigger_service.py):
  `MAX_BLOCK_TRANSACTIONS = 200` triggers a proposal when the mempool reaches
  200 pending transactions; `IDLE_PROPOSAL_INTERVAL = 10 minutes` triggers a
  proposal when there is at least one pending transaction and that long has
  passed since the last committed block.
- [consensus_engine.ex](./Server_MessagerNode/lib/inventory_node/consensus_engine.ex):
  `@round_timeout 8000` is an 8-second consensus round timeout. It advances
  the round when consensus is stalled; it is **not** a block-proposal timer.
- [distributed_service.py](./Server_Python/app/services/distributed_service.py):
  `MAX_BLOCK_TRANSACTIONS` also limits each block to at most 200 transactions.

The proposer changes through BFT round changes. A proposal is requested when
either proposal trigger above fires.

The script asks for the admin email and password (at least 12 characters),
then creates the root `.env` with static validator keys and
`Server_Python/.env` with app settings and initial admin credentials. Compose
passes both files to the Python services, which create the admin on first
start. The script does not overwrite existing files. Keep the password and
both `.env` files private.

## Reset the local blockchain

To erase the local blockchain and start with empty databases, run these commands
from the project folder:

```bash
docker compose down -v
docker compose up -d --build
```

The `down -v` command permanently removes the Compose data volumes
`bis_data_a`, `bis_data_b`, `bis_data_c`, and `bis_data_d`. This deletes each
node's persisted blockchain and other database records, including pending
transactions and application data. Back up anything you need first. It does
not delete the `.env` files or generated validator keys, and it does not remove
the images.

Check the services and API:

```bash
docker compose ps
curl http://localhost:8001/api/v1/health/ready
```

## Test block creation with many transactions

The project includes `Server_Python/load_test.py`. After the services are
running, rebuild them so the script is present in the Python image, then run:

```bash
docker compose up -d --build
docker compose exec -T python_validator_a python /app/load_test.py --count 1998
```

The script creates signed test transactions, sends them through node A's
Elixir router (which forwards them to the other nodes), and checks chain
history until they are committed or the timeout is reached. The default is
1,998 transactions; each block holds at most 200, so expect about ten new
blocks if there are no other pending transactions. You can change the amount
with `--count`, or send through another node with `--node node_b` (also
`node_c` or `node_d`).

This test commits real blocks and adds stock for a test item to each node's
persistent database. Run it on test data, not a production deployment.

## Test Byzantine behaviour

Node D starts in `healthy` runtime mode, so Byzantine behaviour is **off by
default**. The `BIZANTINE_SCENARIO` setting selects which fault to simulate
only after Byzantine mode is enabled. Compose defaults this setting to
`invalid_signature`; that setting alone does not enable the fault.

The runtime mode starts as `healthy` in
[simbehaviour_service.py](./Server_Python/app/services/simbehaviour_service.py).
The scenario default is configured in [docker-compose.yml](./docker-compose.yml)
and read by [distributed_service.py](./Server_Python/app/services/distributed_service.py).
To select a scenario, set it in the root `.env` before creating/recreating
node D's containers:

```env
BIZANTINE_SCENARIO=invalid_signature
```

Choose one scenario at a time. Each case shows both what node D tries to do and
why that attempt cannot break the consensus rules:

- `invalid_signature`: node D signs consensus messages with an invalid key.
  Other nodes check signatures and reject D's votes or proposal. The three
  honest validators can still reach the required quorum.
- `split_brain`: if node D is proposer, it sends the commit proposal to only
  two peers and withholds its own COMMIT vote. The peers' COMMIT messages also
  carry the verified proposal and are broadcast to everyone, so the third
  honest validator can join. The three honest votes can still form a quorum.
- `equivocation`: if node D is proposer, it sends different, validly signed
  block proposals to separate groups of peers. This needs at least two pending
  transactions. Each honest node votes for at most one proposal for that
  height and round. A valid conflict proof received before a node starts
  COMMIT makes it stop voting for that round and relay the proof. If a node has
  already started COMMIT and the main block reaches quorum, it persists the
  COMMIT signatures and sends the finalized block with that certificate only
  to the reporter(s) who missed the main proposal. Each reporter verifies the
  COMMIT quorum and imports the committed block; the PREPARE certificate alone
  is not used for this recovery. The proof does not undo a block already
  committed, and D cannot get both conflicting blocks committed.
- `leader_offline`: node D sends its proposal, then withholds the commit
  proposal and its ROUND_CHANGE message. The honest validators time out,
  exchange their own ROUND_CHANGE votes, and select a new proposer after
  reaching quorum.

For an already configured local Compose cluster, set the scenario for node D
and recreate its containers. This command does not delete database volumes:

```bash
BIZANTINE_SCENARIO=equivocation docker compose up -d --force-recreate python_validator_d node_d
```

Enable the Byzantine mode on node D:

```bash
curl -X POST http://localhost:8004/api/v1/simbehaviour/bizantine
```

The mode is runtime state and resets to `healthy` after a Python backend
restart. To disable the fault before then, call:

```bash
curl -X POST http://localhost:8004/api/v1/simbehaviour/healthy
```

Verify that all backends are ready and node D reports Byzantine mode:

```bash
for port in 8001 8002 8003 8004; do
  curl -fsS "http://localhost:${port}/api/v1/health/ready"
  echo
done
curl -fsS http://localhost:8004/api/v1/simbehaviour
```

Byzantine mode does not block transaction forwarding; it changes only node D's
consensus messages. Use the included load-test script to submit signed test
transactions through node A:

```bash
docker compose exec -T python_validator_a python /app/load_test.py \
  --count 2000 --delay 0.01 --timeout 900
```

The test inserts real transactions and blocks into the persistent databases.
Do not run it against production data. Each block contains at most 200
transactions. If there are fewer than 200 pending transactions when the
10-minute idle trigger fires (for example, because the latest existing block
is already older than 10 minutes), a smaller block may be proposed and the
script can wait for the remaining transactions. In that case run the same
command again with a small additional `--count` (for example, `--count 49`)
to reach the next block threshold, or wait for the idle trigger.

The equivocation branch runs only when node D is the expected proposer:
validators are sorted as `node_a`, `node_b`, `node_c`, `node_d`, and D proposes
when `(height + round) mod 4 = 3`. The normal proposal is triggered by pending
transactions; the 8-second round timeout advances the round and proposer.
The load test may therefore commit ordinary blocks before it reaches a D-led
round. Keep the following log view open to observe the conflict proof, a node
rejecting COMMIT after seeing that proof, and certificate-based recovery:

```bash
docker compose logs -f node_a node_b node_c node_d
```

Look for messages such as `Valid equivocation proof`, `Ignoring COMMIT vote
after equivocation proof`, and `imported with a COMMIT certificate`. A node
that has already started COMMIT records the proof reporter and sends the
finalized block and COMMIT certificate only to that reporter. To monitor the
persisted chain, open these URLs in a browser and
refresh them, or query them with `curl`:

```text
http://localhost:8001/api/v1/chain/history
http://localhost:8002/api/v1/chain/history
http://localhost:8003/api/v1/chain/history
http://localhost:8004/api/v1/chain/history
```

```bash
for port in 8001 8002 8003 8004; do
  echo "Validator API on port ${port}:"
  curl -fsS "http://localhost:${port}/api/v1/chain/history?limit=1"
  echo
done
```

The newest block is first. Compare its `n_block` and `block_hash` across all
four responses to check convergence; its `votes` should include three
distinct entries with `"phase":"commit"`. With one Byzantine validator, three
honest validators can still reach quorum and the chain can continue growing.

When the test is finished, restore normal behaviour:

```bash
curl -X POST http://localhost:8004/api/v1/simbehaviour/healthy
```

The mode resets to `healthy` when the Python backend restarts.

## Deploy to one VPS

`deploy.sh` is a manual deployment script; Docker Compose and the application
do not run it automatically. From the project root, run:

```bash
bash deploy.sh
```

It asks for the VPS address, SSH user, and remote project path (or reads
`VPS_IP`, `VPS_USER`, `VPS_PASS`, and `VPS_PATH` from the environment). It
packages the Python and Elixir code, creates validator keys and deployment
secrets, copies them to the VPS over SSH, builds the Docker images, and starts
the four nodes. It checks backend health and that each consensus engine
started. The remote code folders and containers are replaced during deploy;
named database volumes are not deleted. The script requires SSH, SCP, tar,
and OpenSSL locally, plus Docker on the VPS; `sshpass` is needed only for SSH
password authentication.

## Stop

```bash
docker compose down
```

Do not add `-v` if you want to keep the databases.
