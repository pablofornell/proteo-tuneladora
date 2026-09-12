# Add a New Machine — Workflow

Onboarding a **bare-metal host or a VM**. For LXC/Docker children use
[`ADD_CONTAINER.md`](ADD_CONTAINER.md); for a NAS, router or other appliance with a
proprietary OS use [`ADD_NAS.md`](ADD_NAS.md).

Structure (file names, vault numbering, `STATE.md` schema) is defined by
[`SPEC.md`](../SPEC.md). This document is procedure only — where the two disagree,
`SPEC.md` wins.

**Running this with an agent:** the driver is the `/add-machine <name>` slash command
([`.claude/commands/add-machine.md`](../.claude/commands/add-machine.md)), which marks
the handoff points. Per-machine execution belongs to the `machine-operator` subagent and
vault writes to `vault-writer`
([`.claude/agents/`](../.claude/agents/)). Those definitions own the orchestration
protocol — parallelism, models, return format. Do not restate it here.

## Overview

Four phases:

1. **Agent** — scaffold the folder, vault and `STATE.md` with `tools/new_machine.sh`.
2. **Operator** — configure initial SSH access with their own user (needs sudo).
3. **Agent prepares + operator executes** — the agent generates the key and ships the
   setup script; the operator runs **one** `sudo` command on the target.
4. **Agent** — harden SSH, discover the system, populate the record, then **validate and
   reconcile**.

Phases 2 and 3 genuinely require a human: until the `tuneladora` user exists there is no
key-based, non-root way in. Do not attempt to work around them.

---

## Phase 1 — Agent: create the structure

```bash
# Bare-metal host
bash tools/new_machine.sh <name> --type bare-metal

# VM on an existing host
bash tools/new_machine.sh <name> --type vm --parent <host>
```

The script is the single source of truth for layout (`SPEC.md §8`). It creates:

- `machines/<name>/` (bare-metal) or `machines/<host>/VMs/<name>/` (VM)
- `STATE.md`, `CLAUDE.md`, `CONTEXT.md`, `REFERENCES.md`
- `vault/00_INDEX.md` … `vault/07_UPDATES.md`, plus `vault/08_CONTAINERS.md`
  (bare-metal and VM always get it — both can host children)
- `vault/archive/` and `TOOLS/`
- an `~/.ssh/config` snippet, printed — **do not add it yet**, the IP is still unknown

`vault/09_TROUBLESHOOTING.md` is optional and created only when there is something to
put in it.

Then fill `STATE.md` (`SPEC.md §1`) with what is already known and leave the rest honest
(`unknown` / `null`). There is **no `children:` key** — the folder tree is the topology,
and a hand-maintained child list is forbidden.

Log the scaffolding in `vault/03_TASK_LOG.md` (`SPEC.md §4.1`, all seven fields).

**Stop here and hand over.** Print the Phase 2 commands, filled in, and wait.

---

## Phase 2 — Operator: initial SSH with your own user

```bash
ssh-keygen -t ed25519 -f ~/.ssh/<name>-personal -C "<your-user>@<name>"
ssh-copy-id -i ~/.ssh/<name>-personal.pub <your-user>@<host>
```

Add a temporary `~/.ssh/config` entry, for the setup only:

```
Host <name>
    HostName <host>
    User <your-user>
    IdentityFile ~/.ssh/<name>-personal
    IdentitiesOnly yes
```

Verify:

```bash
ssh <name> "echo ok"
```

Then tell the agent: *"SSH ready for `<name>`"*.

---

## Phase 3 — Agent prepares, operator runs one command

**Agent, locally:**

```bash
# Generates ~/.ssh/tuneladora_<name> (skipped if it already exists)
bash tools/setup_tuneladora_control.sh --machine <name>

# Ship the setup script over the operator's personal alias
scp tools/setup_tuneladora_target.sh <name>:/tmp/
```

`setup_tuneladora_control.sh` prints the public key, its fingerprint, and the exact
command to hand over. It never touches `~/.ssh/config`.

**Operator, on the target, with sudo:**

```bash
sudo bash /tmp/setup_tuneladora_target.sh --pubkey 'ssh-ed25519 AAAA...'
```

That one command creates the `tuneladora` user, grants passwordless sudo, creates
`~/.ssh/`, installs the public key into `authorized_keys` and locks the account
password (key-only auth from here on). It is idempotent. No `ssh-copy-id` needed.

Then tell the agent: *"tuneladora user ready"*.

---

## Phase 4 — Agent: harden, discover, finalise

Steps 1–3 are strictly sequential; each depends on the previous one.

1. **Discover the LAN subnet and restrict the key.** Never hardcode a subnet:

   ```bash
   SUBNET=$(ip -4 addr show scope global | awk '/inet / {split($2,a,"."); print a[1]"."a[2]"."a[3]".*"}' | head -1)
   PUBKEY=$(cat ~/.ssh/tuneladora_<name>.pub)
   ssh <name> "echo 'from=\"$SUBNET\",no-agent-forwarding,no-X11-forwarding $PUBKEY' > ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
   ```

   > **Network change:** connecting later from a different LAN (office vs home) will be
   > refused until this is re-run from the new network. Record that in `04_NOTES.md`.

2. **Update `~/.ssh/config`** to `User tuneladora` and
   `IdentityFile ~/.ssh/tuneladora_<name>`. Editing `~/.ssh/config` is permitted during
   setup and migration.

3. **Test:** `ssh <name> "whoami"` must return `tuneladora`. Never `root` — a root SSH
   attempt is blocked by a `PreToolUse` hook (`.claude/settings.json`). If this step
   fails, stop and report; do not work around it.

Once step 3 passes, the discovery work is independent and can run concurrently —
delegate it per the `machine-operator` definition rather than improvising roles:

4. **Discover system info** → `vault/01_SYSTEM_INFO.md`.
5. **Populate `CONTEXT.md`** with real data: purpose, network role, quirks. Never leave
   a scaffolded template behind.
6. **Record SSH access policy** → `vault/05_SECURITY.md`: key **fingerprints** and
   locations only. Never key material, never a password value (`SPEC.md §5`; a
   `PreToolUse` hook blocks writing a live secret under `machines/**`).

Then sequential again:

7. **Configure automatic security updates** with the OS-appropriate tool
   (`unattended-upgrades` on Debian/Ubuntu, `dnf-automatic` on RHEL) and document the
   mechanism, coverage, schedule and reboot policy in `vault/07_UPDATES.md`.
8. **Verify or configure backups** → `vault/06_BACKUPS.md`. "No backup — intentional" is
   a valid and required entry when that is the truth. `backups.last_verified` in
   `STATE.md` means a restore or snapshot listing was actually observed, not that a job
   exists.
9. **Complete `STATE.md`**: `ip`, `ip_assignment`, `status`, `os`, `ssh_alias`,
   `backups`, `auto_updates`, `last_reconciled`. Fill the `## Services` table, set
   `## Open Issues` (`none` if there are none) and write `## Read Next` — that section
   is what keeps later L2/L3 reads targeted (`SPEC.md §3`). Keep `STATE.md` under 2 KB;
   overflow belongs in a vault note.
10. **Write `CLAUDE.md`** with the machine-specific rules actually discovered: critical
    services, ports not to bind, restart-required quirks, important paths.
11. **If the machine has a parent** (VM case), add a row for it to the parent's
    `vault/08_CONTAINERS.md`. The parent owns that file; the child never maintains a
    child list of its own.
12. **Log the setup** in `vault/03_TASK_LOG.md`.

### Reading, from here on

Once the machine exists, later tasks read by tier (`SPEC.md §3`) — **not** the whole
folder:

- **L1, always:** root `CLAUDE.md`, `<machine>/STATE.md`, `<machine>/CLAUDE.md`, plus the
  parent's `STATE.md` for a VM. Budget ~4 KB.
- **L2, for service/config/package work:** `vault/02_SERVICES.md`, `vault/04_NOTES.md`,
  `CONTEXT.md`.
- **L3, investigation only, by `grep`:** `03_TASK_LOG.md`, `archive/*` and the remaining
  numbered notes. Never `cat` one whole.

---

## Phase 4b — Validate and reconcile (mandatory)

Setup is not finished until both of these have been run. This is the step that catches
the drift class the audit was created to fix — cheapest at onboarding, expensive a year
later.

```bash
# Structure: required files, STATE.md schema and enums, legacy leftovers,
# referential integrity, secret scan, task-log length, L1 budget.
tools/validate.sh --machine <name>
```

**Must report 0 FAIL.** A FAIL means the record is structurally wrong — fix it before
continuing. WARN is reviewed, not ignored.

```bash
# Reality: STATE.md and 08_CONTAINERS.md against what the machine actually reports
# over SSH, plus disk thresholds and the systemd units named in STATE.md.
tools/reconcile.sh --machine <name>
```

`reconcile.sh` is read-only against the remote machine; it never writes there. Exit 0
means no drift, 1 means findings, 2 is a tool error. Useful flags: `--offline` (skip all
SSH, vault-internal consistency only), `--json`, and `--write` (updates **only**
`last_reconciled:` and `status:` in `STATE.md`, and only when status drift is the sole
finding). Everything else stays a judgement call.

For a full read-only sweep with proposed fixes, use the `/audit [machine]` command,
which delegates to the read-only `drift-auditor` subagent.

Task logs are bounded at 5 entries; `tools/rotate_tasklog.sh [--dry-run] [--machine
<name>] [--keep <n>]` moves older entries verbatim into `vault/archive/<YYYY>-Q<N>.md`
(`SPEC.md §4.2`).

---

## Lost SSH Key Recovery

If the control machine loses `~/.ssh/tuneladora_<name>` (disk wipe, migration) and the
`tuneladora` user already exists on the target:

**1. Generate a new key on the control machine:**

```bash
bash tools/setup_tuneladora_control.sh --machine <name> --replace-key
```

`--replace-key` forces a fresh keypair even when the key file exists, and includes the
flag in the printed target command so the target script overwrites `authorized_keys`
instead of appending.

**2. Get the new key onto the target.** Use whichever route applies:

| Scenario | How to access |
|----------|---------------|
| Bare-metal — admin still has personal SSH | `scp` the script, run as usual |
| LXC — the parent's `tuneladora` still works | Agent runs it via `pct exec` autonomously |
| Bare-metal — only `tuneladora` SSH ever existed | Physical/console access, or the Proxmox web shell |

**3a. Run on the target (bare-metal / VM):**

```bash
sudo bash /tmp/setup_tuneladora_target.sh --pubkey 'ssh-ed25519 AAAA...' --replace-key
```

**3b. Run via the parent (LXC):**

```bash
ssh <parent-name> "bash /tmp/setup_tuneladora_target.sh \
  --pubkey '$(cat ~/.ssh/tuneladora_<name>.pub)' \
  --replace-key --lxc --vmid <vmid>"
```

**4. Re-apply Phase 4 hardening** — connect as `tuneladora`, re-apply the `from=`
restriction, update `~/.ssh/config`, and log the recovery in `vault/03_TASK_LOG.md`.

> Without `--replace-key` the script appends the new key beside the old orphaned one.
> Phase 4 hardening overwrites `authorized_keys` with only the new key anyway, so both
> modes reach the same end state — `--replace-key` just gets there immediately.

---

## Quick reference

| Phase | Who | What |
|-------|-----|------|
| 1 — Scaffold | Agent | `tools/new_machine.sh <name> --type bare-metal\|vm [--parent <host>]` |
| 2 — Initial SSH | Operator | Personal key + temporary `~/.ssh/config` entry |
| 3 — `tuneladora` user | Agent prepares, operator runs one `sudo` command | `setup_tuneladora_control.sh` → `setup_tuneladora_target.sh` |
| 4 — Harden + discover + populate | Agent | `from=` restriction, config update, discovery, updates, backups, `STATE.md` |
| 4b — Verify | Agent | `tools/validate.sh --machine <name>` (0 FAIL) then `tools/reconcile.sh --machine <name>` |
