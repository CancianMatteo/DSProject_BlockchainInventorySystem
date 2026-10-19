import json

from fastapi import APIRouter, Depends
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.exceptions import AppError
from app.db.session import get_db

router = APIRouter(prefix="/health", tags=["health"])


@router.get("/live")
def live():
    return {"ok": True, "status": "live"}


@router.get("/ready")
def ready(db: Session = Depends(get_db)):
    db.execute(text("SELECT 1"))
    try:
        validator_keys = (
            json.loads(settings.validator_public_keys)
            if isinstance(settings.validator_public_keys, str)
            else settings.validator_public_keys
        )
    except json.JSONDecodeError as exc:
        raise AppError(
            "VALIDATOR_CONFIGURATION_INVALID",
            "Validator public-key configuration is invalid",
            status_code=500,
        ) from exc
    return {
        "ok": True,
        "status": "ready",
        "checks": {
            "db": True,
            "validator_quorum_configured": isinstance(validator_keys, dict)
            and len(validator_keys) >= 3,
        },
    }
