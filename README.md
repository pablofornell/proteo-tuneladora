# Tuneladora

SSH connection hub operated by an LLM assistant to manage a homelab. The assistant
connects over SSH, executes tasks, and keeps a persistent, Obsidian-compatible written
memory of every machine under `machines/`.

- [`SPEC.md`](SPEC.md) — canonical structure: file set, vault numbering, `STATE.md`
  schema, reading tiers, rotation, redaction, linking. Read it first.
- [`CLAUDE.md`](CLAUDE.md) — operating rules for the agent.
- [`AGENTS.md`](AGENTS.md) — agent entry point and standing saved-key SSH policy.
- [`workflows/`](workflows/) — onboarding procedures.
- [`REFERENCES.md`](REFERENCES.md) — naming conventions and links.

## SSH setup

Configured machine aliases are ready for autonomous use: the agent connects with
the saved dedicated key without asking for a password, keyring unlock or another
connection approval. Management aliases disable interactive authentication and use
the key file directly; the exact settings are in [`CLAUDE.md`](CLAUDE.md).

The onboarding steps below apply when working saved access does not exist yet.

Tuneladora operates through a dedicated `tuneladora` user on each server — never your
personal user, never `root`. That keeps a clean audit trail and separates daily work from
server administration.

Setup has **two phases**: one thing only you can do (create a privileged user on a
machine the agent cannot yet reach), and everything else, which the agent does.

### Phase 1 — you, once per machine

**1. Get SSH access with your own user.**

```bash
ssh-keygen -t ed25519 -f ~/.ssh/<machine-name>-personal -C "<user>@<machine-name>"
ssh-copy-id -i ~/.ssh/<machine-name>-personal.pub <user>@<host>
```

Add a temporary `~/.ssh/config` entry, for the setup only:

```
Host <machine-name>
    HostName <host>
    User <user>
    IdentityFile ~/.ssh/<machine-name>-personal
    IdentitiesOnly yes
```

Verify with `ssh <machine-name> "echo ok"`.

**2. Let the agent prepare the key and the script.** It runs, locally:

```bash
bash tools/setup_tuneladora_control.sh --machine <machine-name>
scp tools/setup_tuneladora_target.sh <machine-name>:/tmp/
```

`setup_tuneladora_control.sh` generates `~/.ssh/tuneladora_<machine-name>` (skipping
generation if the key already exists, unless `--replace-key` is given), prints the public
key and its fingerprint, and prints the exact command to run next. It never edits
`~/.ssh/config`.

**3. Run one command on the target, with sudo:**

```bash
sudo bash /tmp/setup_tuneladora_target.sh --pubkey 'ssh-ed25519 AAAA...'
```

That single command creates the `tuneladora` user, grants it passwordless sudo, creates
`~/.ssh/`, installs the public key into `authorized_keys`, and locks the account password
so only key auth remains. It is idempotent — safe to re-run. No `ssh-copy-id` needed.

Useful flags: `--group <name>` (adds `tuneladora` to a group — `--group admin` is required
on UGOS for shell access), `--replace-key` (overwrite `authorized_keys` instead of
appending, for key recovery), `--lxc --vmid <id>` (run everything inside an LXC container
via `pct exec` on the parent, which lets the agent do it with no human step at all).

### Phase 2 — tell Tuneladora to take over

> **"Initialize web-prod"** — or `/add-machine web-prod`

Tuneladora then:

1. Scaffolds the machine folder, `STATE.md`, context files and vault
   (`tools/new_machine.sh`).
2. Discovers the LAN subnet dynamically and restricts `authorized_keys` with
   `from="<subnet>",no-agent-forwarding,no-X11-forwarding`.
3. Updates `~/.ssh/config` to the `tuneladora` user and the dedicated key.
4. Tests the connection (`whoami` must return `tuneladora`).
5. Discovers system info, services, updates and backups, and populates `STATE.md`,
   `CONTEXT.md` and the vault with real data.
6. Logs the setup in `vault/03_TASK_LOG.md`.
7. Runs `tools/validate.sh --machine <name>` and `tools/reconcile.sh --machine <name>`.

The full procedure, including the lost-key recovery path, is in
[`workflows/ADD_MACHINE.md`](workflows/ADD_MACHINE.md).

## Project structure

```
SPEC.md                            # canonical structure — the authority
AGENTS.md                          # agent entry point and saved-key SSH policy
CLAUDE.md                          # agent operating rules
CONTEXT.md / REFERENCES.md / TODO.md
tools/                             # scaffolding, validation, reconciliation, rotation
workflows/                         # ADD_MACHINE.md, ADD_CONTAINER.md, ADD_NAS.md
.claude/
├── agents/                        # machine-operator, vault-writer, drift-auditor
├── commands/                      # /connect /task /add-machine /add-container /audit
├── hooks/                         # root-SSH block, secret-write block, repo validation
└── settings.json
machines/                          # ONE Obsidian vault, rooted here
├── .obsidian/                     # the single vault config, one only (SPEC.md §7)
└── <host>/                        # bare-metal host — a root node
    ├── STATE.md                   # identity, topology, services, open issues (SPEC.md §1)
    ├── CLAUDE.md                  # machine-specific agent rules
    ├── CONTEXT.md                 # purpose, network role, quirks
    ├── REFERENCES.md              # docs, runbooks, vendor links
    ├── .env_<host>                # non-SSH env variables (optional, gitignored)
    ├── vault/                     # persistent memory (SPEC.md §2)
    │   ├── 00_INDEX.md
    │   ├── 01_SYSTEM_INFO.md
    │   ├── 02_SERVICES.md
    │   ├── 03_TASK_LOG.md         # the 5 most recent entries only
    │   ├── 04_NOTES.md
    │   ├── 05_SECURITY.md
    │   ├── 06_BACKUPS.md
    │   ├── 07_UPDATES.md
    │   ├── 08_CONTAINERS.md       # parents only — hosts with VMs or containers
    │   ├── 09_TROUBLESHOOTING.md  # optional
    │   └── archive/YYYY-QN.md     # rotated-out task-log entries
    ├── TOOLS/                     # machine-specific scripts and unit files
    ├── VMs/<name>/                # same layout, recursively
    └── CTs/
        ├── LXC/<name>/            # same layout, recursively
        └── Docker/<name>/         # same layout, recursively
```

The **directory tree is the topology**. There is no `children:` field anywhere: a
machine's parent is `parent:` in its `STATE.md`, and its children are the folders beneath
it. A hand-maintained child list was the worst source of drift found in the audit.

Machines are scaffolded with `tools/new_machine.sh`, never by hand.

## Tooling

All four scripts live in `tools/` and are run from the repo root. `validate.sh` and
`reconcile.sh` are also what the `/audit` command and the repo's `Stop` hook use.

| Script | What it does |
|--------|--------------|
| `new_machine.sh <name> [--type bare-metal\|vm\|lxc\|docker] [--parent <name>] [--hosts-children]` | Scaffolds a machine folder to `SPEC.md`: `STATE.md`, context files, the canonical vault, `archive/`, `TOOLS/`, and an `~/.ssh/config` snippet. `--hosts-children` forces `08_CONTAINERS.md` on an LXC/Docker node that itself hosts machines; bare-metal and VMs always get it. |
| `validate.sh [--quiet] [--machine <name>]` | Structural validation: required files, `STATE.md` schema and enum validity, legacy leftovers, referential integrity of `parent`/`depends_on`/`provides_to`, a secret scan over every markdown file under `machines/`, task-log length, L1 context budget, and dangling documentation references. Exits 0 when there is no FAIL. |
| `reconcile.sh [--machine <name>] [--offline] [--json] [--write]` | Documentation-vs-reality drift detection over SSH: `STATE.md` ip/status/os/parent/type against the live host, `08_CONTAINERS.md` against `pct`/`qm` and the folders on disk, disk-usage thresholds, the systemd units named in `STATE.md`, and `TOOLS/` against the deployed copies. Read-only against remote machines; `--write` touches only `last_reconciled:` and `status:`. Exits 0 clean, 1 drift, 2 tool error. |
| `rotate_tasklog.sh [--dry-run] [--machine <name>] [--keep <n>]` | Keeps the N most recent entries (default 5) in `vault/03_TASK_LOG.md` and **moves** older ones byte-for-byte into `vault/archive/<YYYY>-Q<N>.md`. Verifies byte integrity and restores from backup if it fails. Idempotent. |
| `setup_tuneladora_control.sh` / `setup_tuneladora_target.sh` | The two halves of SSH onboarding, described above. |

## Slash commands

Defined in `.claude/commands/`, with the subagents they delegate to in `.claude/agents/`.

| Command | Purpose |
|---------|---------|
| `/connect <machine>` | Orient on one machine: resolve its folder, read L1 only, print a briefing. Runs nothing remotely. |
| `/task <machine> <description>` | The day-to-day loop: L1 read, plan, confirm if destructive, execute, verify, write the vault. |
| `/add-machine <name>` | Drives `workflows/ADD_MACHINE.md`, stopping at each human handoff. |
| `/add-container <name> --parent <p> --type lxc\|docker` | Drives `workflows/ADD_CONTAINER.md`. |
| `/audit [machine]` | Runs validate + reconcile through the read-only `drift-auditor` and proposes fixes without applying them. |

Two `PreToolUse` hooks are active: one blocks `ssh root@`, the other blocks writing a live
secret into `machines/**` (`SPEC.md §5`). A `Stop` hook validates the repository at the
end of a session.

## Reading cost

The agent reads by tier, never the whole folder — `SPEC.md §3`. L1 (`STATE.md`,
`CLAUDE.md`, the parent's `STATE.md`) is always read and budgeted at ~4 KB. L2 is for
service/config work, L3 is investigation by `grep` only. Reading one machine's whole
vault cost ~19k tokens before a single command ran; that is the problem the tiering
exists to solve.

## License

[MIT](LICENSE)
