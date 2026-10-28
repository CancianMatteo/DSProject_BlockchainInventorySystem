from datetime import UTC, datetime, timedelta

import httpx
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.exceptions import AppError
from app.db.models import PendingTransaction
from app.db.repositories import get_latest_block


MAX_BLOCK_TRANSACTIONS = 500
IDLE_PROPOSAL_INTERVAL = timedelta(minutes=15)
_started_at = datetime.now(UTC)


def mark_started() -> None:
    global _started_at
    _started_at = datetime.now(UTC)


def proposal_trigger(db: Session, now: datetime | None = None) -> tuple[str | None, int]:
    pending_count = db.scalar(
        select(func.count())
        .select_from(PendingTransaction)
        .where(PendingTransaction.status == "pending")
    )
    pending_count = int(pending_count or 0)
    if pending_count == 0:
        return None, 0
    if pending_count >= MAX_BLOCK_TRANSACTIONS:
        return "mempool_full", pending_count

    latest = get_latest_block(db)
    if latest is None:
        last_commit = _started_at
    else:
        last_commit = datetime.fromisoformat(latest.datetime.replace("Z", "+00:00"))
        if last_commit.tzinfo is None:
            last_commit = last_commit.replace(tzinfo=UTC)

    current_time = now or datetime.now(UTC)
    if current_time - last_commit >= IDLE_PROPOSAL_INTERVAL:
        return "idle_timeout", pending_count
    return None, pending_count


def request_proposal_if_ready(db: Session) -> dict[str, object] | None:
    reason, pending_count = proposal_trigger(db)
    if reason is None:
        return None

    host = (settings.elixir_host or "").strip()
    if not host:
        raise AppError(
            "ELIXIR_HOST_MISSING",
            "Elixir host is required to request a block proposal",
            status_code=500,
        )

    response = httpx.post(
        f"http://{host}:{settings.elixir_http_port}/api/v1/proposal_request",
        json={"reason": reason, "pending_transactions": pending_count},
        timeout=5.0,
    )
    response.raise_for_status()
    result = response.json()
    if not isinstance(result, dict) or not isinstance(result.get("accepted"), bool):
        raise AppError(
            "ELIXIR_PROPOSAL_RESPONSE_INVALID",
            "Elixir returned an invalid proposal-request response",
            status_code=502,
        )
    return result
