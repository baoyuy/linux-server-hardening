# Two-Step Ubuntu Reinstall Design

Date: 2026-06-19

## Goal

Replace the current unreliable "reinstall plus automatic first-boot hardening" flow with a clear two-step Ubuntu-only flow:

1. Reinstall `Ubuntu 24.04 LTS`
2. Log in to the fresh system and run `harden.sh`

The key requirement is reliability. The reinstall step must not claim that hardening will run automatically after reboot.

## Problem

The current implementation passes `--cloud-data` to `bin456789/reinstall` and expects Ubuntu first boot to consume a `cloud-init` payload that writes and executes `harden.sh`.

This is not a safe assumption for the current Ubuntu reinstall path. A real server rebuilt through the project completed the OS reinstall but did not run any hardening steps. On that system:

- `cloud-init` was disabled by `/etc/cloud/cloud-init.disabled`
- `/root/harden.sh` did not exist
- `/root/linux-hardening.env` did not exist
- `/root/linux-hardening-firstboot.log` did not exist
- `git` and Docker packages were not installed

Therefore the current product promise is false: reinstall can succeed while the automatic hardening step never starts.

## Scope

This change affects:

- `reinstall-and-harden.sh`
- `README.md`
- `docs/design.md`

This change does not redesign `harden.sh` itself beyond documentation or message updates needed to fit the new flow.

## Product Behavior

### Step 1: Reinstall

`reinstall-and-harden.sh` becomes a reinstall-only entrypoint.

Supported target:

- `Ubuntu 24.04 LTS`

Collected inputs remain:

- SSH port
- non-root username
- SSH public key
- whether web traffic is fully proxied by Cloudflare

The script still performs destructive confirmation and still invokes the upstream reinstall tool, but it no longer:

- generates `cloud-init` `user-data`
- generates a `linux-hardening.env` first-boot payload
- passes `--cloud-data`
- claims that hardening will run automatically after reboot

At the end of the pre-reinstall phase, the script prints:

- the exact SSH login form for the fresh system
- the exact commands to run for step 2
- a reminder that missing `git` and Docker immediately after reinstall is expected

### Step 2: Hardening

`harden.sh` remains the hardening entrypoint and is run manually after the new Ubuntu system is reachable.

Primary documented flow:

```bash
apt-get update
apt-get install -y ca-certificates curl
curl -fsSLO https://raw.githubusercontent.com/baoyuy/linux-server-hardening/main/harden.sh
chmod +x harden.sh
sudo bash ./harden.sh
```

The interactive path remains the default recommendation.

## UX Changes

The repository must stop using wording such as:

- "first boot automatically runs hardening"
- "one-click reinstall plus hardening"

Replace it with explicit two-step wording throughout docs and prompts.

`reinstall-and-harden.sh` should explain that:

- step 1 only installs the operating system and login access
- step 2 installs packages and performs hardening
- seeing a fresh Ubuntu system without Docker or Git after reinstall is normal

## Validation

Required checks:

- `bash -n reinstall-and-harden.sh`
- `bash -n harden.sh`
- dry-run output from `reinstall-and-harden.sh` must not contain `--cloud-data`
- README command flow must match actual script behavior

## Risks

- Users who relied on the previous "automatic" promise will now need to perform an explicit second step.
- Some existing wording in docs may still imply automation unless updated consistently.

## Non-Goals

- Restoring multi-distro reinstall support
- Reintroducing automatic first-boot hardening for Ubuntu
- Changing the hardening checklist itself
