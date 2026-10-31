from sqlalchemy import Boolean, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db.session import Base


class User(Base):
    __tablename__ = "users"
    __table_args__ = (
        UniqueConstraint("surname", "name", name="uq_users_surname_name"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, index=True)
    name: Mapped[str] = mapped_column(String(100), nullable=False)
    surname: Mapped[str] = mapped_column(String(100), nullable=False)
    email: Mapped[str] = mapped_column(String(255), unique=True, nullable=False, index=True)
    pwd_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    role: Mapped[str] = mapped_column(String(16), nullable=False, default="user")
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True, index=True)
    created_at: Mapped[str] = mapped_column(String(40), nullable=False)
    updated_at: Mapped[str | None] = mapped_column(String(40), nullable=True)
    disabled_at: Mapped[str | None] = mapped_column(String(40), nullable=True)


class ChainBlock(Base):
    __tablename__ = "chain"
    __table_args__ = (
        UniqueConstraint("n_block", name="uq_chain_n_block"),
        UniqueConstraint("block_hash", name="uq_chain_block_hash"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, index=True)
    n_block: Mapped[int] = mapped_column(Integer, nullable=False, index=True)
    prev_block_hash: Mapped[str | None] = mapped_column(String(128), nullable=True, index=True)
    block_hash: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    datetime: Mapped[str] = mapped_column(String(40), nullable=False)
    changes_json: Mapped[str] = mapped_column(Text, nullable=False)
    author_email: Mapped[str] = mapped_column(String(255), nullable=False, index=True)
    author_sign: Mapped[str | None] = mapped_column(Text, nullable=True)
    server_sign: Mapped[str] = mapped_column(Text, nullable=False)


class PendingTransaction(Base):
    __tablename__ = "pending_transactions"

    trans_id: Mapped[str] = mapped_column(String(128), primary_key=True)
    transaction_json: Mapped[str] = mapped_column(Text, nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False, default="pending", index=True)


class TransactionForwarding(Base):
    __tablename__ = "transaction_forwarding"

    trans_id: Mapped[str] = mapped_column(String(128), primary_key=True)
    transaction_json: Mapped[str] = mapped_column(Text, nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False, default="pending", index=True)
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    last_error: Mapped[str | None] = mapped_column(Text, nullable=True)
    updated_at: Mapped[str] = mapped_column(String(40), nullable=False)


class BlockVote(Base):
    __tablename__ = "block_votes"
    __table_args__ = (
        UniqueConstraint("height", "round", "validator_id", name="uq_block_votes_height_round_validator"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, index=True)
    height: Mapped[int] = mapped_column(Integer, nullable=False, index=True)
    round: Mapped[int] = mapped_column(Integer, nullable=False)
    block_hash: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    validator_id: Mapped[str] = mapped_column(String(128), nullable=False)
    signature: Mapped[str] = mapped_column(Text, nullable=False)
    phase: Mapped[str] = mapped_column(String(16), nullable=False, default="prepare")


class RevokedToken(Base):
    __tablename__ = "revoked_tokens"

    jti: Mapped[str] = mapped_column(String(128), primary_key=True)
    revoked_at: Mapped[str] = mapped_column(String(40), nullable=False)


class PasswordResetOtp(Base):
    __tablename__ = "password_reset_otp"

    user_email: Mapped[str] = mapped_column(String(255), primary_key=True)
    otp_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    generated_at: Mapped[str] = mapped_column(String(40), nullable=False)
    expires_at: Mapped[str] = mapped_column(String(40), nullable=False)
    failed_attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)


class PasswordResetAttemptCounter(Base):
    __tablename__ = "password_reset_attempt_counter"

    user_email: Mapped[str] = mapped_column(String(255), primary_key=True)
    day_utc: Mapped[str] = mapped_column(String(10), nullable=False)
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)


class InAppNotification(Base):
    __tablename__ = "in_app_notifications"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, index=True)
    recipient_email: Mapped[str] = mapped_column(String(255), nullable=False, index=True)
    category: Mapped[str] = mapped_column(String(64), nullable=False)
    message: Mapped[str] = mapped_column(String(512), nullable=False)
    details_json: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[str] = mapped_column(String(40), nullable=False)
    is_read: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False, index=True)
