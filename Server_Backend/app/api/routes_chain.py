from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.api.schemas import AddBlockRequest, CheckChainSyncRequest
from app.db.session import get_db
from app.services import chain_service, sync_service

router = APIRouter(prefix="/chain", tags=["chain"])


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
