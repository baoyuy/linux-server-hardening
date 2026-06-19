# Auto-Full Second-Step Design

Date: 2026-06-19

## Goal

Add an explicit one-command "full automatic" mode for step 2 hardening so the user can run all supported hardening actions without answering each confirmation prompt one by one.

The new mode must be obvious, intentional, and separate from the existing interactive flow.

## Problem

The current second-step script already has:

- default sequential execution
- `--menu` for choose-your-own steps
- `--one-shot` for non-interactive execution

But this behavior is not presented as a clear user-facing "one-click full automatic" product feature. For a new user, it is still ambiguous whether step 2 supports:

- fully automatic execution
- which prompts are skipped
- whether high-risk items such as SSH hardening and nftables are included

The requested behavior is stricter: one explicit mode that performs the complete tutorial-style second step directly, without per-step confirmation.

## Scope

This change affects:

- `harden.sh`
- `README.md`

This change does not alter:

- step 1 reinstall behavior
- the actual hardening checklist order
- the existing `--menu` interactive selection flow

## Product Behavior

### New Explicit Mode

Add a new CLI option:

```bash
bash harden.sh --auto-full
```

This mode means:

- run the full second-step hardening flow in order
- do not show the menu
- do not pause for `y/N` confirmations
- do include the high-risk tutorial steps such as SSH hardening and nftables

This is a deliberate "full automatic" mode, not a hidden side effect of the default command.

### Execution Defaults in `--auto-full`

When `--auto-full` is used, the script should:

- auto-elevate with `sudo` exactly like other modes
- auto-detect and reuse the current SSH port
- auto-detect and reuse the current login user as the daily sudo user
- avoid re-prompting for SSH public key if the current login user is reused
- assume `Cloudflare web = yes` unless a config file explicitly overrides it
- run the same ordered hardening steps as the current all-steps flow

Step order remains:

1. basic packages
2. sudo user maintenance
3. SSH hardening
4. IPv6 route check
5. Debian cloud kernel step
6. Docker
7. Nginx fallback
8. ZRAM and swap
9. fstrim
10. Chrony
11. nftables
12. Fail2ban

### Existing Modes Stay Intact

The existing entrypoints should remain valid:

- `bash harden.sh` keeps the current guided interactive behavior
- `bash harden.sh --menu` keeps the choose-your-own behavior
- existing automation options continue to work for config-driven execution

The new mode is an additive UX improvement, not a replacement.

## CLI and Help Text

`--help` output should clearly describe:

- `--auto-full` as "full automatic second-step hardening"
- that it includes SSH hardening and nftables
- that it assumes the server's websites are behind Cloudflare unless config overrides it

If `--one-shot` remains in the script, help text should distinguish it from `--auto-full` so users understand which option is the recommended direct entrypoint.

## UX Rules

In `--auto-full`:

- no per-step `y/N` questions
- no typed danger confirmations
- no menu
- no repeated setup questions for current user and current SSH port

The script should still print section headers and normal progress output so the user can see what is happening.

## Documentation

README should add a clear "step 2 one-command full automatic" example, for example:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
curl -fsSLO https://raw.githubusercontent.com/baoyuy/linux-server-hardening/main/harden.sh
chmod +x harden.sh
bash ./harden.sh --auto-full
```

README must also state clearly that this mode includes:

- SSH hardening
- nftables with Cloudflare-only 80/443 policy
- Fail2ban

## Validation

Required checks:

- `bash -n harden.sh`
- `bash harden.sh --help` documents `--auto-full`
- test-server run of the second-step auto-full mode completes
- final summary shows the normal completed steps

## Risks

- `--auto-full` intentionally applies the strict firewall profile; this can block business traffic if the user's site is not actually behind Cloudflare.
- `--auto-full` intentionally applies SSH hardening; if the detected current login state is wrong, it can still lock a user out.

These are acceptable because this mode is explicitly named as the full automatic version and is opt-in.

## Non-Goals

- changing the default `bash harden.sh` behavior to become non-interactive
- removing `--menu`
- weakening the full automatic mode by silently skipping SSH hardening or nftables
