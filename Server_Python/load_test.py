#!/usr/bin/env python3
"""Submit signed inbound transactions and wait for them to be committed."""

import argparse
import base64
import json
import time
import uuid
from datetime import datetime, timezone
from urllib.error import URLError
from urllib.request import Request, urlopen

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


API_URL = "http://127.0.0.1:8000/api/v1"
NODE_IDS = ("node_a", "node_b", "node_c", "node_d")
ITEM_METADATA = {
    "itemName": "Blockchain load-test item",
    "brand": "Test",
    "category": "Load test",
}


def canonical_json(value: dict) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def request_json(url: str, payload: dict | None = None) -> dict:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    headers = {} if payload is None else {"Content-Type": "application/json"}
    request = Request(url, data=data, headers=headers)
    with urlopen(request, timeout=15) as response:
        body = json.load(response)
    if not isinstance(body, dict):
        raise RuntimeError(f"Expected a JSON object from {url}")
    return body


def make_transaction(
    index: int,
    run_id: str,
    item_id: str,
    private_key: Ed25519PrivateKey,
    public_key: str,
) -> dict:
    transaction = {
        "client_ID": "load-test@example.invalid",
        "item_id": item_id,
        "quantity": 1,
        "location": "load-test-warehouse",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "trans_id": f"loadtest-{run_id}-{index:06d}",
        "client_public_key": public_key,
        "item_catalog": {item_id: ITEM_METADATA},
    }
    transaction["signature"] = base64.b64encode(
        private_key.sign(canonical_json(transaction))
    ).decode("ascii")
    return {"flag": "transaction", **transaction}


def committed_transaction_ids(baseline_height: int, expected_ids: set[str]) -> tuple[set[str], int]:
    found: set[str] = set()
    before: int | None = None
    latest_height = 0

    while True:
        query = "?limit=100"
        if before is not None:
            query += f"&before_n_block={before}"
        page = request_json(f"{API_URL}/chain/history{query}")
        blocks = page.get("blocks")
        if not isinstance(blocks, list):
            raise RuntimeError("Chain history response does not contain a blocks list")
        if not blocks:
            break

        if before is None:
            latest_height = int(blocks[0]["n_block"])

        heights = []
        for block in blocks:
            heights.append(int(block["n_block"]))
            transactions = block.get("transactions", [])
            if isinstance(transactions, list):
                found.update(
                    transaction["trans_id"]
                    for transaction in transactions
                    if isinstance(transaction, dict)
                    and isinstance(transaction.get("trans_id"), str)
                    and transaction["trans_id"] in expected_ids
                )

        if min(heights) <= baseline_height or not page.get("has_more"):
            break
        next_before = page.get("next_before_n_block")
        if not isinstance(next_before, int) or next_before >= min(heights):
            raise RuntimeError("Chain history returned an invalid pagination cursor")
        before = next_before

    return found, latest_height


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Submit signed test transactions through an Elixir node and monitor commits."
    )
    parser.add_argument("--count", type=int, default=1998, help="number of transactions (default: 1998)")
    parser.add_argument("--node", choices=NODE_IDS, default="node_a", help="Elixir node to send through")
    parser.add_argument("--delay", type=float, default=0.01, help="seconds between transactions (default: 0.01)")
    parser.add_argument(
        "--timeout",
        type=int,
        default=600,
        help="seconds to wait for every test transaction to be committed (default: 600)",
    )
    args = parser.parse_args()
    if args.count < 1:
        parser.error("--count must be at least 1")
    if args.delay < 0:
        parser.error("--delay cannot be negative")
    if args.timeout < 1:
        parser.error("--timeout must be at least 1")
    return args


def main() -> int:
    args = parse_args()
    initial_history = request_json(f"{API_URL}/chain/history?limit=1")
    initial_blocks = initial_history.get("blocks")
    if not isinstance(initial_blocks, list):
        raise RuntimeError("Chain history response does not contain a blocks list")
    baseline_height = int(initial_blocks[0]["n_block"]) if initial_blocks else 0

    private_key = Ed25519PrivateKey.generate()
    public_key = base64.b64encode(
        private_key.public_key().public_bytes(
            serialization.Encoding.Raw,
            serialization.PublicFormat.Raw,
        )
    ).decode("ascii")
    run_id = uuid.uuid4().hex
    item_id = f"loadtest-item-{run_id}"
    expected_ids = {
        f"loadtest-{run_id}-{index:06d}" for index in range(args.count)
    }
    endpoint = f"http://{args.node}:6000/api/v1/python_call"

    print(
        f"Starting load test: {args.count} signed inbound transactions via {args.node}; "
        f"chain starts at block {baseline_height}."
    )
    for index in range(args.count):
        response = request_json(
            endpoint,
            make_transaction(index, run_id, item_id, private_key, public_key),
        )
        if response.get("routed") is not True:
            raise RuntimeError(f"{args.node} did not route transaction {index + 1}: {response}")
        if (index + 1) % 100 == 0 or index + 1 == args.count:
            print(f"Submitted {index + 1}/{args.count} transactions.")
        if args.delay:
            time.sleep(args.delay)

    deadline = time.monotonic() + args.timeout
    last_progress = -1
    while time.monotonic() < deadline:
        try:
            committed, latest_height = committed_transaction_ids(
                baseline_height, expected_ids
            )
        except URLError as exc:
            print(f"Could not read chain history yet: {exc}")
            time.sleep(2)
            continue

        if len(committed) != last_progress:
            print(
                f"Committed {len(committed)}/{args.count}; "
                f"latest block: {latest_height}."
            )
            last_progress = len(committed)
        if len(committed) == args.count:
            print(
                f"Load test complete: all {args.count} transactions were committed; "
                f"chain advanced by {latest_height - baseline_height} blocks."
            )
            return 0
        time.sleep(2)

    raise TimeoutError(
        f"Timed out waiting for commits: {last_progress}/{args.count} transactions "
        f"were found in the chain. Check Docker logs and chain history."
    )


if __name__ == "__main__":
    raise SystemExit(main())
