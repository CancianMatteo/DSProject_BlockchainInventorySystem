from fastapi import APIRouter, Depends
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.core.config import settings
from app.db.session import get_db

router = APIRouter(prefix="/health", tags=["health"])


@router.get("/live")
def live():
    return {"ok": True, "status": "live"}


@router.get("/ready")
def ready(db: Session = Depends(get_db)):
    db.execute(text("SELECT 1"))
    return {
        "ok": True,
        "status": "ready",
        "checks": {
            "db": True,
            "server_sign_key_configured": bool(settings.server_sign_private_key),
        },
    }
