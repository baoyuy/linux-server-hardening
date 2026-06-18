# Design

## Goal

Build a beginner-friendly, interactive Linux server bootstrap and hardening script based on the LINUX DO guide:

<https://linux.do/t/topic/1549495?u=y0816>

The script should let a novice understand each hardening step before running it.

## Scope

The project provides one Bash entrypoint:

```bash
sudo ./harden.sh
```

The script covers:

- Reinstall/DD warning and reference commands only.
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

## Safety Model

The script is intentionally not a silent one-click installer.

Every module explains:

- What it will do.
- Why it is useful.
- What can happen after execution.
- What the user must check first.

High-risk modules require typed confirmation phrases. Configuration files are copied to a timestamped backup directory before being changed.

## Deliberate Limits

IPv6 static routes are not written automatically because gateway details vary by provider. The script inspects and explains instead.

DD reinstall commands are not executed. The script only shows references and examples because a mistake can wipe the server.

The nftables web rules follow the guide's Cloudflare-only origin model. Users with direct web access or extra public services should skip or adapt that step.

## Validation

Validation should include:

- `bash -n harden.sh`
- `shellcheck harden.sh` when ShellCheck is available.
- Manual `--dry-run` smoke test on a disposable Debian VPS before real use.
