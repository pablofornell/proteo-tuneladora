# Tuneladora — Structural Specification

Canonical definition of how a machine is represented on disk: files, names, schemas,
reading order, and rotation rules. `tools/new_machine.sh` scaffolds to this spec and
`tools/validate.sh` checks against it. Other documents cite sections as `SPEC.md §N`.

Scope: structure only. Operating rules live in the root `CLAUDE.md`; per-workflow
procedure lives in `workflows/`.

**Section map**

| § | Topic |
|---|-------|
| 1 | `STATE.md` — the machine descriptor |
| 2 | Vault file set and numbering |
| 3 | Tiered reading (L1 / L2 / L3) |
| 4 | Task log format, rotation and archive |
| 5 | Secret redaction |
| 6 | Language policy |
| 7 | Obsidian vault layout and linking |
| 8 | Machine folder layout |

---

## §1 — `STATE.md`

One per machine, at the machine folder root: `<machine>/STATE.md`.

It is the single source of truth for identity, network position and topology, and the
only mandatory read besides the root `CLAUDE.md` and the machine's own `CLAUDE.md`
(§3). It replaces the legacy per-machine `HIERARCHY` descriptor, which is **deleted**
repo-wide — no machine keeps one.

**Target size: under 2 KB.** If it grows past that, the excess belongs in a vault note,
not here.

### 1.1 Schema

YAML frontmatter, then a short body. All frontmatter keys are required; use `null`
where a value does not apply.

```yaml
---
machine: hef-net
type: lxc                      # bare-metal | vm | lxc | docker
parent: hef-proxmox            # null for root nodes
container_id: 106              # LXC VMID, Docker container name, else null
connection: proxyjump          # direct | proxyjump | docker-exec
ssh_alias: hef-net             # null if not reachable yet
ip: 192.168.0.10
ip_assignment: static          # static | dhcp | none
status: running                # running | stopped | unknown
os: "Ubuntu 24.04"
depends_on:
  - machine: hef-proxmox
    role: hypervisor
    detail: "lifecycle managed via pct on the parent"
provides_to:
  - machine: hef-docker
    role: reverse-proxy
    detail: "publishes ups.home.lan -> 192.168.0.22:8088"
backups:
  configured: true
  destination: "hef-nas-4800:/volume1/backups/..."
  last_verified: 2026-08-04
auto_updates:
  configured: true
  tool: unattended-upgrades
  schedule: "daily + weekly full-upgrade Sun 05:00 UTC"
last_reconciled: 2026-09-12
---
```

### 1.2 Field rules

- **No `children` field.** The child list is derived from the directory tree
  (`<machine>/VMs/*/`, `<machine>/CTs/LXC/*/`, `<machine>/CTs/Docker/*/`) and is never
  hand-maintained. A hand-written child list was the single worst source of drift found
  in the audit; do not reintroduce it in any form.
- `depends_on` / `provides_to` describe **service-level** relationships only — what this
  machine needs from another to function, and what it serves to another. They are not a
  restatement of the parent/child tree. `parent` already carries containment.
- `container_id` is the LXC VMID (integer), the Docker container name (string), or
  `null` for bare-metal and VMs addressed by name.
- `ip_assignment: none` is for machines with no IP of their own (e.g. a Docker container
  on the host network).
- `last_reconciled` is the date the frontmatter was last checked against the live
  machine. Update it whenever you verify, not whenever you edit.
- `backups.last_verified` means a restore or snapshot listing was actually observed —
  not that a job is configured. `configured: true` with a stale `last_verified` is a
  legitimate and useful state.

### 1.3 Body

Three short sections, in this order:

- `## Services` — compact table, columns `Service | Port | Unit | Status`. One line per
  service. Detail goes to `02_SERVICES.md`.
- `## Open Issues` — dated bullets (`- 2026-09-12: ...`), or the single word `none`.
  Remove a bullet when the issue is closed; the history stays in the task log.
- `## Read Next` — pointers telling the agent which vault notes matter for which kind of
  task, e.g. "DNS or proxy work → `02_SERVICES.md`, `04_NOTES.md`". This is what keeps
  L2/L3 reads targeted (§3).

---

## §2 — Vault file set and numbering

Canonical set, under `<machine>/vault/`:

```
00_INDEX.md
01_SYSTEM_INFO.md
02_SERVICES.md
03_TASK_LOG.md            # rotated: 5 most recent entries only (§4)
04_NOTES.md
05_SECURITY.md
06_BACKUPS.md
07_UPDATES.md
08_CONTAINERS.md          # parents only (hosts with VMs or containers)
09_TROUBLESHOOTING.md     # optional
archive/YYYY-QN.md        # rotated-out task log entries (§4)
```

No other numbered files. A machine that hosts nothing omits `08_`; `09_` is created only
when there is something to put in it. Every other file is mandatory.

### 2.1 Why the renumbering

Numbering used to be assigned positionally, per machine, as files were added. Two
collisions resulted, both live in the repo at audit time:

- `06_BACKUPS.md` vs `06_CONTAINERS.md` — `hef-docker` carried **both** at number 06.
- `07_UPDATES.md` vs `07_TROUBLESHOOTING.md` — `hef-proxmox` has the latter and neither
  of the former.

Numbers are now fixed by name, globally, whether or not the file exists on a given
machine. `06_CONTAINERS.md` → `08_CONTAINERS.md`, `07_TROUBLESHOOTING.md` →
`09_TROUBLESHOOTING.md`. A number is never reused for a different note.

### 2.2 Contents

| File | Contents |
|------|----------|
| `00_INDEX.md` | Table of the vault's own files. Navigation only, no state. |
| `01_SYSTEM_INFO.md` | OS, kernel, hardware, disks, IPs, admin users. |
| `02_SERVICES.md` | Services: ports, units, config paths, management commands. |
| `03_TASK_LOG.md` | The 5 most recent task entries (§4). |
| `04_NOTES.md` | Free-form observations, quirks, warnings, unresolved uncertainty. |
| `05_SECURITY.md` | SSH access policy, keys, user accounts, firewall posture. |
| `06_BACKUPS.md` | Backup jobs, destinations, schedules, last verified restore. |
| `07_UPDATES.md` | Auto-update mechanism, coverage, schedule, reboot policy. |
| `08_CONTAINERS.md` | Inventory of hosted VMs/containers and their machine folders. |
| `09_TROUBLESHOOTING.md` | Known failure modes, diagnosis steps, fixes. |
| `archive/YYYY-QN.md` | Task log entries rotated out of `03_TASK_LOG.md`. |

---

## §3 — Tiered reading

The core efficiency rule. Reading "the machine's context files and vault" before acting
cost roughly 77 KB / 19k tokens on `hef-net` — 38 % of it task-log history that had no
bearing on the task. Read by tier instead.

### L1 — always, before any action on a machine

- root `CLAUDE.md`
- `<machine>/STATE.md`
- `<machine>/CLAUDE.md`
- for a child node (`type` vm / lxc / docker), also `<parent>/STATE.md`

**Budget: L1 stays under ~4 KB per machine.** If it does not, the machine's `STATE.md`
or `CLAUDE.md` is carrying content that belongs in a vault note. Fix the file; do not
raise the budget.

### L2 — when the task touches a service, a config file, or a package

- `<machine>/vault/02_SERVICES.md`
- `<machine>/vault/04_NOTES.md`
- `<machine>/CONTEXT.md` — purpose, network role, quirks. Read it when the task needs
  the machine's *why*, not just its *what*. It is not L1: it is prose and routinely
  exceeds the L1 budget on its own.

### L3 — investigation only, and by `grep`, never a full read

`03_TASK_LOG.md`, `archive/*`, `00_INDEX.md`, `01_SYSTEM_INFO.md`, `05_SECURITY.md`,
`06_BACKUPS.md`, `07_UPDATES.md`, `08_CONTAINERS.md`, `09_TROUBLESHOOTING.md`.

Reach for L3 when you need history or a specific recorded fact — "when did this last
change", "what was the old IP", "has this failed before". Grep for the term, read the
matching entry, stop. Opening one of these files whole is a defect, not thoroughness.

### Escalation

Start at L1. Escalate only when the task demonstrably needs it. `STATE.md`'s
`## Read Next` (§1.3) tells you which L2/L3 notes are relevant for the task at hand —
use it instead of guessing.

---

## §4 — Task log: format, rotation, archive

### 4.1 Entry format

```markdown
## YYYY-MM-DD — <short title>
**Requested by:** <user | automated task | workflow name>
**Status:** success | partial | failed
**Summary:** <what changed, in one or two sentences>
**Commands run:**
- `<command>`
**Verification:** <what was checked, and what it returned>
**Rollback:** <the command or procedure that undoes this, or "n/a">
**Notes:** <caveats, follow-ups, links to 04_NOTES.md>
```

All seven fields are present in every entry. Newest entry at the top of the file.
`**Verification:**` is not optional — an entry without evidence is a claim, not a log.

### 4.2 Rotation

`03_TASK_LOG.md` holds the **5 most recent entries**. When a sixth is added, the oldest
**moves** to `vault/archive/<YYYY>-Q<N>.md`, chosen by the entry's own date (e.g. an
entry dated 2026-08-04 goes to `archive/2026-Q3.md`). Create the archive file on first
use.

Within an archive file, entries keep the **order they had in the log** — they are not
re-sorted by date. These logs were not always appended chronologically, so sorting would
change the sequence of historical records, and §4.3 forbids that as much as it forbids
rewording them. Every entry carries its own date in its heading, and the archive index at
the end of `03_TASK_LOG.md` gives each file's date range, so nothing is lost by leaving
the sequence alone. `tools/rotate_tasklog.sh` implements this.

### 4.3 Append-only, restated

Append-only now means: **entries are never deleted and never reworded.** It no longer
means "one file forever". Moving an entry verbatim into `archive/` is not a violation;
editing its text is. The single permitted edit to an already-written entry is secret
redaction under §5.

---

## §5 — Secret redaction

Writing a secret value into any vault file, `STATE.md`, `CONTEXT.md` or `CLAUDE.md` is
forbidden — passwords, API keys, tokens, private keys, recovery codes. Record **where
the real value lives**, never the value.

When a secret is found already written into append-only content, redacting it is the one
permitted edit. Replace the value in place with:

```
<redacted YYYY-MM-DD — live value: <where the real value lives>>
```

Example:

```
**Notes:** API key <redacted 2026-09-12 — live value: /etc/adguard/secrets.env on hef-net>
```

Nothing else in the entry changes. This exception exists because the audit found a live
API key and a server password sitting in an append-only log whose own header forbade
fixing them. Rotate the exposed secret as well as redacting it, and log the rotation as
its own task entry.

---

## §6 — Language policy

**English**, for everything the agent reads in order to act:

- root `CLAUDE.md`, `CONTEXT.md`, `README.md`, `REFERENCES.md`, `SPEC.md`, `QWEN.md`
- `workflows/`, `tools/`, `.claude/`
- every machine's `STATE.md`, `CLAUDE.md`, `CONTEXT.md`, `REFERENCES.md`
- vault notes `01`, `02`, `04`, `05`, `06`, `07`, `08`, `09` (and `00_INDEX.md`)

**Verbatim**, for the historical record:

- `03_TASK_LOG.md` and `archive/*` keep existing entries in whatever language they were
  written. Do not translate them — translation is a rewrite, and §4.3 forbids it.
- **New** task log entries are written in English.

Quoted command output, config excerpts and error messages are reproduced exactly,
whatever language they are in. Conversation with the operator follows the operator.

---

## §7 — Obsidian

**One vault, rooted at `machines/`.** Not one per machine. Exactly one `.obsidian/`
directory exists in the repo, at `machines/.obsidian/`; per-machine `.obsidian/`
directories are removed. (At audit time 1 of 8 machines had one — the per-machine model
was never actually in use.)

**Cross-machine links are encouraged.** The former "each machine's vault is independent
— no cross-machine links" rule is **revoked**: it forbade linking exactly the
dependencies the content already described in prose, which is how `STATE.md`'s
`depends_on` / `provides_to` (§1.2) drifted from reality.

Links are **path-qualified**, relative to the vault root at `machines/`:

```
[[hef-proxmox/CTs/LXC/hef-net/vault/02_SERVICES]]
[[hef-proxmox/CTs/LXC/hef-net/STATE]]
```

Bare `[[02_SERVICES]]` is ambiguous across eight machines and is not used, including
inside a machine's own vault.

---

## §8 — Machine folder layout

```
machines/
├── .obsidian/                      # the single vault config (§7)
└── <host>/                         # bare-metal — root node
    ├── STATE.md                    # §1 — mandatory
    ├── CLAUDE.md                   # machine-specific agent rules
    ├── CONTEXT.md                  # purpose, network role, quirks
    ├── REFERENCES.md               # docs, runbooks, vendor links (optional)
    ├── .env_<host>                 # non-SSH env variables (optional, gitignored)
    ├── vault/                      # §2
    │   ├── 00_INDEX.md … 09_TROUBLESHOOTING.md
    │   └── archive/YYYY-QN.md
    ├── TOOLS/                      # machine-specific scripts and unit files
    ├── VMs/<name>/                 # same layout, recursively
    └── CTs/
        ├── LXC/<name>/             # same layout, recursively
        └── Docker/<name>/          # same layout, recursively
```

A machine's folder path is derived from its `parent` and `type` in `STATE.md`; the tree
is the authority on containment (§1.2). Scaffold with
`tools/new_machine.sh <name> --type <type> --parent <parent>` — never by hand.

### 8.1 Drift reconciliation

Structure drifts. Reconcile when you touch a machine:

1. `STATE.md` frontmatter against the live machine — bump `last_reconciled`.
2. The parent's `08_CONTAINERS.md` after adding or removing any child.
3. `depends_on` / `provides_to` on **both** ends of a relationship you change.
4. `03_TASK_LOG.md` length — rotate if over 5 entries (§4.2).

---
