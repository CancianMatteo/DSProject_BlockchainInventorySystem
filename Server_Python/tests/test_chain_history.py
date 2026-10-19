import json
from datetime import UTC, datetime

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from app.api.routes_chain import get_chain_history
from app.db.models import ChainBlock
from app.db.session import Base


@pytest.fixture
def db():
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
        future=True,
    )
    Base.metadata.create_all(engine)
    try:
        with Session(engine, autoflush=False, future=True) as session:
            yield session
    finally:
        Base.metadata.drop_all(engine)
        engine.dispose()


def test_chain_history_returns_descending_cursor_pages(db):
    timestamp = datetime.now(UTC).isoformat()
    for n_block in range(1, 6):
        db.add(
            ChainBlock(
                n_block=n_block,
                prev_block_hash=f"hash-{n_block - 1}" if n_block > 1 else None,
                block_hash=f"hash-{n_block}",
                datetime=timestamp,
                changes_json=json.dumps({"changes": {"item-1": n_block}}),
                author_email="operator@example.test",
                author_sign=None,
                server_sign="signature",
            )
        )
    db.flush()

    first_page = get_chain_history(db=db, limit=2, before_n_block=None)
    second_page = get_chain_history(
        db=db,
        limit=2,
        before_n_block=first_page["next_before_n_block"],
    )
    last_page = get_chain_history(
        db=db,
        limit=2,
        before_n_block=second_page["next_before_n_block"],
    )

    assert [block["n_block"] for block in first_page["blocks"]] == [5, 4]
    assert first_page["has_more"] is True
    assert first_page["next_before_n_block"] == 4
    assert [block["n_block"] for block in second_page["blocks"]] == [3, 2]
    assert second_page["has_more"] is True
    assert [block["n_block"] for block in last_page["blocks"]] == [1]
    assert last_page["has_more"] is False
    assert last_page["next_before_n_block"] is None
