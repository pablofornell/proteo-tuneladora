#!/usr/bin/env bash
# PreToolUse hook, matcher "Bash".
#
# Blocks any attempt to open an SSH/SCP/SFTP session as root. Tuneladora connects
# as the dedicated `tuneladora` user and escalates with sudo; connecting as root is
# forbidden. Until now that was only a polite request in CLAUDE.md.
#
# Contract (docs.claude.com/en/docs/claude-code -> code.claude.com/docs/en/hooks):
#   stdin  : JSON with .tool_name and .tool_input.command
#   exit 0 : no decision, normal permission flow applies
#   exit 2 : blocks the tool call; stderr is shown to the user and to Claude
set -uo pipefail

INPUT="$(cat)"

# --- JSON field extraction (jq preferred, python3 fallback, fail closed) --------
json_get() { # $1 = dotted path
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r --arg p "$1" '
      (try getpath($p | split(".")) catch null) as $v
      | if $v == null then "" elif ($v|type) == "string" then $v else ($v|tojson) end'
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$INPUT" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for k in sys.argv[1].split("."):
    if isinstance(d,dict) and k in d: d=d[k]
    else: d=""; break
print(d if isinstance(d,str) else json.dumps(d))' "$1"
  else
    echo "__NO_JSON_PARSER__"
  fi
}

deny() {
  local reason="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  fi
  printf '%s\n' "$reason" >&2
  exit 2
}

COMMAND="$(json_get tool_input.command)"

if [ "$COMMAND" = "__NO_JSON_PARSER__" ]; then
  deny "tuneladora hook: neither jq nor python3 is available, so the root-SSH guard cannot inspect this command. Blocking rather than allowing an unchecked connection. Install jq."
fi

[ -n "$COMMAND" ] || exit 0

# --- Detection -----------------------------------------------------------------
# 1. root@ as the destination of ssh/scp/sftp:   ssh root@host, ssh -i k root@host
# 2. -l root / -lroot:                           ssh -l root host
# 3. -o User=root:                               ssh -o User=root host
# [^;&|]* keeps a match inside one command, but deliberately still sees a nested
# `ssh <alias> "ssh root@inner"`, which is the same violation one hop away.
ROOT_DEST='(^|[^[:alnum:]_-])(ssh|scp|sftp)([^;&|]*[[:space:]])?root@'
ROOT_LOGIN='(^|[^[:alnum:]_-])ssh[^;&|]*[[:space:]]-l[[:space:]]*root([[:space:]]|$)'
ROOT_OPT='(^|[^[:alnum:]_-])(ssh|scp|sftp)[^;&|]*[[:space:]]-o[[:space:]]*"?User=root'

if printf '%s' "$COMMAND" | grep -qiE "$ROOT_DEST|$ROOT_LOGIN|$ROOT_OPT"; then
  deny "BLOCKED: connecting as root is forbidden in Tuneladora.

Connect with the dedicated user instead and escalate in-session:
  ssh <alias> \"sudo <command>\"

The alias lives in the machine's STATE.md (ssh_alias). Passwordless sudo for the
tuneladora user is already configured, so nothing needs a root login. For an LXC,
the documented fallback goes through the parent:
  ssh <parent> \"sudo pct exec <container_id> -- <command>\"

This rule has no override. If you believe you need a root session, stop and ask the
operator."
fi

exit 0
