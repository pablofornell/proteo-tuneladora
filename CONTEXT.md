# Current Project

## What we are building

Tuneladora — an SSH connection hub operated by an LLM to manage multiple remote servers.
The LLM connects over SSH, executes tasks, and maintains persistent memory of each
machine in a single Obsidian vault rooted at `machines/`.

Structure is specified in [`SPEC.md`](SPEC.md); operating behaviour in
[`CLAUDE.md`](CLAUDE.md).

## What good looks like

- **Reading is tiered.** L1 (`STATE.md` + machine `CLAUDE.md`, under ~4 KB) before every
  action; L2 only when the task touches a service, config or package; L3 only by `grep`,
  for investigation. Context cost scales with the task, not with the machine's history.
- **`STATE.md` is true.** Identity, network, topology and dependencies match the live
  machine, and `last_reconciled` says when that was checked. Drift is fixed when found,
  not logged and left.
- **One vault, linked across machines.** Cross-machine links are path-qualified and
  encouraged — a dependency described in prose should also be a link.
- **Every task leaves a trail.** A `03_TASK_LOG.md` entry with real verification, rotated
  at 5 entries into `vault/archive/`. Entries are never deleted or reworded.
- **No secrets in the repo.** Only the location of the live value. A secret found in an
  append-only log is redacted in place and rotated.

## What to avoid

- Reading a machine's whole folder and vault before acting.
- Hand-maintaining a child list; the directory tree is the authority on containment.
- Acting on a machine without its L1 context, or assuming state without verifying it.
- Finishing a task without updating the vault and `STATE.md`.
- Destructive changes without explicit user confirmation.
- Writing a credential into any repo file, or leaving a scaffolded template unpopulated.
