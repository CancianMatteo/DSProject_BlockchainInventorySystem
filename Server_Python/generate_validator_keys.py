#!/usr/bin/env python3

import argparse
import base64
import json
import os
import secrets
import shutil
import subprocess
import tempfile
from pathlib import Path


def generate_keypair() -> tuple[bytes, bytes]:
    with tempfile.TemporaryDirectory() as temporary_directory:
        private_key_path = Path(temporary_directory) / "validator.pem"
        subprocess.run(
            ["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(private_key_path)],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        private_der = subprocess.run(
            ["openssl", "pkey", "-in", str(private_key_path), "-outform", "DER"],
            check=True,
            capture_output=True,
        ).stdout
        public_der = subprocess.run(
            [
                "openssl",
                "pkey",
                "-in",
                str(private_key_path),
                "-pubout",
                "-outform",
                "DER",
            ],
            check=True,
            capture_output=True,
        ).stdout

    private_seed = private_der[-32:]
    public_key = public_der[-32:]
    if len(private_seed) != 32 or len(public_key) != 32:
        raise RuntimeError("OpenSSL returned an invalid Ed25519 key pair")
    return private_seed, public_key


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Create a local environment file with fresh BFT validator keys."
    )
    repository_root = Path(__file__).resolve().parents[1]
    parser.add_argument(
        "--output",
        type=Path,
        default=repository_root / ".env",
        help="Output file (default: repository root .env)",
    )
    args = parser.parse_args()
    output = args.output
    if output.exists():
        parser.error(f"{output} already exists; refusing to overwrite validator secrets")
    if shutil.which("openssl") is None:
        parser.error("OpenSSL is required to generate validator keys")

    private_keys = {}
    public_keys = {}
    for node_id in ("node_a", "node_b", "node_c", "node_d"):
        private_keys[node_id], public_keys[node_id] = generate_keypair()
    admin_password = secrets.token_urlsafe(24)
    public_roster = {
        node_id: base64.b64encode(public_key).decode("ascii")
        for node_id, public_key in public_keys.items()
    }
    lines = [
        f"APP_CLIENT_TOKEN={secrets.token_urlsafe(32)}",
        f"JWT_SECRET={secrets.token_urlsafe(48)}",
        "INITIAL_ADMIN_EMAIL=admin@example.com",
        f"INITIAL_ADMIN_PASSWORD={admin_password}",
        f"VALIDATOR_PUBLIC_KEYS={json.dumps(public_roster, separators=(',', ':'))}",
    ]
    for node_id, seed in private_keys.items():
        lines.append(
            f"{node_id.upper()}_PRIVATE_KEY={base64.b64encode(seed).decode('ascii')}"
        )

    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as file:
        file.write("\n".join(lines) + "\n")
    print(f"Created {output} with owner-only permissions. Keep it out of version control.")
    print("Initial admin email: admin@example.com")
    print(f"Initial admin password: {admin_password}")


if __name__ == "__main__":
    main()
