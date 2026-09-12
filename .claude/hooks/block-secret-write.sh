#!/usr/bin/env bash
# PreToolUse hook, matcher "Write|Edit".
#
# Blocks writing an apparent LIVE SECRET into machines/**. The repository audit
# found a live API key and a server password sitting in an append-only task log —
# once committed, redacting afterwards does not un-leak them. This is the control
# that would have stopped that at the moment of writing.
#
# Vault files record WHERE a secret lives, never WHAT it is:
#     <redacted YYYY-MM-DD — live value: /opt/waha/.env, key WHATSAPP_API_KEY>
#
# Explicitly allowed (neutralised before scanning):
#   * the <redacted ...> placeholder
#   * SSH PUBLIC keys: ssh-ed25519 AAAA... / ssh-rsa AAAA... / ecdsa-sha2-* AAAA...
#   * bcrypt hashes: $2y$.. / $2a$.. / $2b$..
#   * lines whose context marks the hex blob as a checksum/fingerprint/UUID
#
# Contract:
#   stdin  : JSON with .tool_name and .tool_input.{file_path,content,new_string}
#   exit 0 : no decision, normal permission flow applies
#   exit 2 : blocks the tool call; stderr is shown to the user and to Claude
set -uo pipefail

INPUT="$(cat)"

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

FILE_PATH="$(json_get tool_input.file_path)"

if [ "$FILE_PATH" = "__NO_JSON_PARSER__" ]; then
  deny "tuneladora hook: neither jq nor python3 is available, so the secret guard cannot inspect this write. Blocking rather than allowing an unscanned write into machines/. Install jq."
fi

# --- Scope: only machine records ----------------------------------------------
case "$FILE_PATH" in
  machines/*|*/machines/*) ;;
  *) exit 0 ;;
esac

# --- Gather the text being introduced -----------------------------------------
CONTENT="$(json_get tool_input.content)"          # Write
NEW_STRING="$(json_get tool_input.new_string)"    # Edit
PAYLOAD="${CONTENT}
${NEW_STRING}"

[ -n "${PAYLOAD//[[:space:]]/}" ] || exit 0

# --- Neutralise the explicitly-allowed constructs ------------------------------
# Each is replaced by "<>" so that a "password: <redacted ...>" line cannot then
# trip the password rule: the rules all refuse a value starting with "<".
# NOTE: '#' is the sed delimiter — the patterns contain '|', '/' and '='.
NEUTRAL="$(printf '%s' "$PAYLOAD" | sed -E \
  -e 's#<redacted[^>]*>#<>#g' \
  -e 's#(ssh-(ed25519|rsa|dss)|ecdsa-sha2-[A-Za-z0-9-]+|sk-ssh-[A-Za-z0-9@.-]+)[[:space:]]+AAAA[A-Za-z0-9+/=]*#<>#g' \
  -e 's#[$]2[aby][$][0-9]{2}[$][A-Za-z0-9./]{20,}#<>#g')"

# Fail closed: if the neutralisation step broke, an empty NEUTRAL would silently
# let every rule below pass.
if [ -z "${NEUTRAL//[[:space:]]/}" ]; then
  deny "tuneladora hook: the secret scanner could not process this write (the neutralisation step produced no text). Blocking rather than allowing an unscanned write into ${FILE_PATH}."
fi

hit=""
add_hit() { hit="${hit}  - ${1}: line ${2}"$'\n'; }

# Rule 1 — a 32+ character hex blob (API keys, tokens, raw key material).
# Skipped when the line's own context marks it as a checksum/fingerprint/UUID.
while IFS= read -r n; do
  [ -n "$n" ] && add_hit "32+ char hex value" "$n"
done < <(printf '%s\n' "$NEUTRAL" | grep -nE '[0-9a-fA-F]{32,}' \
         | grep -viE '(sha-?1|sha-?256|sha-?512|md5|checksum|fingerprint|[[:space:]]commit|blkid|uuid)' \
         | cut -d: -f1)

# Rule 2 — password / passwd / pwd assigned a literal value.
while IFS= read -r n; do
  [ -n "$n" ] && add_hit "password assigned a literal value" "$n"
done < <(printf '%s\n' "$NEUTRAL" \
         | grep -niE '(^|[^a-z0-9_])(password|passwd|pwd|pass)[[:space:]]*[:=][[:space:]]*["'"'"']?[^[:space:]"'"'"'<][^[:space:]"'"'"']{5,}' \
         | cut -d: -f1)

# Rule 3 — api_key / token / secret assigned a literal value.
while IFS= read -r n; do
  [ -n "$n" ] && add_hit "api key / token / secret assigned a literal value" "$n"
done < <(printf '%s\n' "$NEUTRAL" \
         | grep -niE '(^|[^a-z0-9_])(api[_-]?key|apikey|api[_-]?token|access[_-]?token|auth[_-]?token|secret[_-]?key|client[_-]?secret|token|secret)[[:space:]]*[:=][[:space:]]*["'"'"']?[^[:space:]"'"'"'<][^[:space:]"'"'"']{7,}' \
         | cut -d: -f1)

# Rule 4 — private / pre-shared key material assigned a literal value.
while IFS= read -r n; do
  [ -n "$n" ] && add_hit "private / pre-shared key assigned a literal value" "$n"
done < <(printf '%s\n' "$NEUTRAL" \
         | grep -niE '(private[_-]?key|presharedkey|pre[_-]?shared[_-]?key)[[:space:]]*[:=][[:space:]]*["'"'"']?[^[:space:]"'"'"'<][^[:space:]"'"'"']{7,}' \
         | cut -d: -f1)

# Rule 5 — an embedded PEM private key block.
while IFS= read -r n; do
  [ -n "$n" ] && add_hit "PEM PRIVATE KEY block" "$n"
done < <(printf '%s\n' "$NEUTRAL" \
         | grep -nE 'BEGIN[[:space:]]+([A-Z0-9]+[[:space:]]+)*PRIVATE[[:space:]]+KEY' \
         | cut -d: -f1)

[ -n "$hit" ] || exit 0

deny "BLOCKED: this write looks like it puts a LIVE SECRET into ${FILE_PATH}.

Matched (line numbers are within the text being written; the values are deliberately
not echoed here):
${hit}
Machine records store the LOCATION of a secret, never its value. Replace the value
with the redaction placeholder:

  <redacted $(date +%Y-%m-%d) — live value: <where the live value actually lives>>

for example:

  API key: <redacted $(date +%Y-%m-%d) — live value: /opt/waha/.env, key WHATSAPP_API_KEY>
  Admin password: <redacted $(date +%Y-%m-%d) — live value: operator's password manager>

These stay allowed and are not what tripped the rule: SSH PUBLIC keys
(ssh-ed25519 AAAA... / ssh-rsa AAAA...), bcrypt hashes (\$2y\$...), key fingerprints,
paths and port numbers.

If the value is already live in git, redacting is step two — the secret must be
ROTATED on the machine first."
