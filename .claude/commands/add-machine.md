---
description: Drive workflows/ADD_MACHINE.md to onboard a new bare-metal machine or VM, stopping at each human handoff point. Phases 2 and 3 need the operator.
argument-hint: <name>
arguments: [name]
allowed-tools: Read, Grep, Glob, Bash, Agent(machine-operator, vault-writer)
---

# Add machine: `$name`

Drive `workflows/ADD_MACHINE.md`. **Read that file now** — it is the authority; this
command is the driver around it and marks where you must stop for the human.

Wrong workflow? Route first and stop:

| Target | Use instead |
|--------|-------------|
| LXC or Docker container | `/add-container $name --parent <p> --type lxc\|docker` |
| NAS, router, appliance with a proprietary OS | `workflows/ADD_NAS.md` |
| Bare-metal or VM | this command |

---

## Phase 1 — AGENT: scaffold

```bash
bash tools/new_machine.sh $name --type bare-metal
```

(For a VM: `--type vm --parent <host>`.)

It creates the folder, `STATE.md`, `CLAUDE.md`, `CONTEXT.md` and the canonical vault
set (`00_INDEX 01_SYSTEM_INFO 02_SERVICES 03_TASK_LOG 04_NOTES 05_SECURITY
06_BACKUPS 07_UPDATES`, plus `08_CONTAINERS.md` if this host will have children,
`09_TROUBLESHOOTING.md` optional, and `vault/archive/`).

Fill `STATE.md` with everything you already know and leave the rest honest:

```yaml
machine: $name
type: bare-metal
parent: null
container_id: null
connection: ssh
ssh_alias: $name
ip: <unknown until phase 2>
ip_assignment: <static | dhcp | dhcp-reservation>
status: unknown
os: <unknown>
depends_on: []
provides_to: []
backups: <unknown>
auto_updates: <unknown>
last_reconciled: <unset>
```

Log the scaffolding in `03_TASK_LOG.md` via `vault-writer`.

### ⏸ HANDOFF 1 — AGENT → HUMAN

Print the Phase 2 commands from `ADD_MACHINE.md`, filled in with `$name`, and
**stop**. Do not proceed on your own.

---

## Phase 2 — HUMAN: initial SSH with their personal user

The operator generates a personal key, `ssh-copy-id`s it, adds a temporary
`~/.ssh/config` entry, and verifies `ssh $name "echo ok"`.

**Wait for:** *"SSH ready for `$name`"*.

While waiting: do nothing. Do not poll, do not guess the IP, do not try to connect.

---

## Phase 3 — AGENT prepares, HUMAN executes one command

**Agent, locally:**

```bash
bash tools/setup_tuneladora_control.sh --machine $name
scp tools/setup_tuneladora_target.sh $name:/tmp/
```

The control script prints the public key and the exact command to hand over.

### ⏸ HANDOFF 2 — AGENT → HUMAN

Give the operator exactly one line to run on the target, with the real public key
substituted:

```bash
sudo bash /tmp/setup_tuneladora_target.sh --pubkey 'ssh-ed25519 AAAA...'
```

It creates the `tuneladora` user, configures **passwordless full sudo** (a deliberate,
confirmed operator decision — do not question it or propose narrowing it), sets up
`~/.ssh/`, installs the public key and locks the password.

**Wait for:** *"tuneladora user ready"*. Then, and only then, continue.

---

## Phase 4 — AGENT: harden, discover, finalise

Sequential first — each step depends on the previous:

1. Discover the LAN subnet dynamically (never hardcode it) and restrict
   `authorized_keys` with `from="<subnet>",no-agent-forwarding,no-X11-forwarding`,
   per `ADD_MACHINE.md`. Note in `04_NOTES.md` that a network change means re-applying it.
2. Update `~/.ssh/config` to `User tuneladora` + the dedicated `IdentityFile`.
   (You are authorised to edit `~/.ssh/config` during machine setup.)
3. Test: `ssh $name "whoami"` → must return `tuneladora`. **Never `root`.**
   If this fails, stop and report — do not work around it.

Then, in parallel — launch these as `machine-operator` subagents in a single message:

4. Discover system info → `01_SYSTEM_INFO.md`
5. Populate `CONTEXT.md` with real data (OS, purpose, network, quirks) — never leave
   a template
6. Record SSH key **fingerprints** and access policy → `05_SECURITY.md` (fingerprints
   and locations only; never key material, never a password value)

Then sequential again:

7. Configure automatic security updates with the OS-appropriate tool → `07_UPDATES.md`
8. Verify or configure a backup job → `06_BACKUPS.md`. "no backup — intentional" is a
   valid and required entry when that is the truth.
9. Complete `STATE.md` — `ip`, `ip_assignment`, `status: running`, `os`, `backups`,
   `auto_updates`, `last_reconciled` — and keep `00_INDEX.md`'s status block
   consistent with it. Do not restate those facts in prose elsewhere.
10. Write `CLAUDE.md` with the real machine-specific rules discovered during setup:
    critical services, ports not to bind, restart-required quirks, important paths.
11. Log the full setup in `03_TASK_LOG.md` via `vault-writer`.

If this machine has a parent, add it to the **parent's** `08_CONTAINERS.md`.

---

## Finish

Run `bash tools/validate.sh $name` and report the result. Then print the `/connect $name`
briefing so the operator sees exactly what was recorded.

Secrets rule throughout: nothing secret is ever written into a vault file — record the
location, `<redacted YYYY-MM-DD — live value: <location>>`.
