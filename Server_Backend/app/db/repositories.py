from __future__ import annotations

import json
from datetime import UTC, datetime

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.db.models import (
    ChainBlock,
    InAppNotification,
    PasswordResetAttemptCounter,
    PasswordResetOtp,
    RevokedToken,
    User,
)


def _normalize_email(email: str) -> str:
    return email.strip().lower()


def now_iso() -> str:
    return datetime.now(UTC).isoformat()


def get_user_by_email(db: Session, email: str) -> User | None:
    normalized_email = _normalize_email(email)
    stmt = select(User).where(User.email == normalized_email)
    return db.scalar(stmt)


def get_user_by_name_surname(db: Session, *, name: str, surname: str) -> User | None:
    normalized_name = name.strip()
    normalized_surname = surname.strip()
    stmt = select(User).where(
        func.lower(User.name) == func.lower(normalized_name),
        func.lower(User.surname) == func.lower(normalized_surname),
    )
    return db.scalar(stmt)


def count_users(db: Session) -> int:
    stmt = select(func.count()).select_from(User)
    return int(db.scalar(stmt) or 0)


def create_user(
    db: Session,
    *,
    name: str,
    surname: str,
    email: str,
    pwd_hash: str,
    role: str = "user",
) -> User:
    normalized_email = _normalize_email(email)
    normalized_name = name.strip()
    normalized_surname = surname.strip()
    user = User(
        name=normalized_name,
        surname=normalized_surname,
        email=normalized_email,
        pwd_hash=pwd_hash,
        role=role,
        is_active=True,
        created_at=now_iso(),
    )
    db.add(user)
    db.flush()
    return user


def disable_user(db: Session, user: User) -> None:
    user.is_active = False
    user.disabled_at = now_iso()
    user.updated_at = now_iso()
    db.flush()


def enable_user(db: Session, user: User) -> None:
    user.is_active = True
    user.disabled_at = None
    user.updated_at = now_iso()
    db.flush()


def update_user_password(db: Session, user: User, new_pwd_hash: str) -> None:
    user.pwd_hash = new_pwd_hash
    user.updated_at = now_iso()
    db.flush()


def update_user_role(db: Session, user: User, role: str) -> None:
    user.role = role
    user.updated_at = now_iso()
    db.flush()


def get_latest_block(db: Session) -> ChainBlock | None:
    stmt = select(ChainBlock).order_by(ChainBlock.n_block.desc()).limit(1)
    return db.scalar(stmt)


def get_block_by_hash(db: Session, block_hash: str) -> ChainBlock | None:
    stmt = select(ChainBlock).where(ChainBlock.block_hash == block_hash)
    return db.scalar(stmt)


def get_all_blocks(db: Session) -> list[ChainBlock]:
    stmt = select(ChainBlock).order_by(ChainBlock.n_block.asc())
    return list(db.scalars(stmt))


def get_blocks_after_n(db: Session, n_block: int) -> list[ChainBlock]:
    stmt = select(ChainBlock).where(ChainBlock.n_block > n_block).order_by(ChainBlock.n_block.asc())
    return list(db.scalars(stmt))


def insert_block(
    db: Session,
    *,
    n_block: int,
    prev_block_hash: str | None,
    block_hash: str,
    timestamp: str,
    changes: dict[str, int],
    author_email: str,
    author_sign: str | None,
    server_sign: str,
) -> ChainBlock:
    row = ChainBlock(
        n_block=n_block,
        prev_block_hash=prev_block_hash,
        block_hash=block_hash,
        datetime=timestamp,
        changes_json=json.dumps(changes, sort_keys=True),
        author_email=author_email,
        author_sign=author_sign,
        server_sign=server_sign,
    )
    db.add(row)
    db.flush()
    return row


def revoke_token(db: Session, jti: str) -> None:
    db.add(RevokedToken(jti=jti, revoked_at=now_iso()))
    db.flush()


def is_token_revoked(db: Session, jti: str) -> bool:
    stmt = select(RevokedToken).where(RevokedToken.jti == jti)
    return db.scalar(stmt) is not None


def upsert_password_reset_otp(
    db: Session,
    *,
    user_email: str,
    otp_hash: str,
    expires_at: str,
) -> PasswordResetOtp:
    row = db.get(PasswordResetOtp, user_email)
    if row is None:
        row = PasswordResetOtp(
            user_email=user_email,
            otp_hash=otp_hash,
            generated_at=now_iso(),
            expires_at=expires_at,
            failed_attempts=0,
        )
        db.add(row)
    else:
        row.otp_hash = otp_hash
        row.generated_at = now_iso()
        row.expires_at = expires_at
        row.failed_attempts = 0
    db.flush()
    return row


def get_password_reset_otp(db: Session, user_email: str) -> PasswordResetOtp | None:
    return db.get(PasswordResetOtp, user_email)


def increase_password_reset_otp_failed_attempts(db: Session, row: PasswordResetOtp) -> int:
    row.failed_attempts += 1
    db.flush()
    return row.failed_attempts


def delete_password_reset_otp(db: Session, user_email: str) -> None:
    row = db.get(PasswordResetOtp, user_email)
    if row is not None:
        db.delete(row)
        db.flush()


def increase_daily_password_reset_attempts(db: Session, user_email: str) -> int:
    day_utc = datetime.now(UTC).date().isoformat()
    row = db.get(PasswordResetAttemptCounter, user_email)
    if row is None:
        row = PasswordResetAttemptCounter(user_email=user_email, day_utc=day_utc, attempts=1)
        db.add(row)
    else:
        if row.day_utc != day_utc:
            row.day_utc = day_utc
            row.attempts = 1
        else:
            row.attempts += 1
    db.flush()
    return row.attempts


def create_in_app_notification(
    db: Session,
    *,
    recipient_email: str,
    category: str,
    message: str,
    details: dict,
) -> InAppNotification:
    row = InAppNotification(
        recipient_email=recipient_email,
        category=category,
        message=message,
        details_json=json.dumps(details, sort_keys=True),
        created_at=now_iso(),
        is_read=False,
    )
    db.add(row)
    db.flush()
    return row


def get_unread_notifications_for_user(db: Session, user_email: str) -> list[InAppNotification]:
    stmt = (
        select(InAppNotification)
        .where(InAppNotification.recipient_email == user_email, InAppNotification.is_read.is_(False))
        .order_by(InAppNotification.created_at.asc())
    )
    return list(db.scalars(stmt))


def mark_notifications_as_read(db: Session, notifications: list[InAppNotification]) -> None:
    for row in notifications:
        row.is_read = True
    db.flush()


def get_active_admin_users(db: Session) -> list[User]:
    stmt = select(User).where(User.role == "admin", User.is_active.is_(True))
    return list(db.scalars(stmt))


def get_active_users(db: Session) -> list[User]:
    stmt = select(User).where(User.is_active.is_(True))
    return list(db.scalars(stmt))


def get_all_users(db: Session) -> list[User]:
    stmt = select(User).order_by(User.surname.asc(), User.name.asc(), User.email.asc())
    return list(db.scalars(stmt))
