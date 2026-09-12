---
description: Audit the repository against reality — run validate + reconcile, summarise the drift, and propose fixes without applying them. Optionally scoped to one machine.
argument-hint: [machine]
arguments: [machine]
allowed-tools: Read, Grep, Glob, Bash, Agent(drift-auditor, vault-writer, machine-operator)
---

# Audit `$machine`

Scope: `$machine` if given, otherwise the whole repository.

## Run it

Delegate to the **`drift-auditor`** subagent. It is read-only by construction — it has
no `Edit` or `Write` — so it cannot silently "fix" anything, which is the point.

Give it:

- the scope (`$machine`, or "all machines")
- the instruction to run `tools/validate.sh` and `tools/reconcile.sh` (with the
  machine argument when scoped) and interpret their output
- the reading tiers: **L1** always (`STATE.md`, `CLAUDE.md`, parent's `STATE.md`),
  **L2** only when a finding touches a service/config/package, **L3 by `grep` only**
  — never a full read of `03_TASK_LOG.md` or `archive/*`. An audit that reads the
  whole vault has already failed at its own job (~77 KB / ~19k tokens, 38 % of it log
  history).
- the requirement to classify each finding and say who would apply the fix

## Summarise the drift

Present findings **FAIL first**, then WARN, then INFO. One line each, with evidence:

```
FAIL  hef-net       STATE.md ip 192.168.0.31 ≠ live 192.168.0.44, ip_assignment: static
      evidence: reconcile.sh line 12
      fix:      update STATE.md ip → 192.168.0.44, or restore the static lease
      by:       vault-writer (doc) / operator (decide which side is wrong)
```

Group by machine. Say plainly when there is no drift — `clean` is a real, good result
and manufacturing findings to look useful is worse than finding nothing.

## Propose, never apply

**Do not apply any fix in this command.** Present the proposals and stop. For each,
say who executes:

| Class | Applied by |
|-------|-----------|
| stale-doc (`STATE.md` behind reality) | `vault-writer`, after the operator confirms which side is right |
| stale-reality (documented intent never applied) | `machine-operator` via `/task <machine> <fix>` |
| duplication (a `STATE.md` fact restated in prose) | `vault-writer` — delete the prose copy; `STATE.md` is the single source of truth |
| structural (missing file, dangling `parent`, child missing from the parent's `08_CONTAINERS.md`) | `vault-writer`, or `tools/new_machine.sh` for a whole missing folder |
| **secret-leak** (a live value in a vault file) | **operator first** — see below |
| benign | nobody; say why it is benign |

### Secret leaks are a special case

A secret found in a vault file has already been committed. Redacting the file does
not un-leak it. The order is:

1. **Rotate the secret on the machine** (`/task <machine> rotate <thing>`).
2. Then replace the value with `<redacted YYYY-MM-DD — live value: <location>>`.
3. Then log both in `03_TASK_LOG.md`.

Report it as FAIL and say the rotation is step one. Never print the leaked value in
your output — name the file and line.

## After the operator decides

Only once they have chosen, hand the confirmed corrections to `vault-writer` (for
documents) or run `/task` (for machines). `last_reconciled` in `STATE.md` is bumped
only when `reconcile.sh` actually ran against that machine.

## Report

```
Audit scope:  <machine | all>
validate.sh:  <exit code> — N FAIL, N WARN
reconcile.sh: <exit code> — N differences
Status:       clean | drift-found | tooling-failed
Findings:     <the grouped list above>
Next step:    <the single most important action, or "nothing — repository is clean">
```
