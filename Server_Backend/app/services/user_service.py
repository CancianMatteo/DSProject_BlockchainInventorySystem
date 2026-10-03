from sqlalchemy.orm import Session

from app.core.exceptions import AppError
from app.core.config import settings
from app.core.security import generate_temporary_password, hash_password, verify_password
from app.db import repositories
from app.services import auth_service, email_service


def bootstrap_initial_admin(db: Session) -> bool:
    if repositories.count_users(db) > 0:
        return False

    if not settings.initial_admin_email or not settings.initial_admin_password:
        raise AppError(
            "INITIAL_ADMIN_NOT_CONFIGURED",
            "Set INITIAL_ADMIN_EMAIL and INITIAL_ADMIN_PASSWORD to bootstrap first admin",
            status_code=500,
        )

    repositories.create_user(
        db,
        name=settings.initial_admin_name,
        surname=settings.initial_admin_surname,
        email=settings.initial_admin_email,
        pwd_hash=hash_password(settings.initial_admin_password),
        role="admin",
    )
    db.commit()
    return True


def signup_new_user(
    db: Session,
    *,
    admin_token: str,
    new_name: str,
    new_surname: str,
    new_email: str,
    new_pwd: str | None = None,
    new_role: str = "user",
) -> dict:
    auth_service.require_admin(db, admin_token)

    if repositories.get_user_by_email(db, new_email):
        raise AppError("EMAIL_ALREADY_EXISTS", "User already exists", status_code=409)

    if repositories.get_user_by_name_surname(db, name=new_name, surname=new_surname):
        raise AppError(
            "NAME_SURNAME_ALREADY_EXISTS",
            "Another user already exists with the same surname and name",
            status_code=409,
        )

    if new_role not in {"admin", "user"}:
        raise AppError("INVALID_ROLE", "Role must be admin or user", status_code=400)

    assigned_password = (new_pwd or "").strip() or generate_temporary_password(10)
    repositories.create_user(
        db,
        name=new_name,
        surname=new_surname,
        email=new_email,
        pwd_hash=hash_password(assigned_password),
        role=new_role,
    )

    if not new_pwd:
        email_service.send_new_user_email(new_email, f"{new_name} {new_surname}", assigned_password)
    db.commit()
    if new_pwd:
        return {"message": f"User created: {new_email}"}
    return {"message": f"User created and credentials sent by email at {new_email}"}


def remove_user(db: Session, *, email: str, admin_token: str | None = None, pwd: str | None = None) -> dict:
    user = repositories.get_user_by_email(db, email)
    if not user:
        raise AppError("USER_NOT_FOUND", "User not found", status_code=404)

    if admin_token:
        admin_payload = auth_service.require_admin(db, admin_token)
        if admin_payload.get("sub") == user.email:
            raise AppError("FORBIDDEN", "Admin cannot disable own account", status_code=403)
    else:
        if not pwd:
            raise AppError("INVALID_REQUEST", "pwd is required when admin_token is missing", status_code=400)
        if not verify_password(pwd, user.pwd_hash):
            raise AppError("INVALID_CREDENTIALS", "Invalid credentials", status_code=401)

    repositories.disable_user(db, user)
    db.commit()
    return {"message": "User disabled"}


def reenable_user(db: Session, *, admin_token: str, email: str) -> dict:
    admin_payload = auth_service.require_admin(db, admin_token)

    user = repositories.get_user_by_email(db, email)
    if not user:
        raise AppError("USER_NOT_FOUND", "User not found", status_code=404)

    if admin_payload.get("sub") == user.email:
        raise AppError("FORBIDDEN", "Admin cannot re-enable own account", status_code=403)

    if user.is_active:
        return {"message": "User already active"}

    repositories.enable_user(db, user)
    db.commit()
    return {"message": "User re-enabled"}


def change_user_password(db: Session, *, email: str, old_pwd: str, new_pwd: str) -> dict:
    user = repositories.get_user_by_email(db, email)
    if not user or not user.is_active:
        raise AppError("USER_NOT_FOUND", "User not found", status_code=404)

    if not verify_password(old_pwd, user.pwd_hash):
        raise AppError("INVALID_OLD_PASSWORD", "Wrong old password", status_code=401)

    repositories.update_user_password(db, user, hash_password(new_pwd))
    db.commit()
    return {"message": "Password updated"}


def change_user_role(db: Session, *, admin_token: str, target_email: str, new_role: str) -> dict:
    admin_payload = auth_service.require_admin(db, admin_token)

    if new_role not in {"admin", "user"}:
        raise AppError("INVALID_ROLE", "Role must be admin or user", status_code=400)

    target = repositories.get_user_by_email(db, target_email)
    if not target:
        raise AppError("USER_NOT_FOUND", "User not found", status_code=404)

    if admin_payload.get("sub") == target.email:
        raise AppError("FORBIDDEN", "Admin cannot change own role", status_code=403)

    repositories.update_user_role(db, target, new_role)
    db.commit()
    return {"message": f"Role for {target.email} updated to {new_role}"}


def list_users(db: Session, *, admin_token: str) -> dict:
    auth_service.require_admin(db, admin_token)
    users = repositories.get_all_users(db)
    return {
        "users": [
            {
                "name": user.name,
                "surname": user.surname,
                "email": user.email,
                "role": user.role,
                "is_active": user.is_active,
                "created_at": user.created_at,
                "updated_at": user.updated_at,
                "disabled_at": user.disabled_at,
            }
            for user in users
        ]
    }
