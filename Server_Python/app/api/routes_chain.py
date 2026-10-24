from fastapi import APIRouter, Depends, Query
from fastapi.params import Query as QueryParam
from sqlalchemy.orm import Session

from app.api.schemas import AddBlockRequest, CheckChainSyncRequest
from app.db import repositories
from app.db.session import get_db
from app.services import chain_service, sync_service

router = APIRouter(prefix="/chain", tags=["chain"])


@router.get("/history")
def get_chain_history(
    limit: int = Query(default=50, ge=1, le=100),
    before_n_block: int | None = Query(default=None, ge=1),
    db: Session = Depends(get_db),
):
    # Supporta la chiamata diretta (test/unità) in cui i default sono Query(...).
    if isinstance(limit, QueryParam):
        limit = limit.default
    if isinstance(before_n_block, QueryParam):
        before_n_block = before_n_block.default
    rows = repositories.get_recent_blocks(
        db,
        limit=limit + 1,
        before_n_block=before_n_block,
    )
    has_more = len(rows) > limit
    blocks = rows[:limit]
    return {
        "ok": True,
        "blocks": [sync_service.serialize_block(db, block) for block in blocks],
        "has_more": has_more,
        "next_before_n_block": blocks[-1].n_block if has_more else None,
    }


@router.post("/check_chain_sync")
def check_chain_sync(payload: CheckChainSyncRequest, db: Session = Depends(get_db)):
    data = sync_service.check_chain_sync(db, payload.client_block_hash)
    return {"ok": True, **data}


@router.post("/add_block", status_code=201)
def add_block(payload: AddBlockRequest, db: Session = Depends(get_db)):
    data = chain_service.add_block(
        db,
        session_token=payload.session_token,
        prev_block_hash=payload.prev_block_hash,
        changes=payload.changes,
        item_catalog=payload.item_catalog,
        author_sign=payload.author_sign,
    )
    return {"ok": True, **data}
