---
description: The standard day-to-day loop on one machine — L1 read, plan, confirm if destructive, execute via machine-operator, verify, then vault-writer. Use this for ordinary work.
argument-hint: <machine> <description of the task>
allowed-tools: Read, Grep, Glob, Bash, Agent(machine-operator, vault-writer, drift-auditor)
---

# Task on `$1`

**Machine:** `$1`
**Task:** everything after the machine name in: `$ARGUMENTS`

This is the standard loop. Follow it in order; do not skip the verify step and do not
skip the vault write.

---

## Step 1 — Resolve and L1 read (you, not a subagent)

Resolve the folder from the tree (`machines/<host>/`, `.../VMs/<n>/`,
`.../CTs/LXC/<n>/`, `.../CTs/Docker/<n>/`); confirm via `machine:` in `STATE.md`.

Read **L1 only**, ~4 KB:

- `<folder>/STATE.md`
- `<folder>/CLAUDE.md`
- the parent's `STATE.md`, if this is a `vm`/`lxc`/`docker` node

Escalate to **L2** (`vault/02_SERVICES.md`, `vault/04_NOTES.md`) **only if** the task
touches a service, a config file or a package. For anything historical, **L3 by grep
only** (`03_TASK_LOG.md`, `archive/*`, `01_SYSTEM_INFO`, `05_SECURITY`, `06_BACKUPS`,
`07_UPDATES`, `08_CONTAINERS`, `09_TROUBLESHOOTING`) — `grep -n`, never `cat`.

Reading the whole vault costs ~77 KB / ~19k tokens before a single command runs, 38 %
of it task-log history. Don't.

## Step 2 — Plan

State, in five lines or fewer:

- what you will change,
- the exact commands,
- the verification command and its expected result,
- the rollback,
- whether this is destructive.

Check the plan against the machine's own `CLAUDE.md` — machine-specific rules
override global ones (capabilities that must be re-applied, services that need an
explicit restart, ports that must not be bound, firewall rules that come first).

## Step 3 — Confirm if destructive

**Stop and ask the operator** before: deleting data, stopping or removing a
production service, rewriting firewall rules, destroying or recreating a container,
touching DNS/proxy/VPN on a node marked critical, or anything with no rollback.

Read-only inspection needs no confirmation. When in doubt, ask — it costs one turn.

Container lifecycle (start/stop/destroy) is driven **from the parent**, never from
inside the child. If the task implies that, the target of the operation is the parent.

## Step 4 — Execute via `machine-operator`

Launch the `machine-operator` subagent with:

- `machine_path` — the resolved folder
- `task` — the specific, bounded description
- `tier` — which reading tier it should use
- the plan from step 2, including the verification command
- a reminder that it must return the structured block

It connects as the `tuneladora` user via the alias in `STATE.md`, escalates with
`sudo`, checks exit codes, and never connects as root (a hook enforces that).

For a task that genuinely spans several machines, launch **one `machine-operator` per
machine, in parallel, in a single message**. If some fail: apply the successes, log
each failure in that machine's `04_NOTES.md`, report which succeeded and which did
not, and mark the overall task `partial` if at least one succeeded.

## Step 5 — Verify

Do not accept the subagent's word. Its block must contain a real verification command
and a real result. If it does not, send it back to verify before you go further.
No verification, no `success`.

## Step 6 — Vault write via `vault-writer`

Hand the `vault_updates` block straight to the `vault-writer` subagent, with
`machine_path`.

- `03_TASK_LOG.md`: the new entry goes at the **top** of the entry list, directly under
  the file header and above the newest existing entry — never at the bottom, never
  rewriting existing entries (`SPEC.md §4.1`). In English.
- `STATE.md` is the single source of truth for ip/status/topology — a change there is
  not duplicated into prose anywhere.
- No secret values: locations only, `<redacted YYYY-MM-DD — live value: <location>>`.
- If a child was added, removed or moved, the **parent's** `08_CONTAINERS.md` gets
  updated too.

## Step 7 — Report

Six lines, maximum:

```
$1 — <task> : success | partial | failed
Changed:      <what>
Verified by:  <command → result>
Rollback:     <how>
Vault:        <files written>
Follow-up:    <anything left, or "none">
```

Never claim success you did not verify. Never print credentials, key material or raw
hostnames.
