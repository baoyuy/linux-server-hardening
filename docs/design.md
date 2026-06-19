# Design

## Goal

Build a beginner-friendly, interactive Linux server bootstrap and hardening script based on the LINUX DO guide:

<https://linux.do/t/topic/1549495>

The script should let a novice understand each hardening step before running it.

## Scope

The project provides a primary Bash entrypoint for step 1, reinstall only:

```bash
bash ./reinstall-and-harden.sh
```

It also keeps a hardening-only Bash entrypoint:

```bash
bash ./harden.sh
```

It also provides one helper script for the user's local computer:

```bash
curl -fsSL https://raw.githubusercontent.com/baoyuy/linux-server-hardening/4fd8be5f2a828d9dbaf790581ac0a2c88a7700c5/get-ssh-key.py | python3 -
```

It also provides a server-side SSH key append helper:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/baoyuy/linux-server-hardening/main/add-ssh-key.sh)
```

It also provides a server-side SSH key removal helper:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/baoyuy/linux-server-hardening/main/remove-ssh-key.sh)
```

The script covers:

- Ubuntu 24.04 LTS minimal as the only supported reinstall target.
- Destructive reinstall confirmation.
- `bin456789/reinstall` integration for OS reinstall only.
- Printed step-2 instructions for manual post-reinstall hardening.
- `--dry-run` preview mode for the reinstall entrypoint.
- Sudo user creation and optional SSH public key setup.
- SSH hardening.
- IPv6 route inspection.
- Debian cloud kernel installation.
- Base package installation.
- Docker installation.
- Nginx fallback server returning 444.
- ZRAM, swapfile, and swappiness.
- fstrim timer.
- UTC timezone and Chrony with Cloudflare NTP.
- nftables firewall rules.
- Fail2ban for SSH.
- Local SSH public key lookup/generation for Windows, macOS, and Linux.
- Server-side SSH public key appending with backup and permission repair.
- Server-side SSH public key removal with interactive selection, backup, and last-key confirmation.

## Safety Model

The script is intentionally not a silent one-click installer.

Every module explains:

- What it will do.
- Why it is useful.
- What can happen after execution.
- What the user must check first.

High-risk modules require typed confirmation phrases. Configuration files are copied to a timestamped backup directory before being changed.

The local SSH key helper is designed for one-line use. It reads existing public keys first, generates a new `id_ed25519` key only when needed, prints the public key, and does not leave a downloaded script file behind.

The helper prints ASCII English messages by default so that Windows PowerShell code pages do not corrupt Chinese text.

The server-side key append helper targets the current login user by default, asks for a username when running as root, validates the pasted public key, backs up `authorized_keys`, avoids duplicate keys, and repairs `.ssh` permissions.

The key removal helper lists keys from `authorized_keys`. Keys added by this project include a timestamp comment, so the helper can show an exact added time. Existing historical keys do not contain per-line timestamps, so the helper shows the file modification time and labels it as historical.

## Deliberate Limits

IPv6 static routes are not written automatically because gateway details vary by provider. The script inspects and explains instead.

Automatic first-boot hardening after Ubuntu reinstall is intentionally not used. The project now relies on a two-step flow because the previous cloud-init based handoff was not reliable in practice.

DD reinstall commands are not executed. The script only shows references and examples because a mistake can wipe the server.

The nftables web rules follow the guide's Cloudflare-only origin model. Users with direct web access or extra public services should skip or adapt that step.

## Validation

Validation should include:

- `bash -n reinstall-and-harden.sh`
- `bash -n harden.sh`
- `shellcheck` on both scripts when ShellCheck is available.
- Manual `--dry-run` smoke test on a disposable Ubuntu 24.04 VPS before real use.
