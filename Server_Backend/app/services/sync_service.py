import json

from sqlalchemy.orm import Session

from app.db import repositories
from app.services.cache_service import inventory_cache


def serialize_block(block) -> dict:
    raw_payload = json.loads(block.changes_json)
    if isinstance(raw_payload, dict) and "changes" in raw_payload:
        changes = raw_payload.get("changes", {})
        item_catalog = raw_payload.get("item_catalog", {})
    else:
        changes = raw_payload
        item_catalog = {}

    return {
        "n_block": block.n_block,
        "prev_block_hash": block.prev_block_hash,
        "block_hash": block.block_hash,
        "datetime": block.datetime,
        "changes": changes,
        "item_catalog": item_catalog,
        "author_email": block.author_email,
        "author_sign": block.author_sign,
        "server_sign": block.server_sign,
    }


def check_chain_sync(db: Session, client_block_hash: str | None) -> dict:
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
            "missing_blocks": [serialize_block(row) for row in missing],
            "inventory": inventory,
            "last_hash": latest.block_hash,
        }

    all_blocks = repositories.get_all_blocks(db)
    return {
        "synced": False,
        "from_hash": None,
        "missing_blocks": [serialize_block(row) for row in all_blocks],
        "inventory": inventory,
        "last_hash": latest.block_hash,
    }
