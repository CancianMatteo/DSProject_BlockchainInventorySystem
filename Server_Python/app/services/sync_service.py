import json

from sqlalchemy.orm import Session

from app.db import repositories
from app.services.cache_service import inventory_cache


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

    serialized = {
        "n_block": block.n_block,
        "prev_block_hash": block.prev_block_hash,
        "block_hash": block.block_hash,
        "datetime": block.datetime,
        "changes": changes,
        "item_catalog": item_catalog,
        "author_email": block.author_email,
        "author_sign": block.author_sign,
        "server_sign": None if block.server_sign == "validator-quorum" else block.server_sign,
        "transactions": transactions,
        "votes": [
            {
                "height": vote.height,
                "round": vote.round,
                "block_hash": vote.block_hash,
                "validator_id": vote.validator_id,
                "signature": vote.signature,
                "phase": vote.phase,
            }
            for vote in repositories.get_block_votes_for_hash(db, block.block_hash)
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
