#!/usr/bin/env python3

import argparse
import base64
import json
import os
import secrets
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Create a local environment file with fresh BFT validator keys."
    )
    parser.add_argument("--output", default="../.env", help="Output file (default: repository .env)")
    args = parser.parse_args()
    output = Path(args.output)
    if output.exists():
        parser.error(f"{output} already exists; refusing to overwrite validator secrets")

    private_keys = {
        node_id: Ed25519PrivateKey.generate()
        for node_id in ("node_a", "node_b", "node_c", "node_d")
    }
    public_roster = {
        node_id: base64.b64encode(
            private_key.public_key().public_bytes(
                serialization.Encoding.Raw,
                serialization.PublicFormat.Raw,
            )
        ).decode("ascii")
        for node_id, private_key in private_keys.items()
    }
    lines = [
        f"INTERNAL_TOKEN={secrets.token_urlsafe(32)}",
        f"JWT_SECRET={secrets.token_urlsafe(48)}",
        f"VALIDATOR_PUBLIC_KEYS={json.dumps(public_roster, separators=(',', ':'))}",
    ]
    for node_id, private_key in private_keys.items():
        seed = private_key.private_bytes(
            serialization.Encoding.Raw,
            serialization.PrivateFormat.Raw,
            serialization.NoEncryption(),
        )
        lines.append(
            f"{node_id.upper()}_PRIVATE_KEY={base64.b64encode(seed).decode('ascii')}"
        )

    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as file:
        file.write("\n".join(lines) + "\n")
    print(f"Created {output} with owner-only permissions. Keep it out of version control.")


if __name__ == "__main__":
    main()
