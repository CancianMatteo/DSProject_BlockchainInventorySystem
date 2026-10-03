from __future__ import annotations

from pathlib import Path
from typing import Any

import uvicorn

from app.core.config import settings


def _require_file(path_value: str | None, env_name: str) -> str:
    if not path_value:
        raise RuntimeError(f"{env_name} is required when TLS is enabled")

    path = Path(path_value)
    if not path.is_file():
        raise RuntimeError(f"{env_name} points to a missing file: {path_value}")

    return str(path)


def main() -> None:
    ssl_kwargs: dict[str, Any] = {}

    if settings.tls_required:
        ssl_kwargs["ssl_keyfile"] = _require_file(settings.tls_keyfile, "TLS_KEYFILE")
        ssl_kwargs["ssl_certfile"] = _require_file(settings.tls_certfile, "TLS_CERTFILE")
        if settings.tls_ca_certs:
            ssl_kwargs["ssl_ca_certs"] = _require_file(settings.tls_ca_certs, "TLS_CA_CERTS")

    uvicorn.run(
        "app.main:app",
        host=settings.api_host,
        port=settings.api_port,
        proxy_headers=settings.proxy_headers,
        forwarded_allow_ips=settings.forwarded_allow_ips,
        **ssl_kwargs,
    )


if __name__ == "__main__":
    main()
