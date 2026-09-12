#!/usr/bin/env bash
# Stop hook (no matcher — Stop fires on every turn end).
#
# Runs tools/validate.sh --quiet and surfaces any FAIL to the operator.
#
# Deliberately NON-BLOCKING: it exits 0 and reports through the `systemMessage`
# JSON field. Exit 2 on a Stop hook prevents Claude from stopping and continues the
# conversation, and a validation FAIL is frequently something only the operator can
# resolve (a machine that is genuinely down, a decision about which side of a drift
# is correct). Blocking on that would loop the session instead of fixing anything.
# Surfacing is the requirement; blocking is not.
#
# Contract:
#   stdin  : JSON (Stop event; not needed here, but must be drained)
#   stdout : JSON {"systemMessage": "..."} shown to the operator
#   exit 0 : Claude stops normally
set -uo pipefail

cat >/dev/null 2>&1 || true   # drain stdin

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
VALIDATE="${ROOT}/tools/validate.sh"

# Nothing to do if the tool is not present (fresh clone, or running outside the repo).
[ -f "$VALIDATE" ] || exit 0

OUTPUT="$(cd "$ROOT" && bash "$VALIDATE" --quiet 2>&1)" || true

FAILS="$(printf '%s\n' "$OUTPUT" | grep -E '(^|[^A-Za-z])FAIL([^A-Za-z]|$)' || true)"
[ -n "$FAILS" ] || exit 0

COUNT="$(printf '%s\n' "$FAILS" | grep -c . || true)"

MESSAGE="tools/validate.sh reports ${COUNT} FAIL(s) in the machine records:

${FAILS}

Run /audit for the full picture and the proposed corrections."

if command -v jq >/dev/null 2>&1; then
  jq -n --arg m "$MESSAGE" '{systemMessage: $m}'
else
  printf '%s\n' "$MESSAGE" >&2
fi

exit 0
