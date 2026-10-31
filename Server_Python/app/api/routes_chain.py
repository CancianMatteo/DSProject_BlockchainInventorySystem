from fastapi import APIRouter, Depends, Query
from fastapi.params import Query as QueryParam
from sqlalchemy.orm import Session

from app.api.schemas import (
    AddTransactionRequest,
    CheckChainSyncRequest,
    TransactionStatusRequest,
)
from app.db import repositories
from app.db.session import get_db
from app.services import auth_service, distributed_service, sync_service

router = APIRouter(prefix="/chain", tags=["chain"])


@router.get("/history")
def get_chain_history(
    limit: int = Query(default=50, ge=1, le=100),
    before_n_block: int | None = Query(default=None, ge=1),
    db: Session = Depends(get_db),
):
    # Support direct calls (such as unit tests), where defaults are Query(...).
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


@router.post("/blockchain_sync")
def blockchain_sync(payload: CheckChainSyncRequest, db: Session = Depends(get_db)):
    data = sync_service.blockchain_sync(db, payload.client_block_hash)
    return {"ok": True, **data}


@router.post("/add_transaction", status_code=202)
def add_transaction(
    payload: AddTransactionRequest,
    db: Session = Depends(get_db),
):
    token = auth_service.validate_token(db, payload.session_token)
    author_email = token.get("sub")
    if not author_email:
        raise distributed_service.DistributedReject(
            "Invalid session token",
            status_code=401,
        )

    transaction = dict(payload.transaction)
    if transaction.get("client_ID", transaction.get("from_node")) != author_email:
        raise distributed_service.DistributedReject(
            "Transaction origin does not match the authenticated user",
            status_code=403,
        )

    result = distributed_service.submit_transaction(db, transaction)
    forwarding = distributed_service.queue_transaction_forwarding(db, transaction)
    distributed_service.trigger_block_if_ready(db)
    return {
        "ok": True,
        **result,
        "forwarding_status": forwarding,
        "confirm_pending_trans": result["status"] == "pending",
    }


@router.post("/transaction_status")
def get_transaction_status(
    payload: TransactionStatusRequest,
    db: Session = Depends(get_db),
):
    token = auth_service.validate_token(db, payload.session_token)
    if not token.get("sub"):
        raise distributed_service.DistributedReject(
            "Invalid session token",
            status_code=401,
        )

    result = distributed_service.transaction_status(db, payload.trans_id)
    return {
        "ok": True,
        **result,
        "forwarding_status": distributed_service.forwarding_status(db, payload.trans_id),
        "confirm_block_creation_for_trans": result["status"] == "finalized",
    }


@router.get("/forwarding_monitor")
def get_forwarding_monitor(db: Session = Depends(get_db)):
    return {"ok": True, **distributed_service.forwarding_monitor(db)}
