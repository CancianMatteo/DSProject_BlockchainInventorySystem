from contextlib import asynccontextmanager
import json

from fastapi import FastAPI
from app.api.routes_auth import router as auth_router
from app.api.routes_chain import router as chain_router
from app.api.routes_health import router as health_router
from app.api.routes_notifications import router as notifications_router
from app.api.routes_python import router as python_router
from app.api.routes_users import router as users_router
from app.core.config import settings
from app.core.exceptions import install_exception_handlers
from app.core.logging import configure_logging
from app.db import repositories
from app.db.session import Base, SessionLocal, engine
from app.services.cache_service import inventory_cache
from app.services import user_service


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

    yield


app = FastAPI(title="Blockchain Inventory System Backend", lifespan=lifespan)
install_exception_handlers(app)


app.include_router(auth_router, prefix=settings.api_prefix)
app.include_router(notifications_router, prefix=settings.api_prefix)
app.include_router(users_router, prefix=settings.api_prefix)
app.include_router(chain_router, prefix=settings.api_prefix)
app.include_router(python_router, prefix=settings.api_prefix)
app.include_router(health_router, prefix=settings.api_prefix)
