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
from app.db.models import PendingTransaction
from app.db.session import Base
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
