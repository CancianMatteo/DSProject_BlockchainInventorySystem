from datetime import UTC, datetime, timedelta
import json

from sqlalchemy import create_engine
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from app.db.models import ChainBlock, PendingTransaction
from app.db.session import Base
from app.services import proposal_trigger_service


def make_db():
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
        future=True,
    )
    Base.metadata.create_all(engine)
    return engine


def add_pending(db: Session, count: int, start: int = 0) -> None:
    db.add_all(
        PendingTransaction(
            trans_id=f"tx-{index}",
            transaction_json=json.dumps(
                {"trans_id": f"tx-{index}", "tx_type": "inbound"}
            ),
            status="pending",
        )
        for index in range(start, start + count)
    )
    db.commit()


def test_mempool_trigger_requires_200_pending_transactions(monkeypatch):
    engine = make_db()
    now = datetime.now(UTC)
    monkeypatch.setattr(proposal_trigger_service, "_started_at", now)
    try:
        with Session(engine) as db:
            add_pending(db, 199)
            assert proposal_trigger_service.proposal_trigger(db, now) == (None, 199)
            add_pending(db, 1, start=199)
            assert proposal_trigger_service.proposal_trigger(db, now) == (
                "mempool_full",
                200,
            )
    finally:
        engine.dispose()


def test_idle_trigger_starts_after_15_minutes_with_pending_transactions(monkeypatch):
    engine = make_db()
    now = datetime.now(UTC)
    monkeypatch.setattr(
        proposal_trigger_service,
        "_started_at",
        now - timedelta(minutes=15),
    )
    try:
        with Session(engine) as db:
            add_pending(db, 1)
            assert proposal_trigger_service.proposal_trigger(db, now) == (
                "idle_timeout",
                1,
            )
    finally:
        engine.dispose()


def test_idle_trigger_uses_persisted_commit_time(monkeypatch):
    engine = make_db()
    now = datetime.now(UTC)
    monkeypatch.setattr(
        proposal_trigger_service,
        "_started_at",
        now - timedelta(minutes=30),
    )
    try:
        with Session(engine) as db:
            add_pending(db, 1)
            db.add(
                ChainBlock(
                    n_block=1,
                    prev_block_hash=None,
                    block_hash="test-hash",
                    datetime=(now - timedelta(minutes=14)).isoformat(),
                    changes_json="{}",
                    author_email="test@example.org",
                    author_sign=None,
                    server_sign="test-signature",
                )
            )
            db.commit()
            assert proposal_trigger_service.proposal_trigger(db, now) == (None, 1)

            latest = db.query(ChainBlock).one()
            latest.datetime = (now - timedelta(minutes=15)).isoformat()
            db.commit()
            assert proposal_trigger_service.proposal_trigger(db, now) == (
                "idle_timeout",
                1,
            )
    finally:
        engine.dispose()


def test_empty_mempool_never_requests_a_proposal():
    engine = make_db()
    try:
        with Session(engine) as db:
            assert proposal_trigger_service.proposal_trigger(db) == (None, 0)
    finally:
        engine.dispose()
