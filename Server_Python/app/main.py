from contextlib import asynccontextmanager
import asyncio
import json

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from app.api.routes_auth import router as auth_router
from app.api.routes_chain import router as chain_router
from app.api.routes_health import router as health_router
from app.api.routes_python import router as python_router
from app.api.routes_simbehaviour import router as simbehaviour_router
from app.api.routes_users import router as users_router
from app.core.config import settings
from app.core.exceptions import install_exception_handlers
from app.core.logging import configure_logging
from app.db import repositories
from app.db.session import Base, SessionLocal, engine
from app.services.cache_service import inventory_cache
from app.services import distributed_service
from app.services import simbehaviour_service
from app.services import user_service


# Paths (relative to the API prefix) that stay reachable while a fault is
# injected. SimBehaviour itself must always stay reachable so a test can move
# the node back to ``healthy``; health probes stay reachable so the
# deploy script / load balancer can still observe the process.
_ALWAYS_ALLOWED_PREFIXES = (
    "/simbehaviour",
    "/health/live",
    "/health/ready",
)

# Intra-cluster traffic (Elixir consensus engine -> Python) that must keep
# working in ``noclients`` mode: the node still approves transactions and
# votes on blocks, it only ignores clients.
_NODE_TO_NODE_PREFIXES = (
    "/python_call",
)


def _relative_path(path: str) -> str:
    prefix = settings.api_prefix or ""
    if prefix and path.startswith(prefix):
        return path[len(prefix):] or "/"
    return path


@asynccontextmanager
async def lifespan(_: FastAPI):
    configure_logging()
    Base.metadata.create_all(bind=engine)

    db = SessionLocal()
    try:
        user_service.bootstrap_initial_admin(db)
        inventory_cache.reset()
        # Replay all blocks to rebuild inventory cache
        for block in repositories.get_all_blocks(db):
            raw_payload = json.loads(block.changes_json)
            if isinstance(raw_payload, dict) and "changes" in raw_payload:
                changes = raw_payload.get("changes", {})
                item_catalog = raw_payload.get("item_catalog", {})
            else:
                changes = raw_payload
                item_catalog = {}
            inventory_cache.apply_changes(changes, block.block_hash, block.n_block, item_catalog)
    finally:
        db.close()

    trigger_task = asyncio.create_task(_block_trigger_loop())
    try:
        yield
    finally:
        trigger_task.cancel()
        await asyncio.gather(trigger_task, return_exceptions=True)


async def _block_trigger_loop() -> None:
    while True:
        await asyncio.sleep(settings.block_trigger_interval_seconds)
        db = SessionLocal()
        try:
            distributed_service.trigger_block_if_ready(db, force=True)
        finally:
            db.close()


app = FastAPI(title="Blockchain Inventory System Backend", lifespan=lifespan)
install_exception_handlers(app)


@app.middleware("http")
async def simbehaviour_gate(request: Request, call_next):
    """Enforce the simulated-behaviour mode on the Python backend.

    * ``noclients``  - answer only health/simbehaviour/python_call, reject
      every client-facing endpoint with 503;
    * ``noresponse`` - answer only health/simbehaviour, reject everything
      else (including intra-cluster ``python_call``) with 503;
    * ``bizantine``  - requests are served normally; transaction handling is
      unchanged, while ``BIZANTINE_SCENARIO`` controls consensus fault
      injection (see ``distributed_service``).
    """
    rel = _relative_path(request.url.path)
    if request.method != "OPTIONS" and rel.startswith("/"):
        mode = simbehaviour_service.get_mode()
        if mode == simbehaviour_service.NORESPONSE:
            if not rel.startswith(_ALWAYS_ALLOWED_PREFIXES):
                return JSONResponse(
                    status_code=503,
                    content={
                        "ok": False,
                        "error": {
                            "code": "SIMBEHAVIOUR_NORESPONSE",
                            "message": "Node is in simulated noresponse mode",
                            "details": {"mode": mode},
                        },
                    },
                )
        elif mode == simbehaviour_service.NOCLIENTS:
            if not rel.startswith(_ALWAYS_ALLOWED_PREFIXES + _NODE_TO_NODE_PREFIXES):
                return JSONResponse(
                    status_code=503,
                    content={
                        "ok": False,
                        "error": {
                            "code": "SIMBEHAVIOUR_NOCLIENTS",
                            "message": "Node is in simulated noclients mode",
                            "details": {"mode": mode},
                        },
                    },
                )
    return await call_next(request)


app.include_router(auth_router, prefix=settings.api_prefix)
app.include_router(users_router, prefix=settings.api_prefix)
app.include_router(chain_router, prefix=settings.api_prefix)
app.include_router(python_router, prefix=settings.api_prefix)
app.include_router(health_router, prefix=settings.api_prefix)
app.include_router(simbehaviour_router, prefix=settings.api_prefix)
