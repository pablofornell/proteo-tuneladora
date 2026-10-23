# Tuneladora — Agent Instructions

Read `SPEC.md` for repository structure and `CLAUDE.md` for operating rules. Follow
their tiered machine-context reading, verification, secret handling and vault duties.

## Saved SSH access

- A configured machine alias is standing authorization to connect for the user's
  task. Connect autonomously with the saved management key; do not ask the user to
  approve ordinary SSH access, enter a password/passphrase, or unlock a keyring.
- Dedicated management keys are passphrase-free, owned by the operator and mode
  `0600`. Use `BatchMode yes`, `IdentitiesOnly yes`, `IdentityAgent none`,
  `AddKeysToAgent no`, `PasswordAuthentication no` and
  `KbdInteractiveAuthentication no` in their SSH configuration.
- Preserve verified host identities, the management account, ProxyJump and required
  VPN routes. Diagnose a failed noninteractive connection and use a documented
  parent fallback where available. Record unreachable or unconfigured machines
  honestly; verify a DHCP endpoint before adding an alias.
- One-time bootstrap is needed only when working saved access does not exist.
  Keep secrets out of Markdown and tool output; record their live locations only.
- Follow `CLAUDE.md` approval requirements for destructive operations, production
  service interruptions and firewall changes. Connect as the management account
  and escalate with `sudo`; root SSH remains prohibited.

## Working preferences

- Use English for code, commands, documentation and new vault entries; follow the
  operator's language in conversation.
- Prefer `rg` for searches. Delegate independent work when useful using native
  `researcher`, `implementer` and `reviewer` roles; keep integration and final
  verification in the main session.
- When the operator must run an administrative command, prepare a script in
  `/tmp/`, show its complete contents, use `set -euo pipefail` and numbered steps,
  verify the outcome, and give the exact command to run it.
