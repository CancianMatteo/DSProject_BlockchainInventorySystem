import json

from sqlalchemy.orm import Session

from app.core.config import settings
from app.db import repositories
from app.services.cache_service import inventory_cache


def _fallback_proposer_id(block_number: int) -> str:
    try:
        validators = json.loads(settings.validator_public_keys)
    except (TypeError, json.JSONDecodeError):
        validators = {}
    if not isinstance(validators, dict) or not validators:
        return "distributed-node"
    ordered = sorted(str(node_id) for node_id in validators)
    return ordered[block_number % len(ordered)]


def serialize_block(db: Session, block) -> dict:
    raw_payload = json.loads(block.changes_json)
    if isinstance(raw_payload, dict) and "changes" in raw_payload:
        changes = raw_payload.get("changes", {})
        item_catalog = raw_payload.get("item_catalog", {})
        transactions = raw_payload.get("transactions", [])
    else:
        changes = raw_payload
        item_catalog = {}
        transactions = []
    proposer_id = (
        raw_payload.get("proposer_id")
        or (
            block.author_email
            if block.author_email != "distributed-node"
            else _fallback_proposer_id(block.n_block)
        )
    )
    proposer_signature = raw_payload.get("proposer_signature") or block.author_sign
    votes = repositories.get_block_votes_for_hash(db, block.block_hash)
    raw_validator_signatures = raw_payload.get("validator_signatures", {})
    commit_signatures = (
        raw_validator_signatures.get("commit")
        if isinstance(raw_validator_signatures, dict)
        else None
    )
    if not isinstance(commit_signatures, dict) or not commit_signatures:
        commit_signatures = {vote.validator_id: vote.signature for vote in votes}
    validator_signatures = {"commit": commit_signatures} if commit_signatures else {}

    serialized = {
        "n_block": block.n_block,
        "prev_block_hash": block.prev_block_hash,
        "block_hash": block.block_hash,
        "datetime": block.datetime,
        "changes": changes,
        "item_catalog": item_catalog,
        "author_email": proposer_id,
        "author_sign": proposer_signature,
        "proposer_id": proposer_id,
        "proposer_signature": proposer_signature,
        "validator_signatures": validator_signatures,
        "server_sign": None,
        "transactions": transactions,
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
    return serialized


def blockchain_sync(db: Session, client_block_hash: str | None) -> dict:
    normalized_client_hash = client_block_hash
    if normalized_client_hash in (None, "", "0"):
        normalized_client_hash = None

    latest = repositories.get_latest_block(db)
    if latest is None:
        return {"synced": True, "missing_blocks": [], "inventory": [], "last_hash": None}

    inventory = inventory_cache.get_inventory_list()

    if latest.block_hash == normalized_client_hash:
        return {
            "synced": True,
            "missing_blocks": [],
            "inventory": inventory,
            "last_hash": latest.block_hash,
        }

    if normalized_client_hash is None:
        matched = None
    else:
        matched = repositories.get_block_by_hash(db, normalized_client_hash)
    if matched:
        missing = repositories.get_blocks_after_n(db, matched.n_block)
        return {
            "synced": False,
            "from_hash": matched.block_hash,
            "missing_blocks": [serialize_block(db, row) for row in missing],
            "inventory": inventory,
            "last_hash": latest.block_hash,
        }

    all_blocks = repositories.get_all_blocks(db)
    return {
        "synced": False,
        "from_hash": None,
        "missing_blocks": [serialize_block(db, row) for row in all_blocks],
        "inventory": inventory,
        "last_hash": latest.block_hash,
    }
