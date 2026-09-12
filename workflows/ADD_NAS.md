# Add a NAS / Appliance — Workflow

NAS devices and other appliances run proprietary operating systems (UGOS, Synology DSM,
QNAP QTS, TrueNAS, …) that impose restrictions a standard Linux host does not have. This
document adapts [`ADD_MACHINE.md`](ADD_MACHINE.md) for them.

Structure (file names, vault numbering, `STATE.md` schema) is defined by
[`SPEC.md`](../SPEC.md). This document is procedure only.

**Use this instead of `ADD_MACHINE.md`** when the target is:

- a NAS (UGREEN, Synology, QNAP, TrueNAS, …)
- a router or managed switch with SSH
- any appliance whose OS is proprietary or locked

**Running this with an agent:** there is no dedicated slash command — drive it with
`/add-machine <name>` ([`.claude/commands/add-machine.md`](../.claude/commands/add-machine.md))
and substitute the phases below, or run it by hand. Execution on the appliance belongs to
the `machine-operator` subagent and vault writes to `vault-writer`
([`.claude/agents/`](../.claude/agents/)); those definitions own the orchestration
protocol.

**Reference implementation:** `machines/hef-nas-4800/` — a UGREEN DXP4800 on UGOS,
migrated to the current format. Its `STATE.md`, `vault/04_NOTES.md` and
`vault/05_SECURITY.md` are the worked example for everything below. Read it by tier
(`SPEC.md §3`), not whole.

---

## Key differences from standard Linux

| Aspect | Standard Linux | NAS / appliance |
|--------|----------------|-----------------|
| Shell access | Any user with a shell | May require specific group membership (e.g. `admin`) |
| rsync / SFTP / SCP | Any path | May be wrapped — restricted to registered shares |
| Package manager | apt / dnf | Usually unavailable or restricted |
| Kernel updates | Via the package manager | Tied to vendor firmware updates |
| sudoers | Direct edit | May be managed by the appliance OS |
| File transfer destination | Any writable path | Must be a share registered in the appliance UI |

Appliances are almost always root nodes: `type: bare-metal`, `parent: null`,
`connection: direct` in `STATE.md`. `auto_updates.configured: false` with `tool: null` is
the honest value when firmware updates are manual — record that rather than leaving the
scaffold.

---

## Phase 1 — Agent: scaffold the structure

Same as `ADD_MACHINE.md` Phase 1:

```bash
bash tools/new_machine.sh <name> --type bare-metal
```

An appliance that hosts its own Docker containers or VMs as managed machines keeps
`vault/08_CONTAINERS.md` (bare-metal always gets it).

---

## Phase 2 — Operator: verify SSH access

Connect with the appliance's own admin account:

```bash
ssh <admin-user>@<ip>
```

Most NAS systems use password auth by default. Confirm the connection works before going
further.

---

## Phase 3 — Create the `tuneladora` user and install the key

**Agent prepares (locally):**

```bash
bash tools/setup_tuneladora_control.sh --machine <name> --group admin
scp tools/setup_tuneladora_target.sh <admin-user>@<ip>:/tmp/
```

This generates `~/.ssh/tuneladora_<name>`, prints the public key and its fingerprint, and
prints the exact command to hand to the admin.

**Admin runs (one command on the NAS, with sudo):**

```bash
sudo bash /tmp/setup_tuneladora_target.sh --pubkey 'ssh-ed25519 AAAA...' --group admin
```

`--group admin` adds `tuneladora` to the `admin` group, which is **required for
interactive SSH shell access on UGOS**. For other appliances, omit the flag unless the
vendor requires group membership for SSH.

> **UGOS note:** if `useradd` is unavailable (some firmware versions restrict it), create
> the user first in the UGOS admin panel (**Control Panel → Users**), add it to the
> `admin` group there, and then run the script with `--pubkey` only. The script is
> idempotent and skips user creation when the user already exists.

> `ssh-copy-id` is never needed — the script installs the public key into
> `authorized_keys` directly.

---

## Phase 4 — Harden and verify

```bash
# Discover the subnet from the operator's current network — never hardcode it
SUBNET=$(ip -4 addr show scope global | awk '/inet / {split($2,a,"."); print a[1]"."a[2]"."a[3]".*"}' | head -1)
PUBKEY=$(cat ~/.ssh/tuneladora_<name>.pub)
ssh tuneladora@<ip> "echo 'from=\"$SUBNET\",no-agent-forwarding,no-X11-forwarding $PUBKEY' > ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

# Update ~/.ssh/config to User tuneladora + IdentityFile ~/.ssh/tuneladora_<name>, then
ssh <name> "echo ok && whoami"
```

`whoami` must return `tuneladora`; never connect as `root` (a `PreToolUse` hook blocks
it). Re-run the `from=` step from any new network the operator moves to.

---

## Phase 5 — Discover and populate

Same discovery as `ADD_MACHINE.md` Phase 4, steps 4–12. The independent parts —
`01_SYSTEM_INFO.md`, `CONTEXT.md`, `05_SECURITY.md` — can run concurrently; delegate per
the `machine-operator` definition instead of improvising roles, then log the setup in
`03_TASK_LOG.md` once they are all done.

For an appliance, these matter more than on a normal host:

- `CONTEXT.md` → **Known Quirks**: ForceCommand behaviour, group requirements, share
  restrictions, anything the vendor does differently.
- `vault/04_NOTES.md` → every appliance-specific behaviour discovered, including the ones
  you could not explain.
- `vault/06_BACKUPS.md` → the appliance's role as a **backup destination**: which
  machines back up here, the share names, and the real filesystem paths behind them.
- `CLAUDE.md` → the rule that shares must exist in the admin UI before any file transfer
  will work.

Secrets — appliance admin passwords, API tokens, share credentials — are never written
into a file under `machines/`. Record where the live value lives (`SPEC.md §5`); a
`PreToolUse` hook blocks the write if you try.

---

## Phase 6 — Validate and reconcile (mandatory)

```bash
tools/validate.sh --machine <name>      # must be 0 FAIL
tools/reconcile.sh --machine <name>     # record vs. what the appliance actually reports
```

`reconcile.sh` is read-only over SSH and never writes to the appliance. `--offline` skips
SSH entirely; `--write` updates only `last_reconciled:` and `status:` in `STATE.md`.
Expect an appliance to produce findings a Linux host does not — restricted commands,
missing `systemctl` units, unreadable paths. Record those in `vault/04_NOTES.md` so the
next run is interpreted correctly instead of re-investigated.

---

## UGOS-specific: file transfer restrictions

UGOS replaces rsync, SFTP and SCP with proprietary wrappers (`ug_start_server`) that
**only allow access to shares registered in the admin panel**. Raw paths such as
`/volume1/mydir` are rejected unless `mydir` is a registered share.

**Before setting up any backup or file transfer job targeting the NAS:**

1. Open the UGOS admin panel.
2. Go to **Shared Folders** (or the equivalent).
3. Create the shared folder (e.g. `backups`).
4. Grant `tuneladora` read/write permission on that share.
5. The share is then reachable at:
   - SFTP path: `/backups/`
   - rsync path: `/backups/` (via the UGOS rsync module)

Document the share name **and** the real filesystem path behind it in `CONTEXT.md` and
`vault/06_BACKUPS.md`. The two differ, and the difference is what breaks restores.

### Verifying SFTP access after creating a share

```bash
sftp -i ~/.ssh/tuneladora_<name> tuneladora@<ip>
# inside sftp:
ls /            # should list the registered shares
mkdir /backups/test
ls /backups/
rmdir /backups/test
```

### Which protocols are available via the UGOS ForceCommand

| Protocol | Available | Notes |
|----------|-----------|-------|
| Interactive shell | Yes | Only if the user is in the `admin` group |
| SFTP | Yes | Only to registered shares |
| rsync | Yes | Only to registered shares (via the UGOS module) |
| SCP | Yes | Only to registered shares |
| Arbitrary commands | Yes | Only if the user is in the `admin` group |

---

## Tested appliances

| Appliance | OS | Notes |
|-----------|----|-------|
| UGREEN DXP4800 | UGOS 1.14.1 | Requires the `admin` group for SSH; ForceCommand restricts every file operation to registered shares. Reference implementation: `machines/hef-nas-4800/`. |
