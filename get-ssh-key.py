#!/usr/bin/env python3
"""
Print a local SSH public key, or create one if no usable public key exists.

This script is meant to be run from a one-line command such as:
  curl -fsSL https://raw.githubusercontent.com/baoyuy/linux-server-hardening/main/get-ssh-key.py | python3 -
"""

from __future__ import annotations

import getpass
import os
from pathlib import Path
import platform
import shutil
import socket
import stat
import subprocess
import sys


VALID_PUBLIC_KEY_PREFIXES = (
    "ssh-ed25519",
    "sk-ssh-ed25519@openssh.com",
    "ecdsa-sha2-",
    "sk-ecdsa-sha2-nistp256@openssh.com",
    "ssh-rsa",
)

PREFERRED_PUBLIC_KEYS = (
    "id_ed25519.pub",
    "id_ecdsa.pub",
    "id_rsa.pub",
)


def fail(message: str) -> None:
    print(f"[ERROR] {message}", file=sys.stderr)
    sys.exit(1)


def is_valid_public_key(line: str) -> bool:
    return line.startswith(VALID_PUBLIC_KEY_PREFIXES) and len(line.split()) >= 2


def read_public_key(path: Path) -> str | None:
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            key = line.strip()
            if key and is_valid_public_key(key):
                return key
    except OSError:
        return None
    except UnicodeDecodeError:
        return None
    return None


def find_existing_public_key(ssh_dir: Path) -> tuple[Path, str] | None:
    for name in PREFERRED_PUBLIC_KEYS:
        path = ssh_dir / name
        key = read_public_key(path)
        if key:
            return path, key

    try:
        public_keys = sorted(ssh_dir.glob("*.pub"))
    except OSError:
        return None

    for path in public_keys:
        key = read_public_key(path)
        if key:
            return path, key

    return None


def ensure_ssh_dir(ssh_dir: Path) -> None:
    try:
        ssh_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    except OSError as exc:
        fail(f"无法创建 SSH 目录: {ssh_dir}\n原因: {exc}")

    if os.name != "nt":
        try:
            ssh_dir.chmod(0o700)
        except OSError:
            pass


def run_ssh_keygen(args: list[str]) -> subprocess.CompletedProcess[str]:
    ssh_keygen = shutil.which("ssh-keygen")
    if not ssh_keygen:
        system_name = platform.system()
        if system_name == "Windows":
            fail(
                "ssh-keygen was not found. Install Windows OpenSSH Client, "
                "then run this command again."
            )
        if system_name == "Darwin":
            fail("ssh-keygen was not found. macOS normally includes it. Check your PATH.")
        fail("ssh-keygen was not found. Install openssh-client, then run this command again.")

    try:
        return subprocess.run(
            [ssh_keygen, *args],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except subprocess.CalledProcessError as exc:
        details = exc.stderr.strip() or exc.stdout.strip() or str(exc)
        fail(f"ssh-keygen failed:\n{details}")


def derive_public_key(private_key: Path, public_key: Path) -> tuple[Path, str] | None:
    if not private_key.exists() or public_key.exists():
        return None

    result = run_ssh_keygen(["-y", "-f", str(private_key)])
    key = result.stdout.strip()
    if not is_valid_public_key(key):
        return None

    try:
        public_key.write_text(f"{key}\n", encoding="utf-8")
        if os.name != "nt":
            public_key.chmod(0o644)
    except OSError as exc:
        fail(f"Could not write public key file: {public_key}\nReason: {exc}")

    return public_key, key


def generate_ed25519_key(ssh_dir: Path) -> tuple[Path, str]:
    private_key = ssh_dir / "id_ed25519"
    public_key = ssh_dir / "id_ed25519.pub"

    if private_key.exists():
        derived = derive_public_key(private_key, public_key)
        if derived:
            return derived
        fail(
            f"A private key already exists, but no usable public key was found: {private_key}\n"
            "This script will not overwrite it. Check it manually, or back it up first."
        )

    comment = f"{getpass.getuser()}@{socket.gethostname()}"
    run_ssh_keygen(["-t", "ed25519", "-C", comment, "-f", str(private_key), "-N", ""])

    if os.name != "nt":
        try:
            private_key.chmod(stat.S_IRUSR | stat.S_IWUSR)
            public_key.chmod(0o644)
        except OSError:
            pass

    key = read_public_key(public_key)
    if not key:
        fail(f"The key was generated, but the public key could not be read: {public_key}")

    return public_key, key


def main() -> None:
    home = Path.home()
    ssh_dir = home / ".ssh"
    ensure_ssh_dir(ssh_dir)

    existing = find_existing_public_key(ssh_dir)
    created = False
    if existing:
        public_key_path, public_key = existing
    else:
        public_key_path, public_key = generate_ed25519_key(ssh_dir)
        created = True

    action = "Created a new SSH public key" if created else "Found an existing SSH public key"
    print(action)
    print(f"Public key file: {public_key_path}")
    if created:
        print("Note: the new SSH private/public key files are kept on this computer.")
        print("You need them for future SSH login.")
    print()
    print("Copy the full line below into the server hardening script when it asks for SSH public key:")
    print(public_key)


if __name__ == "__main__":
    main()
