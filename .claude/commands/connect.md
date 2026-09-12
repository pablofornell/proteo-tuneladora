---
description: Orient on one machine — resolve its folder, do the L1 read only, and report a short briefing. Cheap entry point; runs no commands on the machine.
argument-hint: <machine>
arguments: [machine]
allowed-tools: Read, Grep, Glob, Bash(ls *), Bash(find machines *), Bash(sed -n *), Bash(grep *)
---

# Connect: orient on `$machine`

Get oriented on **$machine** and then **stop**. This is the cheap entry point — no
SSH, no changes, no vault writes. If the operator then wants work done, that is
`/task $machine <description>`.

## 1. Resolve the folder

The tree is the topology — there is no `children` key anywhere.

| Type | Folder |
|------|--------|
| bare-metal | `machines/<host>/` |
| vm | `machines/<host>/VMs/<name>/` |
| lxc | `machines/<host>/CTs/LXC/<name>/` |
| docker | `machines/<host>/CTs/Docker/<name>/` |

```bash
find machines -maxdepth 4 -type d -name '$machine' -not -path '*/.git/*'
```

Confirm the hit: its `STATE.md` must have `machine: $machine`. If nothing matches,
list the known machines and stop. If several match, ask which.

## 2. L1 read — and nothing more

Read exactly these, budget ~4 KB:

1. `<folder>/STATE.md`
2. `<folder>/CLAUDE.md`
3. the parent's `STATE.md` — only if `type` is `vm`, `lxc` or `docker`

Root `CLAUDE.md` is already loaded; do not re-read it.

**Do not** open `02_SERVICES.md`, `04_NOTES.md` or anything else in `vault/` for this
command. If `CLAUDE.md` does not name the services, say "services not listed in
CLAUDE.md" rather than escalating the read. Reading the whole vault costs ~77 KB /
~19k tokens; the entire point of `/connect` is not paying that.

The one exception: **open issues**. Get them with a bounded grep, never a full read:

```bash
grep -n -iE '(TODO|FIXME|pending|unresolved|known issue|broken)' \
  <folder>/vault/04_NOTES.md 2>/dev/null | head -5
```

## 3. Report — 10 lines, then stop

```
<machine>  —  <type>, parent <parent or none>
What it is:      <one line from CLAUDE.md's Identity section>
Address:         <ip> (<ip_assignment>), alias <ssh_alias>, <connection>
Status:          <status>  |  OS: <os>
Services:        <from CLAUDE.md's Services table, comma-separated>
Depends on:      <depends_on>
Provides to:     <provides_to>
Backups:         <backups.configured; destination; last_verified>
Auto-updates:    <auto_updates.configured; tool; schedule>
Open issues:     <from the grep, or "none flagged">
Rules that matter: <the 2–3 machine-specific rules most likely to bite — the ones
                    about critical services, capabilities, ports, restart-required
                    quirks — not the global rules>
Last reconciled: <last_reconciled>
```

Then stop. Do not connect, do not propose work, do not read further. If `STATE.md`
contradicts `CLAUDE.md`, say so in one extra line and suggest `/audit $machine`.
