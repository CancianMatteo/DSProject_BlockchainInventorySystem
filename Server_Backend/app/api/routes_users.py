from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.api.schemas import AdminActionRequest, AdminEmailActionRequest, ChangePasswordRequest, ChangeUserRoleRequest, RemoveUserRequest, SignupRequest
from app.db.session import get_db
from app.services import user_service

router = APIRouter(prefix="/users", tags=["users"])


@router.post("/signup_new_user", status_code=201)
def signup_new_user(payload: SignupRequest, db: Session = Depends(get_db)):
    data = user_service.signup_new_user(
        db,
        admin_token=payload.admin_token,
        new_name=payload.new_name,
        new_surname=payload.new_surname,
        new_email=payload.new_email,
        new_pwd=payload.new_pwd,
        new_role=payload.new_role,
    )
    return {"ok": True, **data}


@router.post("/list_users")
def list_users(payload: AdminActionRequest, db: Session = Depends(get_db)):
    data = user_service.list_users(db, admin_token=payload.admin_token)
    return {"ok": True, **data}


@router.post("/remove_user")
def remove_user(payload: RemoveUserRequest, db: Session = Depends(get_db)):
    data = user_service.remove_user(
        db,
        email=payload.email,
        admin_token=payload.admin_token,
        pwd=payload.pwd,
    )
    return {"ok": True, **data}


@router.post("/reenable_user")
def reenable_user(payload: AdminEmailActionRequest, db: Session = Depends(get_db)):
    data = user_service.reenable_user(
        db,
        admin_token=payload.admin_token,
        email=payload.email,
    )
    return {"ok": True, **data}


@router.post("/change_user_pwd")
def change_user_pwd(payload: ChangePasswordRequest, db: Session = Depends(get_db)):
    data = user_service.change_user_password(
        db,
        email=payload.email,
        old_pwd=payload.old_pwd,
        new_pwd=payload.new_pwd,
    )
    return {"ok": True, **data}


@router.post("/change_user_role")
def change_user_role(payload: ChangeUserRoleRequest, db: Session = Depends(get_db)):
    data = user_service.change_user_role(
        db,
        admin_token=payload.admin_token,
        target_email=payload.target_email,
        new_role=payload.new_role,
    )
    return {"ok": True, **data}
