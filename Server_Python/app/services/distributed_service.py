from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
from datetime import UTC, datetime
from typing import Any
from uuid import uuid4

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.exceptions import AppError
from app.db import repositories
from app.db.models import ChainBlock, PendingTransaction
from app.services import simbehaviour_service
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
    return {**peer_public_keys, **configured}


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


# ---------------------------------------------------------------------------
# Elixir <-> Python bridge: firma/verifica e operazioni con il motore di
# consenso (dispatched by "flag" dall'endpoint /api/v1/python_call).
# ---------------------------------------------------------------------------

# Chiavi pubbliche dei peer ricevute via setup_keys_warning (registro volatile).
peer_public_keys: dict[str, str] = {}
_BYZANTINE_SCENARIOS = {
    "invalid_signature",
    "split_brain",
    "equivocation",
    "leader_offline",
}


def _byzantine_scenario() -> str:
    scenario = os.getenv("BIZANTINE_SCENARIO", "invalid_signature")
    if scenario not in _BYZANTINE_SCENARIOS:
        raise DistributedReject(f"Unsupported BIZANTINE_SCENARIO: {scenario}", 500)
    return scenario


def _forge_signature(content: dict[str, Any]) -> str:
    """Produce a well-formed but invalid signature (byzantine behaviour).

    A fresh random key signs the payload so honest nodes fail verification
    against the registered validator key.
    """
    decoy = Ed25519PrivateKey.generate()
    return base64.b64encode(decoy.sign(canonical_json(content))).decode("ascii")


def _spoof_transaction(base: dict[str, Any], node_id: str) -> dict[str, Any]:
    """Forge a fake transaction that honest nodes will reject."""
    forged = {
        **base,
        "flag": "transaction",
        "from_node": base.get("from_node") or node_id,
        "tx_type": base.get("tx_type") or "inbound",
        "item_id": base.get("item_id") or "spoofed-item",
        "quantity": base.get("quantity") or 1,
        "location": base.get("location") or "spoofed-warehouse",
        "timestamp": base.get("timestamp") or datetime.now(UTC).isoformat(),
        "tx_id": base.get("tx_id") or f"spoofed-{uuid4().hex}",
        "pub_key": base.get("pub_key") or "",
        "item_catalog": base.get("item_catalog") or {},
    }
    forged.pop("signature", None)
    forged["signature"] = base64.b64encode(os.urandom(64)).decode("ascii")
    return forged


def local_public_key() -> str:
    if (
        simbehaviour_service.is_byzantine()
        and _byzantine_scenario() == "invalid_signature"
    ):
        # Advertise an unrelated key so honest nodes cannot match this node
        # to its registered validator identity.
        decoy = Ed25519PrivateKey.generate()
        return base64.b64encode(
            decoy.public_key().public_bytes(
                serialization.Encoding.Raw,
                serialization.PublicFormat.Raw,
            )
        ).decode("ascii")
    public_keys = _configured_validator_keys()
    public_key = public_keys.get(settings.node_id)
    if not isinstance(public_key, str) or not public_key:
        raise DistributedReject(
            f"No validator public key configured for node {settings.node_id}", 500
        )
    return public_key


def register_peer_public_key(from_node: Any, public_key: Any) -> None:
    if not isinstance(from_node, str) or not from_node.strip():
        raise DistributedReject("Peer node id must not be empty")
    if not isinstance(public_key, str) or not public_key.strip():
        raise DistributedReject("Peer public key must not be empty")
    try:
        base64.b64decode(public_key, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise DistributedReject("Peer public key must be base64 encoded") from exc
    peer_public_keys[from_node] = public_key


def _validator_private_key() -> Ed25519PrivateKey:
    raw = settings.validator_private_key
    if not raw:
        raise DistributedReject("Validator private key is not configured", 500)
    try:
        key_bytes = base64.b64decode(raw, validate=True)
        return Ed25519PrivateKey.from_private_bytes(key_bytes)
    except (ValueError, TypeError, binascii.Error) as exc:
        raise DistributedReject("Validator private key is invalid", 500) from exc


def sign_payload(content: dict[str, Any]) -> str:
    if (
        simbehaviour_service.is_byzantine()
        and _byzantine_scenario() == "invalid_signature"
    ):
        return _forge_signature(content)
    signature = _validator_private_key().sign(canonical_json(content))
    return base64.b64encode(signature).decode("ascii")


def verify_validator_signature(
    validator_id: Any,
    content: dict[str, Any],
    signature_text: Any,
) -> bool:
    if not isinstance(validator_id, str) or not isinstance(signature_text, str):
        return False
    public_keys = _configured_validator_keys()
    if validator_id not in public_keys:
        return False
    try:
        public_key = Ed25519PublicKey.from_public_bytes(
            base64.b64decode(public_keys[validator_id], validate=True)
        )
        signature = base64.b64decode(signature_text, validate=True)
        public_key.verify(signature, canonical_json(content))
        return True
    except (ValueError, TypeError, binascii.Error, InvalidSignature):
        return False


# --- Proposta di blocco (PRE-PREPARE) ---------------------------------------

def _proposal_signature_payload(
    height: Any,
    round_number: Any,
    proposer_id: Any,
    block_hash: Any,
) -> dict[str, Any]:
    return {
        "height": height,
        "round": round_number,
        "proposer_id": proposer_id,
        "block_hash": block_hash,
    }


def prepare_proposal(db: Session, round_number: int) -> dict[str, Any]:
    block = build_proposal(db, round_number).get("block")
    if not block:
        # Nessuna transazione in mempool: il motore Elixir registra un warning.
        return {"flag": "prepare_block", "block_data": None}
    if (
        simbehaviour_service.is_byzantine()
        and _byzantine_scenario() == "invalid_signature"
    ):
        # Tamper the proposal while keeping the original (valid) signature:
        # honest nodes recompute the hash and reject the block.
        tampered = dict(block)
        transactions = list(tampered.get("transactions") or [])
        if transactions and isinstance(transactions[0], dict):
            first = dict(transactions[0])
            quantity = first.get("quantity")
            if isinstance(quantity, int) and not isinstance(quantity, bool):
                first["quantity"] = quantity + 1
            else:
                first["quantity"] = 999999
            transactions[0] = first
            tampered["transactions"] = transactions
        else:
            tampered["transactions"] = [
                _spoof_transaction({}, settings.node_id),
            ]
        content = _proposal_signature_payload(
            block["height"], block["round"], settings.node_id, block["block_hash"]
        )
        return {
            "flag": "prepare_block",
            "block_data": tampered,
            "proposer_sign": sign_payload(content),
        }

    content = _proposal_signature_payload(
        block["height"], block["round"], settings.node_id, block["block_hash"]
    )
    proposal = {
        "flag": "prepare_block",
        "block_data": block,
        "proposer_sign": sign_payload(content),
    }

    if (
        simbehaviour_service.is_byzantine()
        and _byzantine_scenario() == "equivocation"
    ):
        if len(block["transactions"]) < 2:
            raise DistributedReject(
                "The equivocation scenario requires at least two pending transactions"
            )

        alternate = dict(block)
        alternate["transactions"] = list(block["transactions"][:-1])
        alternate["block_hash"] = _compute_block_hash(alternate)
        alternate_content = _proposal_signature_payload(
            alternate["height"],
            alternate["round"],
            settings.node_id,
            alternate["block_hash"],
        )
        proposal["equivocation_block_data"] = alternate
        proposal["equivocation_sign"] = sign_payload(alternate_content)

    return proposal


def verify_pre_prepare(payload: dict[str, Any]) -> bool:
    block = payload.get("block_data")
    proposer_id = payload.get("proposer_id")
    height = payload.get("height")
    round_number = payload.get("round")
    if (
        not isinstance(block, dict)
        or isinstance(height, bool)
        or not isinstance(height, int)
        or isinstance(round_number, bool)
        or not isinstance(round_number, int)
    ):
        return False

    public_keys = _configured_validator_keys()
    if not isinstance(proposer_id, str) or proposer_id not in public_keys:
        return False

    # Proposer deterministico: (height + round) mod numero di validatori,
    # con i validatori ordinati come il motore Elixir (Enum.sort).
    validators = sorted(public_keys)
    if proposer_id != validators[(height + round_number) % len(validators)]:
        return False

    if block.get("height") != height or block.get("round") != round_number:
        return False
    if not isinstance(block.get("block_hash"), str) or _compute_block_hash(block) != block["block_hash"]:
        return False

    content = _proposal_signature_payload(height, round_number, proposer_id, block["block_hash"])
    return verify_validator_signature(proposer_id, content, payload.get("signature"))


def _conflict_accusation_content(
    height: Any,
    round_number: Any,
    validator_id: Any,
    forged_block_hash: Any,
    conflicting_block_hash: Any,
) -> dict[str, Any]:
    return {
        "flag": "pre_prepare_conflict",
        "height": height,
        "round": round_number,
        "validator_id": validator_id,
        "hash_1": forged_block_hash,
        "hash_2": conflicting_block_hash,
    }


def create_pre_prepare_conflict_proof(payload: dict[str, Any]) -> dict[str, Any] | None:
    """Sign a compact proof that a proposer signed two different block hashes."""
    height = payload.get("height")
    round_number = payload.get("round")
    proposer_id = payload.get("proposer_id")
    validator_id = payload.get("validator_id")
    forged_hash = payload.get("forged_block_hash")
    conflicting_hash = payload.get("conflicting_block_hash")
    if (
        isinstance(height, bool)
        or not isinstance(height, int)
        or height < 1
        or isinstance(round_number, bool)
        or not isinstance(round_number, int)
        or round_number < 0
        or validator_id != settings.node_id
        or not isinstance(forged_hash, str)
        or not isinstance(conflicting_hash, str)
        or forged_hash == conflicting_hash
    ):
        return None

    validators = sorted(_configured_validator_keys())
    if not validators or proposer_id != validators[(height + round_number) % len(validators)]:
        return None

    forged_content = _proposal_signature_payload(height, round_number, proposer_id, forged_hash)
    conflicting_content = _proposal_signature_payload(
        height, round_number, proposer_id, conflicting_hash
    )
    if not verify_validator_signature(proposer_id, forged_content, payload.get("forged_signature")):
        return None
    if not verify_validator_signature(
        proposer_id, conflicting_content, payload.get("conflicting_signature")
    ):
        return None

    accusation = _conflict_accusation_content(
        height, round_number, validator_id, forged_hash, conflicting_hash
    )
    return {
        "flag": "pre_prepare_conflict_proof",
        "height": height,
        "round": round_number,
        "proposer_id": proposer_id,
        "validator_id": validator_id,
        "forged_block_hash": forged_hash,
        "forged_signature": payload["forged_signature"],
        "conflicting_block_hash": conflicting_hash,
        "conflicting_signature": payload["conflicting_signature"],
        "validator_signature": sign_payload(accusation),
    }


def verify_pre_prepare_conflict_proof(payload: dict[str, Any]) -> bool:
    height = payload.get("height")
    round_number = payload.get("round")
    proposer_id = payload.get("proposer_id")
    validator_id = payload.get("validator_id")
    forged_hash = payload.get("forged_block_hash")
    conflicting_hash = payload.get("conflicting_block_hash")
    target_round = payload.get("target_round")
    if (
        isinstance(height, bool)
        or not isinstance(height, int)
        or height < 1
        or isinstance(round_number, bool)
        or not isinstance(round_number, int)
        or round_number < 0
        or target_round != round_number + 1
        or not isinstance(forged_hash, str)
        or not isinstance(conflicting_hash, str)
        or forged_hash == conflicting_hash
    ):
        return False

    validators = sorted(_configured_validator_keys())
    if not validators or proposer_id != validators[(height + round_number) % len(validators)]:
        return False

    forged_content = _proposal_signature_payload(height, round_number, proposer_id, forged_hash)
    conflicting_content = _proposal_signature_payload(
        height, round_number, proposer_id, conflicting_hash
    )
    if not verify_validator_signature(proposer_id, forged_content, payload.get("forged_signature")):
        return False
    if not verify_validator_signature(
        proposer_id, conflicting_content, payload.get("conflicting_signature")
    ):
        return False

    accusation = _conflict_accusation_content(
        height, round_number, validator_id, forged_hash, conflicting_hash
    )
    return verify_validator_signature(
        validator_id, accusation, payload.get("validator_signature")
    )


# --- Voti PREPARE / COMMIT ---------------------------------------------------

def _vote_signature_payload(
    phase: str,
    height: Any,
    round_number: Any,
    validator_id: Any,
    block_hash: Any = None,
) -> dict[str, Any]:
    content = {
        "phase": phase,
        "height": height,
        "round": round_number,
        "validator_id": validator_id,
    }
    if block_hash is not None:
        content["block_hash"] = block_hash
    return content


def sign_vote(phase: str, payload: dict[str, Any]) -> dict[str, Any]:
    block = payload.get("block_data")
    block_hash = (
        block.get("block_hash") if isinstance(block, dict) else payload.get("block_hash")
    )
    if phase == "prepare" and (
        not isinstance(block, dict)
        or not isinstance(block_hash, str)
        or block.get("height") != payload.get("height")
        or block.get("round") != payload.get("round")
        or _compute_block_hash(block) != block_hash
    ):
        raise DistributedReject("PREPARE vote requires a valid block matching its height and round")
    if phase == "commit" and (
        not isinstance(block_hash, str)
        or not block_hash
        or isinstance(payload.get("height"), bool)
        or not isinstance(payload.get("height"), int)
        or payload["height"] < 1
        or isinstance(payload.get("round"), bool)
        or not isinstance(payload.get("round"), int)
        or payload["round"] < 0
    ):
        raise DistributedReject("COMMIT vote requires height, round and block_hash")

    content = _vote_signature_payload(
        phase, payload.get("height"), payload.get("round"), settings.node_id, block_hash
    )
    return {"flag": payload.get("flag"), "signature": sign_payload(content)}


def verify_vote(phase: str, payload: dict[str, Any]) -> bool:
    height = payload.get("height")
    round_number = payload.get("round")
    if (
        isinstance(height, bool)
        or not isinstance(height, int)
        or height < 1
        or isinstance(round_number, bool)
        or not isinstance(round_number, int)
        or round_number < 0
    ):
        return False
    validator_id = payload.get("validator_id")
    block_hash = payload.get("block_hash")
    if phase in {"prepare", "commit"} and (
        not isinstance(block_hash, str) or not block_hash
    ):
        return False
    content = _vote_signature_payload(
        phase, height, round_number, validator_id, block_hash
    )
    return verify_validator_signature(validator_id, content, payload.get("signature"))


def verify_prepare_certificate(payload: dict[str, Any]) -> bool:
    block = payload.get("block_data")
    if not isinstance(block, dict) or not verify_pre_prepare(payload):
        return False

    signatures = payload.get("signatures")
    if not isinstance(signatures, list):
        return False

    validators = sorted(_configured_validator_keys())
    if not validators:
        return False
    quorum = 2 * ((len(validators) - 1) // 3) + 1
    seen: set[str] = set()
    valid_votes = 0
    for vote in signatures:
        if not isinstance(vote, dict):
            return False
        validator_id = vote.get("validator_id")
        if not isinstance(validator_id, str) or validator_id in seen:
            return False
        vote_payload = {
            "height": block.get("height"),
            "round": block.get("round"),
            "block_hash": block.get("block_hash"),
            "validator_id": validator_id,
            "signature": vote.get("signature"),
        }
        if not verify_vote("prepare", vote_payload):
            return False
        seen.add(validator_id)
        valid_votes += 1

    return valid_votes >= quorum


# --- ROUND CHANGE ------------------------------------------------------------

_ROUND_CHANGE_EXCLUDED_FIELDS = ("flag", "signature", "validator_signature")


def _round_change_content(payload: dict[str, Any]) -> dict[str, Any]:
    return {
        key: value
        for key, value in payload.items()
        if key not in _ROUND_CHANGE_EXCLUDED_FIELDS
    }


def sign_round_change(payload: dict[str, Any]) -> dict[str, Any]:
    content = _round_change_content(payload)
    content.setdefault("validator_id", settings.node_id)
    return {**payload, "signature": sign_payload(content)}


def verify_round_change(payload: dict[str, Any]) -> bool:
    height = payload.get("height")
    target_round = payload.get("target_round")
    if (
        isinstance(height, bool)
        or not isinstance(height, int)
        or isinstance(target_round, bool)
        or not isinstance(target_round, int)
    ):
        return False

    if "forged_block_hash" in payload or "conflicting_block_hash" in payload:
        return verify_pre_prepare_conflict_proof(payload)

    content = _round_change_content(payload)
    validator_id = content.get("validator_id")

    # Firma standard del round_change (path timeout).
    if verify_validator_signature(validator_id, content, payload.get("signature")):
        return True

    return False


# --- Scrittura del blocco confermato -----------------------------------------

def write_committed_block(db: Session, block: Any) -> dict[str, Any]:
    """Scrive un blocco già ratificato dal quorum PBFT (2f+1) dal motore Elixir."""
    if not isinstance(block, dict):
        raise DistributedReject("Committed block must be an object")
    height = block.get("height")
    if isinstance(height, bool) or not isinstance(height, int) or height < 1:
        raise DistributedReject("Committed block height must be a positive integer")
    transactions = block.get("transactions")
    if not isinstance(transactions, list) or not transactions:
        raise DistributedReject("Committed block must contain transactions")
    if not isinstance(block.get("block_hash"), str) or _compute_block_hash(block) != block["block_hash"]:
        raise DistributedReject("Committed block hash is invalid")

    latest = repositories.get_latest_block(db)
    if latest is not None and block["block_hash"] == latest.block_hash:
        return {"status": True, "duplicate": True}
    expected_height = (latest.n_block + 1) if latest else 1
    expected_prev_hash = latest.block_hash if latest else None
    if height != expected_height or block.get("prev_block_hash") != expected_prev_hash:
        raise DistributedReject("Committed block does not extend the current chain head", 409)

    validated = [_validate_transaction(tx) for tx in transactions]
    changes, catalog = _validate_inventory_transition(_order_transactions(validated))
    # L'elenco dei voti non è re-inoltrato: il quorum è già stato verificato
    # dal motore Elixir prima di richiedere la scrittura.
    _store_block(db, block, [], changes, catalog)
    return {"status": True}
