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

The proposer changes through the BFT round timeout (8 seconds). A proposal is
requested when 500 transactions are pending or 15 minutes have passed since
the last committed block; each block contains at most 500 transactions.

The script asks for the admin email and password (at least 12 characters),
then creates the root `.env` with static validator keys and
`Server_Python/.env` with app settings. The backend creates this admin on its
first start. The script does not overwrite existing files. Keep the password
and both `.env` files private.

Check the services and API:

```bash
docker compose ps
curl http://localhost:8001/api/v1/health/ready
```

## Test Byzantine behaviour

Node D can simulate four consensus faults. Choose one scenario in the root
`.env` file before starting the services:

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
  height and round; conflicting signed proposals expose the equivocation and
  can trigger a round change. D cannot get both conflicting blocks committed.
- `leader_offline`: node D sends its proposal, then withholds the commit
  proposal and its ROUND_CHANGE message. The honest validators time out,
  exchange their own ROUND_CHANGE votes, and select a new proposer after
  reaching quorum.

Set the scenario, then start or recreate node D's services so the setting is
loaded:

```bash
docker compose up -d --build --force-recreate python_validator_d node_d
```

Enable the Byzantine mode on node D:

```bash
curl -X POST http://localhost:8004/api/v1/simbehaviour/bizantine
```

Submit valid transactions as usual through the application. Byzantine mode
does not block transaction forwarding; it changes only node D's consensus
messages. The blockchain needs pending transactions to create a block. It
proposes when 500 are waiting, or after 15 minutes with at least one pending
transaction.

Open [http://localhost:8001/api/v1/chain/history](http://localhost:8001/api/v1/chain/history)
in a browser to monitor the blockchain. Refresh the page to see new blocks;
the newest block appears first. You can also check it with:

```bash
curl http://localhost:8001/api/v1/chain/history
```

Honest nodes reject invalid signatures and conflicting proposals. For
`leader_offline`, they should change round after the timeout. With one
Byzantine validator, the three honest validators can still reach quorum and
commit blocks, so the history should continue to grow when proposals succeed.

When the test is finished, restore normal behaviour:

```bash
curl -X POST http://localhost:8004/api/v1/simbehaviour/healthy
```

The mode resets to `healthy` when the Python backend restarts.

## Stop

```bash
docker compose down
```

Do not add `-v` if you want to keep the databases.
