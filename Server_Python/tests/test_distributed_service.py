import base64
import json
import uuid
from datetime import datetime, timezone

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from sqlalchemy import create_engine
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from app.core.config import settings
from app.api.routes_chain import get_chain_history
from app.db.models import PendingTransaction
from app.db.repositories import insert_block
from app.db.session import Base
from app.services import simbehaviour_service
from app.services.cache_service import inventory_cache
from app.services.distributed_service import (
    DistributedReject,
    build_proposal,
    canonical_json,
    chain_from,
    commit_block,
    import_block,
    submit_transaction,
    transaction_status,
)


@pytest.fixture
def db():
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
        future=True,
    )
    Base.metadata.create_all(engine)
    with Session(engine, autoflush=False, future=True) as session:
        inventory_cache.reset()
        yield session
    Base.metadata.drop_all(engine)
    engine.dispose()


@pytest.fixture(autouse=True)
def validator_keys(monkeypatch):
    keys = {
        node_id: Ed25519PrivateKey.generate()
        for node_id in ("node_a", "node_b", "node_c", "node_d")
    }
    public_keys = {
        node_id: base64.b64encode(
            key.public_key().public_bytes(
                serialization.Encoding.Raw,
                serialization.PublicFormat.Raw,
            )
        ).decode("ascii")
        for node_id, key in keys.items()
    }
    monkeypatch.setattr(settings, "node_id", "node_a")
    monkeypatch.setattr(settings, "validator_private_key", base64.b64encode(
        keys["node_a"].private_bytes(
            serialization.Encoding.Raw,
            serialization.PrivateFormat.Raw,
            serialization.NoEncryption(),
        )
    ).decode("ascii"))
    monkeypatch.setattr(settings, "validator_public_keys", json.dumps(public_keys))
    return keys


def make_transaction(
    item_id: str = "item-1",
    quantity: int = 5,
    tx_type: str = "inbound",
) -> dict:
    private_key = Ed25519PrivateKey.generate()
    public_key = private_key.public_key().public_bytes(
        serialization.Encoding.Raw,
        serialization.PublicFormat.Raw,
    )
    transaction = {
        "flag": "transaction",
        "from_node": "operator@example.test",
        "tx_type": tx_type,
        "item_id": item_id,
        "quantity": quantity,
        "location": "warehouse-1",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "tx_id": str(uuid.uuid4()),
        "pub_key": base64.b64encode(public_key).decode("ascii"),
        "item_catalog": {
            item_id: {
                "itemName": "Sample",
                "brand": "Brand",
                "category": "General",
            }
        } if tx_type == "inbound" else {},
    }
    transaction["signature"] = base64.b64encode(
        private_key.sign(canonical_json(transaction))
    ).decode("ascii")
    return transaction


def make_votes(block: dict, keys: dict[str, Ed25519PrivateKey]) -> list[dict]:
    votes = []
    for validator_id in ("node_a", "node_b", "node_c"):
        payload = {
            "height": block["height"],
            "round": block["round"],
            "block_hash": block["block_hash"],
            "validator_id": validator_id,
        }
        votes.append(
            {
                **payload,
                "signature": base64.b64encode(
                    keys[validator_id].sign(canonical_json(payload))
                ).decode("ascii"),
            }
        )
    return votes


def test_submit_is_idempotent_and_requires_valid_client_signature(db):
    transaction = make_transaction()
    accepted = submit_transaction(db, transaction)
    duplicate = submit_transaction(db, transaction)

    assert accepted["status"] == "pending"
    assert duplicate["duplicate"] is True
    assert db.get(PendingTransaction, transaction["tx_id"]).status == "pending"

    tampered = make_transaction()
    tampered["quantity"] += 1
    with pytest.raises(DistributedReject, match="Cryptographic signature is invalid"):
        submit_transaction(db, tampered)


def test_block_is_finalized_only_with_three_distinct_valid_votes(db, validator_keys):
    transaction = make_transaction()
    submit_transaction(db, transaction)
    proposal = build_proposal(db, 0)["block"]
    assert proposal is not None
    assert build_proposal(db, 0)["block"] == proposal

    with pytest.raises(DistributedReject, match="At least 3 distinct"):
        commit_block(db, proposal, make_votes(proposal, validator_keys)[:2])

    result = commit_block(db, proposal, make_votes(proposal, validator_keys))

    assert result["height"] == 1
    assert transaction_status(db, transaction["tx_id"])["status"] == "finalized"
    assert inventory_cache.items["item-1"]["quantity"] == 5


def test_rejects_duplicate_validator_votes(db, validator_keys):
    transaction = make_transaction()
    submit_transaction(db, transaction)
    proposal = build_proposal(db, 0)["block"]
    votes = make_votes(proposal, validator_keys)
    votes[-1] = votes[0]

    with pytest.raises(DistributedReject, match="At least 3 distinct"):
        commit_block(db, proposal, votes)


def test_rejects_outbound_transaction_exceeding_committed_stock(db, validator_keys):
    inbound = make_transaction(quantity=5)
    submit_transaction(db, inbound)
    proposal = build_proposal(db, 0)["block"]
    commit_block(db, proposal, make_votes(proposal, validator_keys))

    outbound = make_transaction(quantity=6, tx_type="outbound")
    with pytest.raises(DistributedReject, match="would make item-1 inventory negative"):
        submit_transaction(db, outbound)


def test_sync_import_accepts_only_a_certified_block(db, validator_keys, monkeypatch):
    transaction = make_transaction()
    submit_transaction(db, transaction)
    proposal = build_proposal(db, 0)["block"]
    votes = make_votes(proposal, validator_keys)
    commit_block(db, proposal, votes)

    synced = chain_from(db, 1)["blocks"][0]
    target_engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
        future=True,
    )
    Base.metadata.create_all(target_engine)
    node_b_seed = validator_keys["node_b"].private_bytes(
        serialization.Encoding.Raw,
        serialization.PrivateFormat.Raw,
        serialization.NoEncryption(),
    )
    monkeypatch.setattr(settings, "node_id", "node_b")
    monkeypatch.setattr(settings, "validator_private_key", base64.b64encode(node_b_seed).decode("ascii"))
    inventory_cache.reset()
    try:
        with Session(target_engine, autoflush=False, future=True) as target_db:
            imported = import_block(target_db, synced["block"], synced["votes"])
            assert imported["height"] == 1
            assert transaction_status(target_db, transaction["tx_id"])["status"] == "finalized"
            assert inventory_cache.items["item-1"]["quantity"] == 5
    finally:
        Base.metadata.drop_all(target_engine)
        target_engine.dispose()


def test_chain_history_returns_descending_cursor_pages(db):
    for n_block in range(1, 6):
        insert_block(
            db,
            n_block=n_block,
            prev_block_hash=f"hash-{n_block - 1}" if n_block > 1 else None,
            block_hash=f"hash-{n_block}",
            timestamp=datetime.now(timezone.utc).isoformat(),
            changes={"item-1": n_block},
            author_email="operator@example.test",
            author_sign=None,
            server_sign="signature",
        )

    first_page = get_chain_history(db=db, limit=2)
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


@pytest.fixture
def healthy_mode(monkeypatch):
    monkeypatch.setattr(simbehaviour_service, "_forward_to_elixir", lambda mode: None)
    previous = simbehaviour_service.get_mode()
    simbehaviour_service.set_mode(simbehaviour_service.HEALTHY)
    try:
        yield
    finally:
        simbehaviour_service.set_mode(previous)


def _simbehaviour_client():
    pytest.importorskip("httpx", reason="httpx is required for TestClient")
    from fastapi.testclient import TestClient

    from app.main import app

    return TestClient(app, raise_server_exceptions=False)


def test_simbehaviour_endpoints_switch_mode(healthy_mode, monkeypatch):
    pytest.importorskip("httpx", reason="httpx is required for TestClient")
    monkeypatch.setattr(simbehaviour_service, "_forward_to_elixir", lambda mode: None)
    client = _simbehaviour_client()

    assert client.get("/api/v1/simbehaviour").json() == {"ok": True, "mode": "healthy"}

    for mode in ("noclients", "noresponse", "bizantine", "healthy"):
        response = client.post(f"/api/v1/simbehaviour/{mode}")
        assert response.status_code == 200
        assert response.json() == {"ok": True, "mode": mode}
        assert simbehaviour_service.get_mode() == mode


def test_noclients_blocks_clients_but_not_python_call(healthy_mode, monkeypatch, validator_keys):
    pytest.importorskip("httpx", reason="httpx is required for TestClient")
    monkeypatch.setattr(simbehaviour_service, "_forward_to_elixir", lambda mode: None)
    client = _simbehaviour_client()

    assert client.post("/api/v1/simbehaviour/noclients").status_code == 200

    # Client-facing endpoints are rejected...
    assert client.get("/api/v1/chain/history").status_code == 503
    assert client.post("/api/v1/auth/login", json={"email": "a@b.c", "pwd": "secret12"}).status_code == 503
    # ...while simbehaviour/health/python_call keep working.
    assert client.get("/api/v1/simbehaviour").status_code == 200
    assert client.get("/api/v1/health/live").status_code == 200
    assert client.post("/api/v1/python_call", json={"flag": "setup_keys"}).status_code == 200


def test_noresponse_blocks_python_call_too(healthy_mode, monkeypatch):
    pytest.importorskip("httpx", reason="httpx is required for TestClient")
    monkeypatch.setattr(simbehaviour_service, "_forward_to_elixir", lambda mode: None)
    client = _simbehaviour_client()

    assert client.post("/api/v1/simbehaviour/noresponse").status_code == 200

    assert client.get("/api/v1/chain/history").status_code == 503
    assert client.post("/api/v1/python_call", json={"flag": "setup_keys"}).status_code == 503
    # Control plane stays reachable so tests can recover the node.
    assert client.get("/api/v1/simbehaviour").status_code == 200
    assert client.get("/api/v1/health/live").status_code == 200


def test_byzantine_drops_transactions_and_forges_signatures(db, validator_keys, healthy_mode, monkeypatch):
    from app.services import distributed_service

    monkeypatch.setattr(simbehaviour_service, "_forward_to_elixir", lambda mode: None)
    simbehaviour_service.set_mode(simbehaviour_service.BIZANTINE)
    try:
        # Transactions are dropped (never stored) and acknowledged as forged.
        transaction = make_transaction()
        result = distributed_service.submit_transaction(db, transaction)
        assert result.get("forged") is True
        assert db.get(PendingTransaction, transaction["tx_id"]) is None

        # Signatures/keys are forged: honest verification must fail.
        content = {"hello": "world"}
        forged_signature = distributed_service.sign_payload(content)
        assert distributed_service.verify_validator_signature("node_a", content, forged_signature) is False
        assert distributed_service.local_public_key() != json.loads(settings.validator_public_keys)["node_a"]
    finally:
        simbehaviour_service.set_mode(simbehaviour_service.HEALTHY)
