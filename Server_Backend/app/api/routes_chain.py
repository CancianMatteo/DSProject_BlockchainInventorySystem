from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.api.schemas import (
    AddBlockRequest,
    BuildProposalRequest,
    CheckChainSyncRequest,
    SubmitTransactionRequest,
)
from app.core.exceptions import AppError
from app.db.session import get_db
from app.services import distributed_service, sync_service

router = APIRouter(prefix="/chain", tags=["chain"])


@router.post("/check_chain_sync")
def check_chain_sync(payload: CheckChainSyncRequest, db: Session = Depends(get_db)):
    data = sync_service.check_chain_sync(db, payload.client_block_hash)
    return {"ok": True, **data}


@router.post("/submit_transaction", status_code=202)
def submit_transaction(payload: SubmitTransactionRequest, db: Session = Depends(get_db)):
    data = distributed_service.submit_transaction(db, payload.transaction)
    return {"ok": True, **data}


@router.post("/build_proposal")
def build_proposal(payload: BuildProposalRequest, db: Session = Depends(get_db)):
    data = distributed_service.build_proposal(db, payload.round)
    return {"ok": True, **data}


@router.post("/add_block", status_code=201)
def add_block(payload: AddBlockRequest, db: Session = Depends(get_db)):
    if payload.block is None:
        raise AppError(
            "INVALID_PROPOSAL",
            "A proposed block and at least 3 validator signatures are required",
            status_code=400,
        )
    data = distributed_service.commit_block(db, payload.block, payload.votes)
    return {"ok": True, **data}
