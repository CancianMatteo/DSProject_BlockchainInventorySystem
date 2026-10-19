from sqlalchemy.orm import Session
from datetime import UTC, datetime, timedelta
import json
import secrets
from typing import NoReturn
import logging

from app.core.config import settings
from app.core.exceptions import AppError
from app.core.security import create_session_token, decode_session_token, hash_password, verify_password
from app.db import repositories
from app.services import email_service


_DUMMY_OTP_HASH = hash_password("000000")
logger = logging.getLogger(__name__)


def _notify_admins_otp_email_sent(db: Session, *, target_email: str) -> None:
    details = {
        "time_utc": datetime.now(UTC).isoformat(),
        "target_email": target_email,
        "event": "OTP_RESET_EMAIL_SENT",
    }
    admins = repositories.get_active_admin_users(db)
    for admin in admins:
        repositories.create_in_app_notification(
            db,
            recipient_email=admin.email,
            category="security",
            message=f"Password reset OTP email sent to {target_email}",
            details=details,
        )


def login(db: Session, email: str, pwd: str) -> dict:
    user = repositories.get_user_by_email(db, email)
    if not user:
        raise AppError("INVALID_CREDENTIALS", "Invalid credentials", status_code=401)

    if not user.is_active:
        raise AppError("USER_DISABLED", "User disabiled by admins", status_code=403)
    
    if not verify_password(pwd, user.pwd_hash):
        raise AppError("INVALID_CREDENTIALS", "Invalid credentials", status_code=401)

    token = create_session_token(user.email, user.role)
    return {
        "session_token": token,
        "user": {
            "name": user.name,
            "surname": user.surname,
            "email": user.email,
            "role": user.role,
        },
    }


def validate_token(db: Session, token: str) -> dict:
    payload = decode_session_token(token)
    jti = payload.get("jti")
    if jti and repositories.is_token_revoked(db, jti):
        raise AppError("TOKEN_REVOKED", "Session token has been revoked", status_code=401)
    return payload


def require_admin(db: Session, token: str) -> dict:
    payload = validate_token(db, token)
    if payload.get("role") != "admin":
        raise AppError("ADMIN_REQUIRED", "Admin role required", status_code=403)
    return payload


def require_app_token(app_token: str | None) -> None:
    expected = settings.app_client_token
    if not expected:
        return
    if app_token is None or not secrets.compare_digest(app_token, expected):
        raise AppError("APP_AUTH_REQUIRED", "Valid app token required", status_code=401)


def _generate_otp_code() -> str:
    return f"{secrets.randbelow(1_000_000):06d}"


def _parse_iso(ts: str) -> datetime:
    return datetime.fromisoformat(ts)


def _notify_admins_excessive_reset_attempts(
    db: Session,
    *,
    user_email: str,
    executor_ip: str,
    attempts_today: int,
) -> None:
    event_time = datetime.now(UTC).isoformat()
    details = {
        "time_utc": event_time,
        "involved_user": user_email,
        "executor_ip": executor_ip,
        "attempts_today": attempts_today,
        "event": "EXCESSIVE_OTP_RESET_ATTEMPTS",
    }

    admins = repositories.get_active_admin_users(db)
    for admin in admins:
        repositories.create_in_app_notification(
            db,
            recipient_email=admin.email,
            category="security",
            message=f"User {user_email} exceeded OTP reset attempts limit",
            details=details,
        )

    email_service.send_security_alert_email(
        settings.security_alert_email,
        title="Security alert: excessive OTP reset attempts detected.",
        details=details,
    )


def _public_forgot_pwd_response() -> dict:
    return {
        "message": "If the account exists, an OTP has been sent",
        "otp_valid_minutes": 15,
    }


def _raise_generic_reset_failure() -> NoReturn:
    raise AppError("OTP_INVALID", "Invalid OTP or reset request", status_code=401)


def _consume_invalid_reset_attempt(
    db: Session,
    *,
    attempt_key_email: str,
    executor_ip: str,
    notify_user_email: str | None,
) -> None:
    attempts_today = repositories.increase_daily_password_reset_attempts(db, attempt_key_email)
    if attempts_today > settings.password_reset_max_attempts_per_day:
        if notify_user_email and attempts_today == settings.password_reset_max_attempts_per_day + 1:
            _notify_admins_excessive_reset_attempts(
                db,
                user_email=notify_user_email,
                executor_ip=executor_ip,
                attempts_today=attempts_today,
            )
        db.commit()
        raise AppError(
            "TOO_MANY_RESET_ATTEMPTS",
            "Too many reset attempts for today; try again tomorrow",
            status_code=429,
        )


def forgot_pwd(db: Session, *, email: str) -> dict:
    user = repositories.get_user_by_email(db, email)
    if not user:
        logger.info("OTP_NOT_SENT_USER_NOT_ELIGIBLE email=%s", email)
        raise AppError("USER_NOT_FOUND", "User not found", status_code=404)
    if not user.is_active:
        logger.info("OTP_NOT_SENT_USER_NOT_ELIGIBLE email=%s", email)
        raise AppError("USER_INACTIVE", "User is inactive", status_code=403)

    otp_row = repositories.get_password_reset_otp(db, user.email)
    if otp_row is not None:
        elapsed = (datetime.now(UTC) - _parse_iso(otp_row.generated_at)).total_seconds()
        if elapsed < settings.password_reset_email_cooldown_seconds:
            logger.info(
                "OTP_NOT_SENT_COOLDOWN email=%s elapsed_seconds=%.2f cooldown_seconds=%s",
                user.email,
                elapsed,
                settings.password_reset_email_cooldown_seconds,
            )
            wait_seconds = int(settings.password_reset_email_cooldown_seconds - elapsed)
            raise AppError(
                "OTP_REQUEST_COOLDOWN",
                f"Please wait {wait_seconds} seconds before requesting a new OTP",
                status_code=429,
            )

    otp_code = _generate_otp_code()
    expires_at = (datetime.now(UTC) + timedelta(minutes=15)).isoformat()

    repositories.upsert_password_reset_otp(
        db,
        user_email=user.email,
        otp_hash=hash_password(otp_code),
        expires_at=expires_at,
    )
    email_service.send_password_reset_otp_email(user.email, otp_code)
    _notify_admins_otp_email_sent(db, target_email=user.email)
    db.commit()
    logger.info("OTP_EMAIL_SENT email=%s expires_at=%s", user.email, expires_at)

    return {"message": "OTP sent to email", "otp_valid_minutes": 15}


def reset_login_with_otp(db: Session, *, email: str, otp: str, new_pwd: str, executor_ip: str) -> dict:
    user = repositories.get_user_by_email(db, email)
    if not user or not user.is_active:
        verify_password(otp, _DUMMY_OTP_HASH)
        _consume_invalid_reset_attempt(
            db,
            attempt_key_email=email,
            executor_ip=executor_ip,
            notify_user_email=None,
        )
        db.commit()
        _raise_generic_reset_failure()

    active_user_email = user.email

    otp_row = repositories.get_password_reset_otp(db, active_user_email)
    if otp_row is None:
        verify_password(otp, _DUMMY_OTP_HASH)
        _consume_invalid_reset_attempt(
            db,
            attempt_key_email=active_user_email,
            executor_ip=executor_ip,
            notify_user_email=active_user_email,
        )
        db.commit()
        _raise_generic_reset_failure()

    now = datetime.now(UTC)
    if _parse_iso(otp_row.expires_at) < now:
        verify_password(otp, _DUMMY_OTP_HASH)
        _consume_invalid_reset_attempt(
            db,
            attempt_key_email=active_user_email,
            executor_ip=executor_ip,
            notify_user_email=active_user_email,
        )
        db.commit()
        _raise_generic_reset_failure()

    if otp_row.failed_attempts >= 3:
        otp_code = _generate_otp_code()
        expires_at = (now + timedelta(minutes=15)).isoformat()
        repositories.upsert_password_reset_otp(
            db,
            user_email=active_user_email,
            otp_hash=hash_password(otp_code),
            expires_at=expires_at,
        )
        email_service.send_password_reset_otp_email(active_user_email, otp_code)
        db.commit()
        raise AppError(
            "OTP_REGENERATED",
            "OTP try limit reached; a new OTP has been sent",
            status_code=400,
        )

    if not verify_password(otp, otp_row.otp_hash):
        _consume_invalid_reset_attempt(
            db,
            attempt_key_email=active_user_email,
            executor_ip=executor_ip,
            notify_user_email=active_user_email,
        )

        failed = repositories.increase_password_reset_otp_failed_attempts(db, otp_row)
        if failed >= 3:
            otp_code = _generate_otp_code()
            expires_at = (now + timedelta(minutes=15)).isoformat()
            repositories.upsert_password_reset_otp(
                db,
                user_email=active_user_email,
                otp_hash=hash_password(otp_code),
                expires_at=expires_at,
            )
            email_service.send_password_reset_otp_email(active_user_email, otp_code)
            _notify_admins_otp_email_sent(db, target_email=active_user_email)
            db.commit()
            raise AppError(
                "OTP_REGENERATED",
                "OTP try limit reached; a new OTP has been sent",
                status_code=400,
            )

        db.commit()
        _raise_generic_reset_failure()

    repositories.update_user_password(db, user, hash_password(new_pwd))
    repositories.delete_password_reset_otp(db, active_user_email)
    db.commit()
    return {"message": "Password reset completed"}


def notify(db: Session, *, session_token: str) -> dict:
    payload = validate_token(db, session_token)
    email = payload.get("sub")
    if not isinstance(email, str) or not email:
        raise AppError("TOKEN_INVALID", "Invalid session token", status_code=401)

    user = repositories.get_user_by_email(db, email)
    if not user or not user.is_active:
        raise AppError("INVALID_CREDENTIALS", "Invalid credentials", status_code=401)

    unread = repositories.get_unread_notifications_for_user(db, email)
    notifications = [
        {
            "id": row.id,
            "category": row.category,
            "message": row.message,
            "details": json.loads(row.details_json),
            "created_at": row.created_at,
        }
        for row in unread
    ]
    repositories.mark_notifications_as_read(db, unread)
    db.commit()
    return {"notifications": notifications}
