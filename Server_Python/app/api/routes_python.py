from typing import Any

from fastapi import APIRouter, Body, Depends
from sqlalchemy.orm import Session

from app.core.exceptions import AppError
from app.db.session import get_db
from app.services import distributed_service

router = APIRouter(tags=["python"])


@router.post("/python_call")
def python_call(
    payload: dict[str, Any] = Body(...),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    """Internal endpoint used by the Elixir consensus engine
    (InventoryNode.PythonClient): the "flag" field selects the operation.

    Each handler returns exactly the structure expected by Elixir
    (see InventoryNode.ConsensusEngine and InventoryNode.Router).
    """
    flag = payload.get("flag")

    # --- Transactions (mempool) ---
    if flag == "transaction":
        result = distributed_service.submit_transaction(db, payload)
        return {
            **payload,
            "status": result["status"],
            "duplicate": result["duplicate"],
        }

    if flag == "chain_state":
        return distributed_service.chain_state(db)

    # --- Leader proposal (PRE-PREPARE) ---
    if flag == "prepare_block":
        round_number = payload.get("round")
        if (
            isinstance(round_number, bool)
            or not isinstance(round_number, int)
            or round_number < 0
        ):
            raise AppError(
                "INVALID_ROUND",
                "prepare_block round must be a non-negative integer",
                status_code=400,
            )
        return distributed_service.prepare_proposal(db, round_number)

    if flag == "pre_prepare":
        return {"status": distributed_service.verify_pre_prepare(payload)}

    if flag == "pre_prepare_conflict":
        proof = distributed_service.create_pre_prepare_conflict_proof(payload)
        return {"status": proof is not None, "proof": proof}

    # --- PREPARE / COMMIT votes ---
    if flag == "prepare":
        return distributed_service.sign_vote("prepare", payload)

    if flag == "verified_prepare":
        return {"status": distributed_service.verify_vote("prepare", payload)}

    if flag == "commit_proposal":
        return {"status": distributed_service.verify_prepare_certificate(payload)}

    if flag == "verify_commit_certificate":
        return {"status": distributed_service.verify_commit_certificate(payload)}

    if flag == "get_finalized_block":
        return distributed_service.get_finalized_block(db, payload.get("height"))

    if flag == "commit":
        return distributed_service.sign_vote("commit", payload)

    if flag == "verified_commit":
        return {"status": distributed_service.verify_vote("commit", payload)}

    # --- ROUND CHANGE ---
    if flag == "round_change":
        return distributed_service.sign_round_change(payload)

    if flag == "verified_round_change":
        return {"status": distributed_service.verify_round_change(payload)}

    # --- Persist finalized block ---
    if flag == "write_block":
        return distributed_service.write_committed_block(
            db,
            payload.get("block_data"),
            payload.get("proposer_id"),
            payload.get("proposer_signature"),
            payload.get("commit_signatures"),
        )

    if flag == "import_finalized_block":
        return distributed_service.write_committed_block(
            db,
            payload.get("block_data"),
            payload.get("proposer_id"),
            payload.get("proposer_signature"),
            payload.get("commit_signatures"),
        )

    raise AppError(
        "UNKNOWN_FLAG",
        f"Unknown python_call flag: {flag!r}",
        status_code=404,
    )