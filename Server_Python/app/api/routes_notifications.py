from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.api.schemas import NotifyRequest
from app.db.session import get_db
from app.services import auth_service

router = APIRouter(tags=["notifications"])


@router.post("/notify")
def notify(
    payload: NotifyRequest,
    db: Session = Depends(get_db),
):
    data = auth_service.notify(db, session_token=payload.session_token)
    return {"ok": True, **data}
