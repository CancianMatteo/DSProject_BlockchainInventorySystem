"""Simulated node behaviour (fault injection for testing).

Modes (volatile, reset to ``healthy`` on restart):

* ``healthy``    - normal behaviour (default);
* ``noclients``  - the node still talks to peer nodes (transaction
  approvals, block votes) but does not answer clients;
* ``noresponse`` - the node talks to nobody (cluster traffic is dropped
  on the Elixir side, every Python endpoint except ``simbehaviour`` and
  ``health`` answers 503);
* ``bizantine``  - byzantine behaviour: transactions received from clients
  are not forwarded to peers, and proposals/votes/transactions are
  forged so honest nodes reject them.

The mode is shared with the Elixir consensus engine: every change is
forwarded (best-effort) to the co-located Elixir HTTP listener at
``POST /api/v1/simbehaviour`` so both halves of the node apply the same
mode. The Elixir side stores it in ``InventoryNode.SimBehaviour``.
"""

from __future__ import annotations

import logging
import threading

logger = logging.getLogger(__name__)

HEALTHY = "healthy"
NOCLIENTS = "noclients"
NORESPONSE = "noresponse"
BIZANTINE = "bizantine"

MODES = (HEALTHY, NOCLIENTS, NORESPONSE, BIZANTINE)

_lock = threading.Lock()
_mode: str = HEALTHY


def get_mode() -> str:
    with _lock:
        return _mode


def set_mode(mode: str) -> str:
    """Set the simulated-behaviour mode and forward it to the Elixir node."""
    if mode not in MODES:
        raise ValueError(f"Unknown simbehaviour mode: {mode!r}. Allowed: {list(MODES)}")
    with _lock:
        global _mode
        _mode = mode
    _forward_to_elixir(mode)
    return mode


def is_healthy() -> bool:
    return get_mode() == HEALTHY


def is_byzantine() -> bool:
    return get_mode() == BIZANTINE


def _forward_to_elixir(mode: str) -> None:
    """Best-effort propagation of the mode to the Elixir HTTP listener.

    The Python backend must stay usable (especially the simbehaviour
    endpoints themselves) even when the Elixir side is unreachable, so
    every failure is logged and swallowed.
    """
    try:
        from app.core.config import settings
    except Exception:  # pragma: no cover - defensive
        return
    host = (settings.elixir_host or "").strip()
    if not host:
        return
    try:
        import httpx

        url = f"http://{host}:{settings.elixir_http_port}/api/v1/simbehaviour"
        with httpx.Client(timeout=3.0) as client:
            response = client.post(url, json={"mode": mode})
        if response.status_code != 200:
            logger.warning("Elixir simbehaviour forward failed: HTTP %s: %s", response.status_code, response.text)
    except Exception as exc:  # noqa: BLE001 - best effort by design
        logger.warning("Elixir simbehaviour forward failed: %s", exc)
