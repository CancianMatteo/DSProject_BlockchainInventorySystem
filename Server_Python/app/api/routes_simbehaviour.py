"""External fault-injection endpoints (testing purposes).

Each node exposes, on its Python backend:

* ``POST /api/v1/simbehaviour/healthy``    - normal behaviour (default);
* ``POST /api/v1/simbehaviour/noclients``  - talks to peers, ignores clients;
* ``POST /api/v1/simbehaviour/noresponse`` - talks to nobody;
* ``POST /api/v1/simbehaviour/bizantine``  - byzantine behaviour;
* ``GET  /api/v1/simbehaviour``            - current mode (convenience).

The mode is applied locally and forwarded to the co-located Elixir
consensus engine (``InventoryNode.SimBehaviour``).
"""

from fastapi import APIRouter

from app.services import simbehaviour_service

router = APIRouter(prefix="/simbehaviour", tags=["simbehaviour"])


def _apply(mode: str) -> dict:
    applied = simbehaviour_service.set_mode(mode)
    return {"ok": True, "mode": applied}


@router.get("")
def get_simbehaviour() -> dict:
    return {"ok": True, "mode": simbehaviour_service.get_mode()}


@router.post("/healthy")
def set_healthy() -> dict:
    return _apply(simbehaviour_service.HEALTHY)


@router.post("/noclients")
def set_noclients() -> dict:
    return _apply(simbehaviour_service.NOCLIENTS)


@router.post("/noresponse")
def set_noresponse() -> dict:
    return _apply(simbehaviour_service.NORESPONSE)


@router.post("/bizantine")
def set_bizantine() -> dict:
    return _apply(simbehaviour_service.BIZANTINE)
