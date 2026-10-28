#!/usr/bin/env python3
"""Create the local Compose and Python environment files."""

import base64
import getpass
import json
import os
import re
import secrets
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent
ROOT_ENV = ROOT / ".env"
PYTHON_ENV = ROOT / "Server_Python" / ".env"
PYTHON_ENV_EXAMPLE = ROOT / "Server_Python" / ".env.example"
NODE_IDS = ("node_a", "node_b", "node_c", "node_d")


def read_env(path: Path) -> dict[str, str]:
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            name, value = line.split("=", 1)
            values[name.strip()] = value.strip().strip("\"'")
    return values


def make_keypair(openssl: str, directory: Path, node_id: str) -> tuple[str, str]:
    private_path = directory / f"{node_id}.pem"
    private_path.touch(mode=0o600)
    subprocess.run(
        [openssl, "genpkey", "-algorithm", "ED25519", "-out", str(private_path)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    private_path.chmod(0o600)
    private_der = subprocess.run(
        [openssl, "pkey", "-in", str(private_path), "-outform", "DER"],
        check=True,
        capture_output=True,
    ).stdout
    public_der = subprocess.run(
        [openssl, "pkey", "-in", str(private_path), "-pubout", "-outform", "DER"],
        check=True,
        capture_output=True,
    ).stdout
    if len(private_der) < 32 or len(public_der) < 32:
        raise RuntimeError(f"OpenSSL returned an invalid Ed25519 key for {node_id}")
    return (
        base64.b64encode(private_der[-32:]).decode("ascii"),
        base64.b64encode(public_der[-32:]).decode("ascii"),
    )


def generate_root_env(openssl: str) -> dict[str, str]:
    with tempfile.TemporaryDirectory(prefix="blockchain-keys-") as temp_dir:
        key_dir = Path(temp_dir)
        os.chmod(key_dir, 0o700)
        keypairs = {
            node_id: make_keypair(openssl, key_dir, node_id)
            for node_id in NODE_IDS
        }

    values = {
        f"NODE_{node_id[-1].upper()}_PRIVATE_KEY": keypairs[node_id][0]
        for node_id in NODE_IDS
    }
    values["VALIDATOR_PUBLIC_KEYS"] = json.dumps(
        {node_id: keypairs[node_id][1] for node_id in NODE_IDS},
        separators=(",", ":"),
    )
    values["JWT_SECRET"] = secrets.token_urlsafe(48)
    values["HOST_UID"] = str(os.getuid()) if hasattr(os, "getuid") else "1000"
    values["HOST_GID"] = str(os.getgid()) if hasattr(os, "getgid") else "1000"
    return values


def write_env_file(path: Path, content: str) -> None:
    old_umask = os.umask(0o077)
    try:
        path.write_text(content, encoding="utf-8")
        path.chmod(0o600)
    finally:
        os.umask(old_umask)


def prompt_admin_credentials() -> tuple[str, str]:
    while True:
        email = input("Admin email: ").strip()
        if re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", email):
            break
        print("Enter a valid email address.")

    while True:
        password = getpass.getpass("Admin password (at least 12 characters): ")
        if len(password) < 12:
            print("Password must contain at least 12 characters.")
            continue
        confirmation = getpass.getpass("Confirm admin password: ")
        if password == confirmation:
            return email, password
        print("Passwords do not match.")


def main() -> None:
    try:
        openssl = shutil.which("openssl")
        if not openssl:
            raise RuntimeError("OpenSSL is required. Install it, then run this script again.")

        if ROOT_ENV.exists():
            root_values = read_env(ROOT_ENV)
            required = {
                *(f"NODE_{letter}_PRIVATE_KEY" for letter in "ABCD"),
                "VALIDATOR_PUBLIC_KEYS",
                "JWT_SECRET",
            }
            missing = sorted(required - root_values.keys())
            if missing:
                raise RuntimeError(
                    f"{ROOT_ENV.name} already exists but is missing required settings. "
                    "Keep your existing file and add its static keys, or back it up "
                    "before running setup again."
                )
            root_values["VALIDATOR_PUBLIC_KEYS"] = json.dumps(
                json.loads(root_values["VALIDATOR_PUBLIC_KEYS"])
            )
        else:
            root_values = None

        if not PYTHON_ENV.exists():
            if not PYTHON_ENV_EXAMPLE.exists():
                raise RuntimeError("Server_Python/.env.example was not found.")
            admin_email, admin_password = prompt_admin_credentials()

        if root_values is None:
            root_values = generate_root_env(openssl)
            write_env_file(
                ROOT_ENV,
                "".join(f"{key}={value}\n" for key, value in root_values.items()),
            )
            print(f"Created {ROOT_ENV.relative_to(ROOT)}")

        if not PYTHON_ENV.exists():
            template = PYTHON_ENV_EXAMPLE.read_text(encoding="utf-8")
            template = template.replace(
                "INITIAL_ADMIN_EMAIL=admin@example.com",
                f"INITIAL_ADMIN_EMAIL={admin_email}",
            ).replace(
                "INITIAL_ADMIN_PASSWORD=CHANGE_THIS_TO_A_LONG_RANDOM_PASSWORD",
                f"INITIAL_ADMIN_PASSWORD={admin_password}",
            )
            write_env_file(PYTHON_ENV, template)
            print(f"Created {PYTHON_ENV.relative_to(ROOT)}")
        else:
            print(f"Kept existing {PYTHON_ENV.relative_to(ROOT)}")

        print("Setup complete. Start the cluster with: docker compose up -d --build")
    except (OSError, ValueError, subprocess.CalledProcessError, RuntimeError) as exc:
        raise SystemExit(f"Setup failed: {exc}") from exc


if __name__ == "__main__":
    main()
