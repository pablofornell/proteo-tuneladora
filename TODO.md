# TODO

Repository-level follow-ups only. **Per-machine issues do not live here.**

## Where the real work is tracked

- **Open issues per machine:** the `## Open Issues` section of each
  `machines/**/STATE.md`, as dated bullets (`SPEC.md §1.3`). That is the tracker — it
  sits next to the machine it concerns and is read as part of L1. Do not duplicate those
  items into this file; a copy here would drift within a week, which is the exact failure
  the audit was about.
- **Drift between the documentation and reality:** `tools/reconcile.sh` finds it on
  demand. Run `tools/reconcile.sh` for the whole repo or `--machine <name>` for one, and
  `/audit` to have the read-only `drift-auditor` interpret the output and propose fixes.
  A finding is not a TODO item until someone has decided which side is wrong.

## Open, repo-level

- **Tuneladora needs a real secret-management system.** *(Operator decision, 2026-09-12 —
  build this.)* Today the arrangement is deliberate but minimal: the live value stays in
  the machine's own config file, the vault records only **where** it lives, and a
  `PreToolUse` hook blocks writing a value into `machines/**` (`SPEC.md §5`). That stops
  the leak the audit found, but it is not management. Nothing can answer "what is the
  RCON password", "when was it last changed", or "which machines share a credential", and
  a rotation is a hand-run script with the new values printed once to a terminal.

  What it should become: a secret store as the single source of truth — `pass`, Bitwarden
  or the system keyring via `secret-tool` — with `STATE.md` and the vault referencing a
  stable **secret ID** rather than a filesystem path, so moving a config file does not
  strand the pointer. Tuneladora would read a secret only when a task needs it, write it
  only into the target machine, and log the rotation date, never the value. Worth pairing
  with the existing `05_SECURITY.md` note per machine so age and reuse become visible.

  Precondition, still outstanding: five credentials were redacted from
  `machines/hef-proxmox/CTs/LXC/hef-pzserver/` on 2026-09-12 and **have not been
  rotated** — redaction is not rotation, and all five are still valid. See that machine's
  `STATE.md § Open Issues`. The operator chose to defer this until WAHA and the PZ server
  are next started, since both are down and nothing can be verified while they are.

- **A UI.** Some way to see the fleet — machines, status, open issues, last reconcile —
  without reading markdown by hand. `tools/reconcile.sh --json` already emits
  machine-readable output, so a read-only dashboard over that is the cheapest first
  version.
- **Historical task logs are not in English.** `03_TASK_LOG.md` and `vault/archive/*`
  keep existing entries verbatim in whatever language they were written; `SPEC.md §4.3`
  and `§6` forbid rewriting them, and translation is a rewrite. New entries are written
  in English. If translated history is ever wanted, it has to be an *added* parallel
  rendering, never an edit to the originals — decide deliberately, not by drifting into
  it.
- **Machine `TOOLS/` directories are outside the language policy.** `SPEC.md §6` covers
  the markdown an agent reads to act; it says nothing about the scripts and unit files in
  `machines/**/TOOLS/`, whose comments and output are in mixed languages. Either extend
  the policy to them or state explicitly that they are exempt. Related, and worse:
  `tools/reconcile.sh` reports that a repo `TOOLS/` copy is **not** evidence of what is
  deployed — those snapshots drift in both directions and nothing keeps them in sync.
  Deciding which copy is authoritative is still an open question.
