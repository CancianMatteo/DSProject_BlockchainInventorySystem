from __future__ import annotations

import base64
import json
import secrets
from datetime import UTC, datetime, timedelta

from jwt import PyJWTError, ExpiredSignatureError, decode, encode
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from passlib.context import CryptContext

from app.core.config import settings
from app.core.exceptions import AppError

pwd_context = CryptContext(schemes=["argon2"], deprecated="auto")


def hash_password(password: str) -> str:
    return pwd_context.hash(password)


def verify_password(password: str, password_hash: str) -> bool:
    return pwd_context.verify(password, password_hash)


def create_session_token(email: str, role: str) -> str:
    now = datetime.now(UTC)
    payload = {
        "sub": email,
        "role": role,
        "jti": secrets.token_urlsafe(16),
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(hours=settings.jwt_ttl_hours)).timestamp()),
    }
    return encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def decode_session_token(token: str) -> dict:
    try:
        return decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm])
    except ExpiredSignatureError as exc:
        raise AppError("TOKEN_EXPIRED", "Session token expired", status_code=401) from exc
    except PyJWTError as exc:
        raise AppError("TOKEN_INVALID", "Invalid session token", status_code=401) from exc


def generate_temporary_password(length: int = 16) -> str:
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789"
    return "".join(secrets.choice(alphabet) for _ in range(length))


def canonical_block_payload(payload: dict) -> bytes:
    return json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _load_private_key() -> Ed25519PrivateKey:
    key_str = settings.server_sign_private_key
    if not key_str:
        raise AppError("SERVER_KEY_MISSING", "Server signing key is missing", status_code=500)

    key_bytes = key_str.encode("utf-8")
    if b"BEGIN PRIVATE KEY" in key_bytes:
        key = serialization.load_pem_private_key(key_bytes, password=None)
        if not isinstance(key, Ed25519PrivateKey):
            raise AppError("SERVER_KEY_INVALID", "Server signing key must be Ed25519", status_code=500)
        return key

    try:
        raw = base64.b64decode(key_str)
        return Ed25519PrivateKey.from_private_bytes(raw)
    except Exception as exc:  # pragma: no cover - defensive parsing
        raise AppError("SERVER_KEY_INVALID", "Server signing key is invalid", status_code=500) from exc


def sign_block_payload(payload: dict) -> str:
    private_key = _load_private_key()
    signature = private_key.sign(canonical_block_payload(payload))
    return base64.b64encode(signature).decode("utf-8")
