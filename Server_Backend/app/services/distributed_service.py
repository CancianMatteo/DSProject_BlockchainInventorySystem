from __future__ import annotations

import base64
import binascii
import hashlib
import json
from datetime import UTC, datetime
from typing import Any

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.exceptions import AppError
from app.db import repositories
from app.db.models import ChainBlock, PendingTransaction
from app.services.cache_service import inventory_cache


class DistributedReject(AppError):
    def __init__(self, message: str, status_code: int = 400):
        super().__init__("DISTRIBUTED_REJECT", message, status_code)


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _transaction_id(transaction: dict[str, Any]) -> str:
    value = transaction.get("tx_id", transaction.get("TransID"))
    if not isinstance(value, str) or not value.strip():
        raise DistributedReject("Transaction is missing a valid TransID")
    return value


def _verify_transaction_signature(transaction: dict[str, Any]) -> None:
    public_key_text = transaction.get("pub_key")
    signature_text = transaction.get("signature")
    if not isinstance(public_key_text, str) or not isinstance(signature_text, str):
        raise DistributedReject("Transaction is missing its public key or signature")

    unsigned_transaction = {key: value for key, value in transaction.items() if key != "signature"}
    try:
        public_key = Ed25519PublicKey.from_public_bytes(
            base64.b64decode(public_key_text, validate=True)
        )
        signature = base64.b64decode(signature_text, validate=True)
        public_key.verify(signature, canonical_json(unsigned_transaction))
    except (ValueError, binascii.Error, InvalidSignature) as exc:
        raise DistributedReject("Cryptographic signature is invalid") from exc


def _validate_transaction(transaction: Any) -> dict[str, Any]:
    if not isinstance(transaction, dict):
        raise DistributedReject("Each transaction must be an object")
    if transaction.get("flag") != "transaction":
        raise DistributedReject("Transaction flag must be 'transaction'")
    _transaction_id(transaction)
    _verify_transaction_signature(transaction)

    tx_type = transaction.get("tx_type")
    item_id = transaction.get("item_id")
    quantity = transaction.get("quantity")
    if tx_type not in {"inbound", "outbound"}:
        raise DistributedReject("Transaction type must be inbound or outbound")
    if not isinstance(item_id, str) or not item_id.strip():
        raise DistributedReject("Transaction item_id must not be empty")
    if isinstance(quantity, bool) or not isinstance(quantity, int) or quantity <= 0:
        raise DistributedReject("Transaction quantity must be a positive integer")
    for field in ("from_node", "location", "timestamp"):
        if not isinstance(transaction.get(field), str) or not transaction[field].strip():
            raise DistributedReject(f"Transaction {field} must not be empty")
    catalog = transaction.get("item_catalog", {})
    if not isinstance(catalog, dict):
        raise DistributedReject("Transaction item_catalog must be an object")
    if any(not isinstance(key, str) or not isinstance(value, dict) for key, value in catalog.items()):
        raise DistributedReject("Transaction item_catalog entries must be objects")
    return transaction


def _transactions_in_chain(db: Session) -> set[str]:
    ids: set[str] = set()
    for block in repositories.get_all_blocks(db):
        try:
            payload = json.loads(block.changes_json)
        except json.JSONDecodeError as exc:
            raise DistributedReject("Existing blockchain contains invalid transaction data", 500) from exc
        if not isinstance(payload, dict):
            continue
        transactions = payload if isinstance(payload, list) else payload.get("transactions", [])
        for transaction in transactions:
            if isinstance(transaction, dict):
                value = transaction.get("tx_id", transaction.get("TransID"))
                if isinstance(value, str):
                    ids.add(value)
    return ids


def _all_transaction_deltas(transactions: list[dict[str, Any]]) -> dict[str, int]:
    changes: dict[str, int] = {}
    for transaction in transactions:
        item_id = transaction["item_id"]
        quantity = transaction["quantity"]
        delta = quantity if transaction["tx_type"] == "inbound" else -quantity
        changes[item_id] = changes.get(item_id, 0) + delta
    return changes


def _catalog_for_transactions(transactions: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    catalog: dict[str, dict[str, Any]] = {}
    for transaction in transactions:
        tx_catalog = transaction.get("item_catalog", {})
        item_id = transaction["item_id"]
        if item_id in tx_catalog:
            catalog[item_id] = tx_catalog[item_id]
    return catalog


def _validate_inventory_transition(
    transactions: list[dict[str, Any]],
) -> tuple[dict[str, int], dict[str, dict[str, Any]]]:
    changes = _all_transaction_deltas(transactions)
    catalog = _catalog_for_transactions(transactions)
    balances = {
        item_id: item.get("quantity", 0)
        for item_id, item in inventory_cache.items.items()
    }
    known_items = set(inventory_cache.items)
    for transaction in transactions:
        item_id = transaction["item_id"]
        quantity = transaction["quantity"]
        if item_id not in known_items and transaction["tx_type"] != "inbound":
            raise DistributedReject(f"Unknown item {item_id} can only be added by inbound transactions", 422)
        if transaction["tx_type"] == "inbound":
            if item_id not in known_items:
                metadata = transaction.get("item_catalog", {}).get(item_id)
                if not metadata:
                    raise DistributedReject(f"Missing item metadata for new item {item_id}")
                if not all(metadata.get(field) for field in ("itemName", "brand", "category")):
                    raise DistributedReject(
                        f"New item {item_id} requires itemName, brand, and category"
                    )
            known_items.add(item_id)
            balances[item_id] = balances.get(item_id, 0) + quantity
        else:
            available = balances.get(item_id, 0)
            if available < quantity:
                raise DistributedReject(
                    f"Transaction would make {item_id} inventory negative",
                    422,
                )
            balances[item_id] = available - quantity

    for item_id, delta in changes.items():
        if item_id not in inventory_cache.items and delta <= 0:
            raise DistributedReject(
                f"New item {item_id} must have a positive ending quantity",
                422,
            )
    inventory_cache.simulate_changes(changes, catalog)
    return changes, catalog


def _order_transactions(transactions: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(
        transactions,
        key=lambda transaction: (
            transaction["tx_type"] != "inbound",
            _transaction_id(transaction),
        ),
    )


def submit_transaction(db: Session, transaction: dict[str, Any]) -> dict[str, Any]:
    normalized = _validate_transaction(transaction)
    tx_id = _transaction_id(normalized)
    if tx_id in _transactions_in_chain(db):
        raise DistributedReject(f"Transaction {tx_id} already exists in the blockchain")

    serialized = canonical_json(normalized).decode("utf-8")
    existing = repositories.get_pending_transaction(db, tx_id)
    if existing is not None:
        if existing.transaction_json != serialized:
            raise DistributedReject(f"Transaction ID {tx_id} is already used")
        return {"tx_id": tx_id, "status": existing.status, "duplicate": True}

    pending = _order_transactions(
        [json.loads(row.transaction_json) for row in repositories.get_pending_transactions(db)]
    )
    pending.append(normalized)
    _validate_inventory_transition(_order_transactions(pending))
    db.add(PendingTransaction(tx_id=tx_id, transaction_json=serialized, status="pending"))
    db.commit()
    return {"tx_id": tx_id, "status": "pending", "duplicate": False}


def _proposal_hash_payload(block: dict[str, Any]) -> dict[str, Any]:
    return {
        "height": block["height"],
        "prev_block_hash": block["prev_block_hash"],
        "transactions": block["transactions"],
    }


def _compute_block_hash(block: dict[str, Any]) -> str:
    return hashlib.sha256(canonical_json(_proposal_hash_payload(block))).hexdigest()


def build_proposal(db: Session, round_number: int) -> dict[str, Any]:
    pending = repositories.get_pending_transactions(db)
    if not pending:
        return {"block": None}

    latest = repositories.get_latest_block(db)
    transactions = _order_transactions([json.loads(row.transaction_json) for row in pending])
    block: dict[str, Any] = {
        "height": (latest.n_block + 1) if latest else 1,
        "round": round_number,
        "prev_block_hash": latest.block_hash if latest else None,
        "transactions": transactions,
    }
    block["block_hash"] = _compute_block_hash(block)
    return {"block": block}


def _configured_validator_keys() -> dict[str, str]:
    configured = settings.validator_public_keys
    if isinstance(configured, str):
        try:
            configured = json.loads(configured)
        except json.JSONDecodeError as exc:
            raise DistributedReject("Validator public-key configuration is invalid", 500) from exc
    if not isinstance(configured, dict):
        raise DistributedReject("Validator public-key configuration must be an object", 500)
    return configured


def _verify_votes(block: dict[str, Any], votes: Any) -> list[dict[str, Any]]:
    if not isinstance(votes, list):
        raise DistributedReject("Validator votes must be a list")
    public_keys = _configured_validator_keys()
    valid_votes: list[dict[str, Any]] = []
    seen: set[str] = set()
    for vote in votes:
        if not isinstance(vote, dict):
            raise DistributedReject("Each validator vote must be an object")
        validator_id = vote.get("validator_id")
        if not isinstance(validator_id, str) or validator_id not in public_keys:
            raise DistributedReject("Validator vote is from an unknown validator")
        if validator_id in seen:
            continue
        vote_height = vote.get("height")
        vote_round = vote.get("round")
        if (
            isinstance(vote_height, bool)
            or not isinstance(vote_height, int)
            or isinstance(vote_round, bool)
            or not isinstance(vote_round, int)
        ):
            raise DistributedReject("Validator vote height and round must be integers")
        if (
            vote_height != block["height"]
            or vote_round != block["round"]
            or vote.get("block_hash") != block["block_hash"]
        ):
            raise DistributedReject("Validator vote does not match the proposed block")
        signature_text = vote.get("signature")
        if not isinstance(signature_text, str):
            raise DistributedReject("Validator vote is missing its signature")
        vote_payload = {
            "height": vote_height,
            "round": vote_round,
            "block_hash": vote["block_hash"],
            "validator_id": validator_id,
        }
        try:
            key_bytes = base64.b64decode(public_keys[validator_id], validate=True)
            signature = base64.b64decode(signature_text, validate=True)
            Ed25519PublicKey.from_public_bytes(key_bytes).verify(
                signature, canonical_json(vote_payload)
            )
        except (ValueError, TypeError, binascii.Error, InvalidSignature) as exc:
            raise DistributedReject(f"Validator signature is invalid for {validator_id}") from exc
        seen.add(validator_id)
        valid_votes.append(
            {
                **vote_payload,
                "signature": signature_text,
            }
        )

    if len(valid_votes) < 3:
        raise DistributedReject("At least 3 distinct valid validator votes are required")
    return valid_votes


def _validate_proposal(
    db: Session,
    block: Any,
    votes: Any,
) -> tuple[dict[str, Any], list[dict[str, Any]], dict[str, int], dict[str, dict[str, Any]]]:
    if not isinstance(block, dict):
        raise DistributedReject("Proposed block must be an object")
    height = block.get("height")
    round_number = block.get("round")
    transactions = block.get("transactions")
    if isinstance(height, bool) or not isinstance(height, int) or height < 1:
        raise DistributedReject("Proposed block height must be a positive integer")
    if isinstance(round_number, bool) or not isinstance(round_number, int) or round_number < 0:
        raise DistributedReject("Proposed block round must be a non-negative integer")
    if not isinstance(transactions, list) or not transactions:
        raise DistributedReject("Proposed block must contain transactions")
    if "prev_block_hash" not in block:
        raise DistributedReject("Proposed block is missing prev_block_hash")

    latest = repositories.get_latest_block(db)
    expected_height = (latest.n_block + 1) if latest else 1
    expected_prev_hash = latest.block_hash if latest else None
    if height != expected_height:
        raise DistributedReject(
            f"Proposed block height must be {expected_height}, not {height}",
            409,
        )
    if block.get("prev_block_hash") != expected_prev_hash:
        raise DistributedReject("Proposed block prev_block_hash does not match the chain head", 409)

    validated_transactions = [_validate_transaction(tx) for tx in transactions]
    tx_ids = [_transaction_id(tx) for tx in validated_transactions]
    if len(tx_ids) != len(set(tx_ids)):
        raise DistributedReject("Proposed block contains duplicate transaction IDs")
    if set(tx_ids) & _transactions_in_chain(db):
        raise DistributedReject("Proposed block contains a transaction ID already in the blockchain")

    computed_hash = _compute_block_hash(block)
    if block.get("block_hash") != computed_hash:
        raise DistributedReject("Proposed block hash is invalid")
    valid_votes = _verify_votes(block, votes)
    changes, catalog = _validate_inventory_transition(validated_transactions)
    return block, valid_votes, changes, catalog


def _store_block(
    db: Session,
    block: dict[str, Any],
    votes: list[dict[str, Any]],
    changes: dict[str, int],
    catalog: dict[str, dict[str, Any]],
) -> None:
    transaction_ids = {_transaction_id(tx) for tx in block["transactions"]}
    row = ChainBlock(
        n_block=block["height"],
        prev_block_hash=block["prev_block_hash"],
        block_hash=block["block_hash"],
        datetime=datetime.now(UTC).isoformat(),
        changes_json=json.dumps(
            {
                "changes": changes,
                "item_catalog": catalog,
                "transactions": block["transactions"],
            },
            sort_keys=True,
        ),
        author_email=str(block.get("proposer", "distributed-node")),
        author_sign=None,
        server_sign="validator-quorum",
    )
    db.add(row)
    db.flush()
    for vote in votes:
        repositories.add_block_vote(
            db,
            height=block["height"],
            round_number=block["round"],
            block_hash=block["block_hash"],
            validator_id=vote["validator_id"],
            signature=vote["signature"],
        )

    for tx_id in transaction_ids:
        pending = repositories.get_pending_transaction(db, tx_id)
        if pending is not None:
            pending.status = "finalized"
    db.commit()
    inventory_cache.apply_changes(changes, block["block_hash"], block["height"], catalog)


def commit_block(db: Session, block: dict[str, Any], votes: list[dict[str, Any]]) -> dict[str, Any]:
    validated_block, valid_votes, changes, catalog = _validate_proposal(db, block, votes)
    _store_block(db, validated_block, valid_votes, changes, catalog)
    return {
        "height": validated_block["height"],
        "block_hash": validated_block["block_hash"],
        "votes": valid_votes,
    }


def import_block(
    db: Session,
    block: dict[str, Any],
    votes: list[dict[str, Any]],
) -> dict[str, Any]:
    return commit_block(db, block, votes)


def chain_from(db: Session, from_height: int) -> dict[str, Any]:
    blocks = []
    for row in repositories.get_all_blocks(db):
        if row.n_block < from_height:
            continue
        raw_payload = json.loads(row.changes_json)
        votes = repositories.get_block_votes_for_hash(db, row.block_hash)
        blocks.append(
            {
                "block": {
                    "height": row.n_block,
                    "round": votes[0].round if votes else 0,
                    "prev_block_hash": row.prev_block_hash,
                    "transactions": raw_payload.get("transactions", []),
                    "block_hash": row.block_hash,
                },
                "votes": [
                    {
                        "height": vote.height,
                        "round": vote.round,
                        "block_hash": vote.block_hash,
                        "validator_id": vote.validator_id,
                        "signature": vote.signature,
                    }
                    for vote in votes
                ],
            }
        )
    return {"blocks": blocks}


def transaction_status(db: Session, tx_id: str) -> dict[str, Any]:
    pending = repositories.get_pending_transaction(db, tx_id)
    if pending is not None:
        return {"tx_id": tx_id, "status": pending.status}
    if tx_id in _transactions_in_chain(db):
        return {"tx_id": tx_id, "status": "finalized"}
    return {"tx_id": tx_id, "status": "unknown"}
