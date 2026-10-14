from fastapi import APIRouter, Depends, Header, Request
from sqlalchemy.orm import Session

from app.api.schemas import ForgotPasswordRequest, LoginRequest, ResetLoginWithOtpRequest
from app.db.session import get_db
from app.services import auth_service

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/login")
def login(payload: LoginRequest, db: Session = Depends(get_db)):
    data = auth_service.login(db, payload.email, payload.pwd)
    return {"ok": True, **data}


@router.post("/forgot_pwd")
def forgot_pwd(
    payload: ForgotPasswordRequest,
    x_app_token: str | None = Header(default=None, alias="X-App-Token"),
    db: Session = Depends(get_db),
):
    auth_service.require_app_token(x_app_token)
    data = auth_service.forgot_pwd(db, email=payload.email)
    return {"ok": True, **data}


@router.post("/reset_login_with_otp")
def reset_login_with_otp(
    payload: ResetLoginWithOtpRequest,
    request: Request,
    db: Session = Depends(get_db),
):
    client_ip = request.client.host if request.client is not None else "unknown"
    data = auth_service.reset_login_with_otp(
        db,
        email=payload.email,
        otp=payload.otp,
        new_pwd=payload.new_pwd,
        executor_ip=client_ip,
    )
    return {"ok": True, **data}
