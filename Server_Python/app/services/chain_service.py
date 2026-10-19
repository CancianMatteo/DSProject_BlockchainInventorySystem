from __future__ import annotations

import hashlib
from datetime import UTC, datetime

from sqlalchemy.orm import Session

from app.core.exceptions import AppError
from app.core.security import canonical_block_payload, sign_block_payload
from app.db import repositories
from app.services import auth_service
from app.services.cache_service import inventory_cache


def _compute_block_hash(payload: dict) -> str:
    return hashlib.sha256(canonical_block_payload(payload)).hexdigest()


def add_block(
    db: Session,
    *,
    session_token: str,
    prev_block_hash: str | None,
    changes: dict[str, int],
    item_catalog: dict[str, dict[str, str | None]],
    author_sign: str | None,
) -> dict:
    normalized_prev_hash = prev_block_hash
    if normalized_prev_hash in (None, "", "0"):
        normalized_prev_hash = None

    payload = auth_service.validate_token(db, session_token)
    author_email = payload.get("sub")
    if not author_email:
        raise AppError("TOKEN_INVALID", "Invalid session token", status_code=401)

    if not changes:
        raise AppError("INVALID_REQUEST", "changes cannot be empty", status_code=400)

    # Validate metadata for new items and keep contract strict.
    current_items = dict(inventory_cache.items)
    for item_id, delta in changes.items():
        if item_id not in current_items and delta > 0:
            metadata = item_catalog.get(item_id)
            if metadata is None:
                raise AppError(
                    "MISSING_ITEM_METADATA",
                    f"Missing metadata for new item '{item_id}'",
                    status_code=400,
                )
            if not metadata.get("itemName") or not metadata.get("brand") or not metadata.get("category"):
                raise AppError(
                    "INVALID_ITEM_METADATA",
                    "New items require itemName, brand and category",
                    status_code=400,
                )

    latest = repositories.get_latest_block(db)
    expected_prev = latest.block_hash if latest else None
    if expected_prev != normalized_prev_hash:
        raise AppError("CHAIN_HEAD_MISMATCH", "Client chain is stale", status_code=409)

    inventory_cache.simulate_changes(changes, item_catalog)

    n_block = (latest.n_block + 1) if latest else 1
    timestamp = datetime.now(UTC).isoformat()

    unsigned_payload = {
        "n_block": n_block,
        "prev_block_hash": normalized_prev_hash,
        "datetime": timestamp,
        "changes": changes,
        "item_catalog": item_catalog,
        "author_email": author_email,
        "author_sign": author_sign,
    }
    block_hash = _compute_block_hash(unsigned_payload)

    signed_payload = {**unsigned_payload, "block_hash": block_hash}
    server_sign = sign_block_payload(signed_payload)

    repositories.insert_block(
        db,
        n_block=n_block,
        prev_block_hash=normalized_prev_hash,
        block_hash=block_hash,
        timestamp=timestamp,
        changes={"changes": changes, "item_catalog": item_catalog},
        author_email=author_email,
        author_sign=author_sign,
        server_sign=server_sign,
    )

    db.commit()

    inventory_cache.apply_changes(changes, block_hash, n_block, item_catalog)
    return {"block_hash": block_hash, "n_block": n_block, "new_head_hash": block_hash}
