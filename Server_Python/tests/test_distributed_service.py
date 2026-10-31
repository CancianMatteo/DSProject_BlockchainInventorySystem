import base64
import hashlib
import json
import uuid
from datetime import datetime, timezone

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from sqlalchemy import create_engine, inspect, text
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from app.core.config import settings
from app.api.routes_chain import get_chain_history
from app.db.models import BlockVote, PendingTransaction
from app.db.repositories import insert_block
from app.db.session import Base
from app.services import simbehaviour_service
from app.services.cache_service import inventory_cache
from app.services.distributed_service import (
    DistributedReject,
    build_proposal,
    canonical_json,
    chain_state,
    chain_from,
    commit_block,
    create_pre_prepare_conflict_proof,
    get_finalized_block,
    import_block,
    prepare_proposal,
    submit_transaction,
    transaction_status,
    verify_prepare_certificate,
    verify_pre_prepare,
    verify_pre_prepare_conflict_proof,
    verify_vote,
    verify_commit_certificate,
    write_committed_block,
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
) -> dict:
    private_key = Ed25519PrivateKey.generate()
    public_key = private_key.public_key().public_bytes(
        serialization.Encoding.Raw,
        serialization.PublicFormat.Raw,
    )
    transaction = {
        "client_ID": "operator@example.test",
        "item_id": item_id,
        "quantity": quantity,
        "location": "warehouse-1",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "trans_id": str(uuid.uuid4()),
        "client_public_key": base64.b64encode(public_key).decode("ascii"),
        "item_catalog": {
            item_id: {
                "itemName": "Sample",
                "brand": "Brand",
                "category": "General",
            }
        } if quantity > 0 else {},
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


def make_finalization_certificate(
    block: dict,
    keys: dict[str, Ed25519PrivateKey],
    phase: str = "commit",
) -> tuple[str, str, list[dict]]:
    validator_ids = sorted(keys)
    proposer_id = validator_ids[(block["height"] + block["round"]) % len(validator_ids)]
    proposer_payload = {
        "height": block["height"],
        "round": block["round"],
        "proposer_id": proposer_id,
        "block_hash": block["block_hash"],
    }
    proposer_signature = base64.b64encode(
        keys[proposer_id].sign(canonical_json(proposer_payload))
    ).decode("ascii")
    votes = []
    for validator_id in validator_ids[:3]:
        vote_payload = {
            "phase": phase,
            "height": block["height"],
            "round": block["round"],
            "validator_id": validator_id,
            "block_hash": block["block_hash"],
        }
        votes.append({
            "validator_id": validator_id,
            "signature": base64.b64encode(
                keys[validator_id].sign(canonical_json(vote_payload))
            ).decode("ascii"),
        })
    return proposer_id, proposer_signature, votes


def test_submit_is_idempotent_and_requires_valid_client_signature(db):
    transaction = make_transaction()
    accepted = submit_transaction(db, transaction)
    duplicate = submit_transaction(db, transaction)

    assert accepted["status"] == "pending"
    assert duplicate["duplicate"] is True
    assert db.get(PendingTransaction, transaction["trans_id"]).status == "pending"

    tampered = make_transaction()
    tampered["quantity"] += 1
    with pytest.raises(DistributedReject, match="Cryptographic signature is invalid"):
        submit_transaction(db, tampered)


def test_block_is_finalized_only_with_three_distinct_valid_votes(db, validator_keys):
    assert chain_state(db) == {"next_height": 1}
    transaction = make_transaction()
    submit_transaction(db, transaction)
    proposal = build_proposal(db, 0)["block"]
    assert proposal is not None
    assert build_proposal(db, 0)["block"] == proposal

    with pytest.raises(DistributedReject, match="At least 3 distinct"):
        commit_block(db, proposal, make_votes(proposal, validator_keys)[:2])

    result = commit_block(db, proposal, make_votes(proposal, validator_keys))

    assert result["height"] == 1
    assert chain_state(db) == {"next_height": 2}
    assert transaction_status(db, transaction["trans_id"])["status"] == "finalized"
    assert inventory_cache.items["item-1"]["quantity"] == 5


def test_finalized_block_persists_commit_certificate_and_import_is_idempotent(
    db, validator_keys
):
    transaction = make_transaction()
    submit_transaction(db, transaction)
    block = build_proposal(db, 0)["block"]
    proposer_id, proposer_signature, commit_signatures = make_finalization_certificate(
        block, validator_keys
    )
    certificate = {
        "block_data": block,
        "proposer_id": proposer_id,
        "proposer_signature": proposer_signature,
        "commit_signatures": commit_signatures,
    }

    assert verify_commit_certificate(certificate)
    assert not verify_commit_certificate({
        **certificate,
        "commit_signatures": commit_signatures[:2],
    })
    assert write_committed_block(
        db, block, proposer_id, proposer_signature, commit_signatures
    ) == {"status": True}

    stored_votes = db.query(BlockVote).filter_by(block_hash=block["block_hash"]).all()
    assert len(stored_votes) == 3
    assert {vote.phase for vote in stored_votes} == {"commit"}
    recovered = get_finalized_block(db, block["height"])
    assert recovered["status"] is True
    assert recovered["proposer_id"] == proposer_id
    assert recovered["proposer_signature"] == proposer_signature
    assert len(recovered["commit_signatures"]) == 3
    assert write_committed_block(
        db, block, proposer_id, proposer_signature, commit_signatures
    ) == {"status": True, "duplicate": True}


def test_finalized_block_rejects_prepare_signatures_as_commit_certificate(
    db, validator_keys
):
    transaction = make_transaction()
    submit_transaction(db, transaction)
    block = build_proposal(db, 0)["block"]
    proposer_id, proposer_signature, prepare_signatures = make_finalization_certificate(
        block, validator_keys, phase="prepare"
    )
    certificate = {
        "block_data": block,
        "proposer_id": proposer_id,
        "proposer_signature": proposer_signature,
        "commit_signatures": prepare_signatures,
    }

    assert not verify_commit_certificate(certificate)
    with pytest.raises(DistributedReject, match="COMMIT signature is invalid"):
        write_committed_block(
            db, block, proposer_id, proposer_signature, prepare_signatures
        )


def test_finalized_commit_certificate_imports_on_a_lagging_node(db, validator_keys):
    transaction = make_transaction()
    submit_transaction(db, transaction)
    block = build_proposal(db, 0)["block"]
    proposer_id, proposer_signature, commit_signatures = make_finalization_certificate(
        block, validator_keys
    )
    lagging_engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
        future=True,
    )
    Base.metadata.create_all(lagging_engine)

    try:
        with Session(lagging_engine, autoflush=False, future=True) as lagging_db:
            inventory_cache.reset()
            result = write_committed_block(
                lagging_db,
                block,
                proposer_id,
                proposer_signature,
                commit_signatures,
            )

            assert result == {"status": True}
            assert chain_state(lagging_db) == {"next_height": 2}
            assert {
                vote.phase
                for vote in lagging_db.query(BlockVote)
                .filter_by(block_hash=block["block_hash"])
                .all()
            } == {"commit"}
    finally:
        inventory_cache.reset()
        Base.metadata.drop_all(lagging_engine)
        lagging_engine.dispose()


def test_block_vote_phase_migration_preserves_existing_votes(monkeypatch):
    legacy_engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
        future=True,
    )
    with legacy_engine.begin() as connection:
        connection.execute(text(
            """
            CREATE TABLE block_votes (
                id INTEGER NOT NULL PRIMARY KEY,
                height INTEGER NOT NULL,
                round INTEGER NOT NULL,
                block_hash VARCHAR(128) NOT NULL,
                validator_id VARCHAR(128) NOT NULL,
                signature TEXT NOT NULL,
                CONSTRAINT uq_block_votes_height_round_validator
                    UNIQUE (height, round, validator_id)
            )
            """
        ))
        connection.execute(text(
            """
            INSERT INTO block_votes
                (id, height, round, block_hash, validator_id, signature)
            VALUES (1, 1, 0, 'legacy-hash', 'node_a', 'legacy-signature')
            """
        ))

    try:
        from app import main

        monkeypatch.setattr(main, "engine", legacy_engine)
        main._migrate_block_vote_phase()

        with Session(legacy_engine) as migrated_db:
            vote = migrated_db.get(BlockVote, 1)
            assert vote is not None
            assert vote.signature == "legacy-signature"
            assert vote.phase == "prepare"
        assert "phase" in {
            column["name"] for column in inspect(legacy_engine).get_columns("block_votes")
        }
    finally:
        legacy_engine.dispose()


def test_rejects_duplicate_validator_votes(db, validator_keys):
    transaction = make_transaction()
    submit_transaction(db, transaction)
    proposal = build_proposal(db, 0)["block"]
    votes = make_votes(proposal, validator_keys)
    votes[-1] = votes[0]

    with pytest.raises(DistributedReject, match="At least 3 distinct"):
        commit_block(db, proposal, votes)


def test_compact_conflict_proof_requires_two_proposer_signatures(validator_keys):
    height = 1
    round_number = 0
    proposer_id = "node_b"
    hashes = ("hash-forged", "hash-conflicting")
    signatures = [
        base64.b64encode(
            validator_keys[proposer_id].sign(
                canonical_json({
                    "height": height,
                    "round": round_number,
                    "proposer_id": proposer_id,
                    "block_hash": block_hash,
                })
            )
        ).decode("ascii")
        for block_hash in hashes
    ]
    proof = create_pre_prepare_conflict_proof({
        "height": height,
        "round": round_number,
        "proposer_id": proposer_id,
        "validator_id": "node_a",
        "forged_block_hash": hashes[0],
        "forged_signature": signatures[0],
        "conflicting_block_hash": hashes[1],
        "conflicting_signature": signatures[1],
    })

    assert proof is not None
    assert verify_pre_prepare_conflict_proof({**proof, "target_round": 1})
    assert not verify_pre_prepare_conflict_proof({
        **proof,
        "target_round": 1,
        "forged_block_hash": "tampered-hash",
    })


def test_prepare_certificate_binds_votes_to_the_block(db, validator_keys):
    submit_transaction(db, make_transaction())
    proposal = prepare_proposal(db, 3)
    block = proposal["block_data"]
    signatures = []
    for validator_id in ("node_a", "node_b", "node_c"):
        vote = {
            "phase": "prepare",
            "height": block["height"],
            "round": block["round"],
            "validator_id": validator_id,
            "block_hash": block["block_hash"],
        }
        signatures.append({
            "validator_id": validator_id,
            "signature": base64.b64encode(
                validator_keys[validator_id].sign(canonical_json(vote))
            ).decode("ascii"),
        })

    certificate = {
        "height": block["height"],
        "round": block["round"],
        "proposer_id": "node_a",
        "block_data": block,
        "signature": proposal["proposer_sign"],
        "signatures": signatures,
    }

    assert verify_prepare_certificate(certificate)
    assert not verify_prepare_certificate({
        **certificate,
        "signatures": [*signatures[:2], {**signatures[2], "signature": "invalid"}],
    })


def test_commit_vote_signature_is_bound_to_the_block(db, validator_keys):
    submit_transaction(db, make_transaction())
    proposal = prepare_proposal(db, 0)
    block = proposal["block_data"]
    vote = {
        "phase": "commit",
        "height": block["height"],
        "round": block["round"],
        "validator_id": "node_b",
        "block_hash": block["block_hash"],
        "signature": base64.b64encode(
            validator_keys["node_b"].sign(canonical_json({
                "phase": "commit",
                "height": block["height"],
                "round": block["round"],
                "validator_id": "node_b",
                "block_hash": block["block_hash"],
            }))
        ).decode("ascii"),
    }

    assert verify_vote("commit", vote)
    assert not verify_vote("commit", {**vote, "block_hash": "different-block"})


def test_rejects_outbound_transaction_exceeding_committed_stock(db, validator_keys):
    inbound = make_transaction(quantity=5)
    submit_transaction(db, inbound)
    proposal = build_proposal(db, 0)["block"]
    commit_block(db, proposal, make_votes(proposal, validator_keys))

    outbound = make_transaction(quantity=-6)
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
            assert transaction_status(target_db, transaction["trans_id"])["status"] == "finalized"
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
    response = client.post(
        "/api/v1/python_call",
        json={"flag": "pre_prepare"},
    )
    assert response.status_code == 200
    for removed_flag in ("setup_keys", "setup_keys_warning"):
        assert client.post(
            "/api/v1/python_call",
            json={"flag": removed_flag},
        ).status_code == 404


def test_noresponse_blocks_python_call_too(healthy_mode, monkeypatch):
    pytest.importorskip("httpx", reason="httpx is required for TestClient")
    monkeypatch.setattr(simbehaviour_service, "_forward_to_elixir", lambda mode: None)
    client = _simbehaviour_client()

    assert client.post("/api/v1/simbehaviour/noresponse").status_code == 200

    assert client.get("/api/v1/chain/history").status_code == 503
    assert client.post(
        "/api/v1/python_call",
        json={"flag": "pre_prepare"},
    ).status_code == 503
    # Control plane stays reachable so tests can recover the node.
    assert client.get("/api/v1/simbehaviour").status_code == 200
    assert client.get("/api/v1/health/live").status_code == 200


def test_byzantine_keeps_transactions_and_forges_consensus_signatures(
    db, healthy_mode, monkeypatch
):
    from app.services import distributed_service

    monkeypatch.setattr(simbehaviour_service, "_forward_to_elixir", lambda mode: None)
    monkeypatch.setenv("BIZANTINE_SCENARIO", "invalid_signature")
    simbehaviour_service.set_mode(simbehaviour_service.BIZANTINE)
    try:
        # Transactions remain valid mempool entries in Byzantine mode.
        transaction = make_transaction()
        result = distributed_service.submit_transaction(db, transaction)
        assert result["duplicate"] is False
        assert db.get(PendingTransaction, transaction["trans_id"]).status == "pending"

        # Consensus signatures are forged: honest verification must fail.
        content = {"hello": "world"}
        forged_signature = distributed_service.sign_payload(content)
        assert distributed_service.verify_validator_signature("node_a", content, forged_signature) is False

        proposal = prepare_proposal(db, 3)
        block = proposal["block_data"]
        hash_payload = {
            "height": block["height"],
            "prev_block_hash": block["prev_block_hash"],
            "transactions": block["transactions"],
        }
        assert hashlib.sha256(canonical_json(hash_payload)).hexdigest() == block["block_hash"]
        assert not verify_pre_prepare({
            "height": block["height"],
            "round": block["round"],
            "proposer_id": "node_a",
            "block_data": block,
            "signature": proposal["proposer_sign"],
        })
        assert db.get(PendingTransaction, transaction["trans_id"]).status == "pending"
    finally:
        simbehaviour_service.set_mode(simbehaviour_service.HEALTHY)


def test_byzantine_equivocation_creates_two_validly_signed_proposals(
    db, healthy_mode, monkeypatch, validator_keys
):
    from app.services import distributed_service

    monkeypatch.setattr(simbehaviour_service, "_forward_to_elixir", lambda mode: None)
    monkeypatch.setenv("BIZANTINE_SCENARIO", "equivocation")
    simbehaviour_service.set_mode(simbehaviour_service.BIZANTINE)
    try:
        submit_transaction(db, make_transaction(item_id="item-1"))
        submit_transaction(db, make_transaction(item_id="item-2"))
        proposal = prepare_proposal(db, 3)

        assert proposal["block_data"]["block_hash"] != proposal["equivocation_block_data"]["block_hash"]
        for block_data, signature in (
            (proposal["block_data"], proposal["proposer_sign"]),
            (proposal["equivocation_block_data"], proposal["equivocation_sign"]),
        ):
            assert verify_pre_prepare({
                "height": block_data["height"],
                "round": block_data["round"],
                "proposer_id": "node_a",
                "block_data": block_data,
                "signature": signature,
            })

        monkeypatch.setattr(settings, "node_id", "node_b")
        node_b_seed = validator_keys["node_b"].private_bytes(
            serialization.Encoding.Raw,
            serialization.PrivateFormat.Raw,
            serialization.NoEncryption(),
        )

        monkeypatch.setattr(
            settings,
            "validator_private_key",
            base64.b64encode(node_b_seed).decode("ascii"),
        )
        proof = distributed_service.create_pre_prepare_conflict_proof({
            "height": 1,
            "round": 3,
            "proposer_id": "node_a",
            "validator_id": "node_b",
            "forged_block_hash": proposal["block_data"]["block_hash"],
            "forged_signature": proposal["proposer_sign"],
            "conflicting_block_hash": proposal["equivocation_block_data"]["block_hash"],
            "conflicting_signature": proposal["equivocation_sign"],
        })
        assert proof is not None
        assert distributed_service.verify_pre_prepare_conflict_proof({
            **proof,
            "target_round": 4,
        })
    finally:
        simbehaviour_service.set_mode(simbehaviour_service.HEALTHY)


def test_equivocation_scenario_requires_two_pending_transactions(
    db, healthy_mode, monkeypatch
):
    monkeypatch.setattr(simbehaviour_service, "_forward_to_elixir", lambda mode: None)
    monkeypatch.setenv("BIZANTINE_SCENARIO", "equivocation")
    simbehaviour_service.set_mode(simbehaviour_service.BIZANTINE)
    try:
        submit_transaction(db, make_transaction())
        with pytest.raises(DistributedReject, match="requires at least two pending transactions"):
            prepare_proposal(db, 3)
    finally:
        simbehaviour_service.set_mode(simbehaviour_service.HEALTHY)


def test_proposal_contains_at_most_500_transactions(db):
    db.add_all(
        PendingTransaction(
            trans_id=f"tx-{index:04}",
            transaction_json=json.dumps(
                {
                    "trans_id": f"tx-{index:04}",
                    "quantity": 1,
                    "item_id": "item-1",
                }
            ),
            status="pending",
        )
        for index in range(501)
    )
    db.commit()

    block = build_proposal(db, 0)["block"]

    assert len(block["transactions"]) == 500
