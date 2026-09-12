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
./tools/new_machine.sh $name --type bare-metal
```

(For a VM: `--type vm --parent <host>`. The full CLI is
`<machine-name> [--type bare-metal|vm|lxc|docker] [--parent <name>] [--hosts-children]`
— there are no other flags.)

It creates the folder, `STATE.md`, `CLAUDE.md`, `CONTEXT.md` and the canonical vault
set (`00_INDEX 01_SYSTEM_INFO 02_SERVICES 03_TASK_LOG 04_NOTES 05_SECURITY
06_BACKUPS 07_UPDATES`, plus `vault/archive/`). `08_CONTAINERS.md` is emitted
automatically for `bare-metal` and `vm`; `09_TROUBLESHOOTING.md` is optional and
created only when there is something to put in it.

The scaffolded `STATE.md` already matches `SPEC.md §1`. **Leave its placeholders
alone at this point** — `ip`, `os`, `status` and the rest are genuinely unknown until
Phase 4, and `unknown`/`null` are the honest values. Do not invent them, and do not
hand-write a replacement block here; Phase 4 step 9 fills it in.

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
9. Complete `STATE.md`. Keys stay in this canonical order and the enums are closed —
   `tools/validate.sh` FAILs on any other value (`SPEC.md §1.1`):

   ```yaml
   ---
   machine: $name
   type: bare-metal               # bare-metal | vm | lxc | docker
   parent: null                   # null for a root node; a VM names its host
   container_id: null             # null for bare-metal and VMs
   connection: direct             # direct | proxyjump | docker-exec
   ssh_alias: $name
   ip: 192.168.0.10
   ip_assignment: static          # static | dhcp | none
   status: running                # running | stopped | unknown
   os: "Ubuntu 24.04"
   depends_on: []                 # service-level only — see below
   provides_to: []
   backups:
     configured: false
     destination: null
     last_verified: null
   auto_updates:
     configured: true
     tool: unattended-upgrades
     schedule: "daily + weekly full-upgrade Sun 05:00 UTC"
   last_reconciled: 2026-09-12    # YYYY-MM-DD
   ---
   ```

   - There is **no `children` key** — the directory tree is the topology, and
     `validate.sh` FAILs if you add one.
   - `depends_on` / `provides_to` are lists of mappings, and every `machine:` they
     name must resolve to a real machine folder:
     ```yaml
     provides_to:
       - machine: hef-docker
         role: reverse-proxy
         detail: "publishes ups.home.lan -> 192.168.0.22:8088"
     ```
     They record **service-level** relationships only (`SPEC.md §1.2`). Containment is
     already carried by `parent`; do not restate the tree here.
   - `backups.last_verified` means a restore or snapshot listing was actually
     observed, not that a job exists.
   - Keep `00_INDEX.md`'s status block consistent with this, and do not restate any of
     these facts in prose elsewhere.
10. Write `CLAUDE.md` with the real machine-specific rules discovered during setup:
    critical services, ports not to bind, restart-required quirks, important paths.
11. Log the full setup in `03_TASK_LOG.md` via `vault-writer`.

If this machine has a parent, add it to the **parent's** `08_CONTAINERS.md`.

---

## Finish

```bash
./tools/validate.sh --machine $name
```

(`validate.sh` takes `--quiet` and `--machine <name>` only; a bare name is rejected
with "Unknown option". Exit status is 0 when nothing FAILed, 1 otherwise.)

Report the result, then print the `/connect $name` briefing so the operator sees
exactly what was recorded.

Secrets rule throughout: nothing secret is ever written into a vault file — record the
location, `<redacted YYYY-MM-DD — live value: <location>>`.
