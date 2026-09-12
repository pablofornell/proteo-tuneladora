#!/usr/bin/env bash
# validate.sh — Structural validator for the Tuneladora machine vault.
#
# Usage:
#   ./tools/validate.sh [--quiet] [--machine <name>]
#
# Options:
#   --quiet            Only print FAIL lines (plus the final summary).
#   --machine <name>   Validate a single machine folder by name.
#   -h, --help         Show this help.
#
# Checks performed per machine folder:
#   1. Required files present (STATE.md, CLAUDE.md, CONTEXT.md, vault/00..07).
#   2. No legacy files left behind (HIERARCHY.md, vault/06_CONTAINERS.md,
#      vault/07_TROUBLESHOOTING.md).
#   3. STATE.md frontmatter has every required key, in order, with valid enums.
#   4. Referential integrity: parent / depends_on / provides_to resolve to
#      machine folders that actually exist in the tree.
#   5. Secret scan over every *.md under machines/.
#   6. Task-log size (rotation reminder).
#   7. L1 context budget (STATE.md + CLAUDE.md <= 6 KB).
#   8. Dangling documentation references (skips the append-only task log and
#      vault/archive/*, per SPEC.md §4.3).
#
# Exit status: 0 when no FAIL was reported, 1 otherwise.
# No external dependencies are required; yq is used when available.

set -euo pipefail

# ── Resolve paths ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MACHINES_DIR="$REPO_ROOT/machines"

# ── Parse arguments ────────────────────────────────────────────────────────────

QUIET=0
ONLY_MACHINE=""

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet)   QUIET=1; shift ;;
    --machine) ONLY_MACHINE="${2:-}"; [[ -n "$ONLY_MACHINE" ]] || { echo "Error: --machine needs a name" >&2; exit 2; }; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! -d "$MACHINES_DIR" ]]; then
  echo "Error: machines/ not found at $MACHINES_DIR" >&2
  exit 2
fi

# ── Reporting ──────────────────────────────────────────────────────────────────

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

if [[ -t 1 ]]; then
  C_PASS=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_PASS=""; C_WARN=""; C_FAIL=""; C_DIM=""; C_OFF=""
fi

# report <PASS|WARN|FAIL> <path> <message>
report() {
  local level="$1" path="$2" msg="$3" color=""
  case "$level" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)); color="$C_PASS"; [[ $QUIET -eq 1 ]] && return 0 ;;
    WARN) WARN_COUNT=$((WARN_COUNT + 1)); color="$C_WARN"; [[ $QUIET -eq 1 ]] && return 0 ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)); color="$C_FAIL" ;;
  esac
  printf '%s%-4s%s %s%s%s %s\n' "$color" "$level" "$C_OFF" "$C_DIM" "$path" "$C_OFF" "$msg"
}

# Strip the repo root prefix so output stays readable.
rel() { printf '%s' "${1#"$REPO_ROOT"/}"; }

# ── Machine discovery ──────────────────────────────────────────────────────────
# A machine folder is any directory that contains STATE.md or a vault/ subdir.
# Machine folders nest: machines/<host>/{VMs,CTs/LXC,CTs/Docker}/<name>/

MACHINE_DIRS=()
declare -A NAME_TO_DIR=()
declare -A DIR_IS_MACHINE=()

discover_machines() {
  local d
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    if [[ -f "$d/STATE.md" || -d "$d/vault" ]]; then
      MACHINE_DIRS+=("$d")
      DIR_IS_MACHINE["$d"]=1
      local name; name="$(basename "$d")"
      if [[ -n "${NAME_TO_DIR[$name]:-}" ]]; then
        report FAIL "$(rel "$d")" "duplicate machine name '$name' (also at $(rel "${NAME_TO_DIR[$name]}"))"
      else
        NAME_TO_DIR["$name"]="$d"
      fi
    fi
  done < <(find "$MACHINES_DIR" -name '.git' -prune -o -name '.obsidian' -prune -o -mindepth 1 -type d -print | sort)
}

# Children of a machine, derived from the directory tree (never hand-maintained).
children_of() {
  local m="$1" sub c
  for sub in "VMs" "CTs/LXC" "CTs/Docker"; do
    [[ -d "$m/$sub" ]] || continue
    for c in "$m/$sub"/*; do
      [[ -d "$c" ]] || continue
      [[ -n "${DIR_IS_MACHINE[$c]:-}" ]] && printf '%s\n' "$c"
    done
  done
}

# Parent of a machine, derived from the directory tree.
tree_parent_of() {
  local d="$1" p
  p="$(dirname "$d")"
  while [[ "$p" != "$MACHINES_DIR" && "$p" != "/" ]]; do
    if [[ -n "${DIR_IS_MACHINE[$p]:-}" ]]; then
      basename "$p"
      return 0
    fi
    p="$(dirname "$p")"
  done
  printf 'null'
}

# ── YAML frontmatter helpers ───────────────────────────────────────────────────

YQ_OK=0
detect_yq() {
  command -v yq >/dev/null 2>&1 || return 0
  # Only mikefarah-style yq (v4) is used; anything else falls back to awk.
  if printf 'a: 1\n' | yq -r 'keys | .[]' >/dev/null 2>&1; then
    YQ_OK=1
  fi
}

# Print the raw frontmatter block (between the leading --- fences).
fm_block() {
  awk '
    NR == 1 { if ($0 != "---") exit 0; infm = 1; next }
    infm && $0 == "---" { exit 0 }
    infm { print }
  ' "$1"
}

# Print the top-level keys of the frontmatter, in document order.
fm_keys() {
  local file="$1"
  if [[ $YQ_OK -eq 1 ]]; then
    local out
    if out="$(fm_block "$file" | yq -r 'keys | .[]' 2>/dev/null)"; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  fm_block "$file" | awk '/^[A-Za-z_][A-Za-z0-9_]*:/ { sub(/:.*$/, ""); print }'
}

# Print the scalar value of a top-level frontmatter key ("" when absent).
fm_scalar() {
  local file="$1" key="$2"
  fm_block "$file" | awk -v key="$key" '
    index($0, key ":") == 1 {
      v = substr($0, length(key) + 2)
      sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      gsub(/^"|"$/, "", v); gsub(/^'"'"'|'"'"'$/, "", v)
      print v
      exit
    }
  '
}

# Print every `machine:` value nested under a top-level list key.
fm_list_machines() {
  local file="$1" key="$2"
  fm_block "$file" | awk -v key="$key" '
    /^[A-Za-z_][A-Za-z0-9_]*:/ {
      k = $0; sub(/:.*$/, "", k)
      inblk = (k == key) ? 1 : 0
      next
    }
    inblk && match($0, /machine:[ \t]*/) {
      v = substr($0, RSTART + RLENGTH)
      sub(/[ \t]*#.*$/, "", v)
      sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      gsub(/^"|"$/, "", v); gsub(/^'"'"'|'"'"'$/, "", v)
      if (v != "" && v != "null") print v
    }
  '
}

# Print the sub-keys nested under a top-level mapping key.
fm_subkeys() {
  local file="$1" key="$2"
  fm_block "$file" | awk -v key="$key" '
    /^[A-Za-z_][A-Za-z0-9_]*:/ {
      k = $0; sub(/:.*$/, "", k)
      inblk = (k == key) ? 1 : 0
      next
    }
    inblk && match($0, /^[ \t]+[A-Za-z_][A-Za-z0-9_]*:/) {
      k = $0
      sub(/^[ \t]+/, "", k); sub(/:.*$/, "", k)
      print k
    }
  '
}

is_placeholder() {
  case "$1" in
    ""|null|Null|NULL|unknown|TBD|"*(TBD)*"|"~") return 0 ;;
    *) return 1 ;;
  esac
}

in_list() {
  local needle="$1"; shift
  local item
  for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
  return 1
}

# ── Canonical definitions ──────────────────────────────────────────────────────

REQUIRED_STATE_KEYS=(
  machine type parent container_id connection ssh_alias ip ip_assignment
  status os depends_on provides_to backups auto_updates last_reconciled
)

REQUIRED_VAULT_FILES=(
  00_INDEX.md 01_SYSTEM_INFO.md 02_SERVICES.md 03_TASK_LOG.md
  04_NOTES.md 05_SECURITY.md 06_BACKUPS.md 07_UPDATES.md
)

LEGACY_RENAMES=(
  "HIERARCHY.md|replace with STATE.md (new frontmatter schema)"
  "vault/06_CONTAINERS.md|rename to vault/08_CONTAINERS.md"
  "vault/07_TROUBLESHOOTING.md|rename to vault/09_TROUBLESHOOTING.md"
)

VALID_TYPE=(bare-metal vm lxc docker)
VALID_CONNECTION=(direct proxyjump docker-exec)
VALID_IP_ASSIGNMENT=(static dhcp none)
VALID_STATUS=(running stopped unknown)

TASK_LOG_MAX_ENTRIES=5
L1_BUDGET_BYTES=6144

# ── Check 1 + 2: file layout ───────────────────────────────────────────────────

check_files() {
  local m="$1" name="$2" f missing=0
  local child_count; child_count="$(children_of "$m" | wc -l)"

  for f in STATE.md CLAUDE.md CONTEXT.md; do
    if [[ -f "$m/$f" ]]; then
      report PASS "$(rel "$m/$f")" "present"
    else
      report FAIL "$(rel "$m/$f")" "missing required file"
      missing=1
    fi
  done

  for f in "${REQUIRED_VAULT_FILES[@]}"; do
    if [[ -f "$m/vault/$f" ]]; then
      report PASS "$(rel "$m/vault/$f")" "present"
    else
      report FAIL "$(rel "$m/vault/$f")" "missing required vault note"
      missing=1
    fi
  done

  if [[ -f "$m/vault/08_CONTAINERS.md" ]]; then
    report PASS "$(rel "$m/vault/08_CONTAINERS.md")" "present"
  elif [[ "$child_count" -gt 0 ]]; then
    report FAIL "$(rel "$m/vault/08_CONTAINERS.md")" "missing; machine hosts $child_count child machine(s) in the tree"
  fi

  # 09_TROUBLESHOOTING.md is optional — no report either way.

  local entry legacy hint
  for entry in "${LEGACY_RENAMES[@]}"; do
    legacy="${entry%%|*}"
    hint="${entry#*|}"
    if [[ -e "$m/$legacy" ]]; then
      report FAIL "$(rel "$m/$legacy")" "legacy file — $hint"
    fi
  done

  return $missing
}

# ── Check 3: STATE.md frontmatter ──────────────────────────────────────────────

check_state_frontmatter() {
  local m="$1" name="$2"
  local state="$m/STATE.md"
  [[ -f "$state" ]] || return 0

  local first_line
  first_line="$(head -n 1 "$state")"
  if [[ "$first_line" != "---" ]]; then
    report FAIL "$(rel "$state")" "no YAML frontmatter (file must start with '---')"
    return 0
  fi
  if ! grep -qx -- '---' <(tail -n +2 "$state"); then
    report FAIL "$(rel "$state")" "unterminated YAML frontmatter (missing closing '---')"
    return 0
  fi

  if [[ $YQ_OK -eq 1 ]]; then
    if ! fm_block "$state" | yq -e 'type == "!!map"' >/dev/null 2>&1; then
      report FAIL "$(rel "$state")" "frontmatter does not parse as a YAML mapping"
      return 0
    fi
  fi

  local keys=() k
  while IFS= read -r k; do [[ -n "$k" ]] && keys+=("$k"); done < <(fm_keys "$state")

  local missing_keys=()
  for k in "${REQUIRED_STATE_KEYS[@]}"; do
    in_list "$k" ${keys[@]+"${keys[@]}"} || missing_keys+=("$k")
  done
  if [[ ${#missing_keys[@]} -gt 0 ]]; then
    report FAIL "$(rel "$state")" "frontmatter missing key(s): ${missing_keys[*]}"
  else
    report PASS "$(rel "$state")" "frontmatter has all ${#REQUIRED_STATE_KEYS[@]} required keys"
  fi

  # Key order (canonical order is part of the contract, but drift is only a WARN).
  local ordered=() expected_order
  for k in ${keys[@]+"${keys[@]}"}; do
    in_list "$k" "${REQUIRED_STATE_KEYS[@]}" && ordered+=("$k")
  done
  expected_order="$(printf '%s\n' "${REQUIRED_STATE_KEYS[@]}" | grep -Fx -f <(printf '%s\n' ${ordered[@]+"${ordered[@]}"}) || true)"
  if [[ ${#ordered[@]} -gt 0 && "$(printf '%s\n' "${ordered[@]}")" != "$expected_order" ]]; then
    report WARN "$(rel "$state")" "frontmatter keys are not in canonical order"
  fi

  # machine: must match the folder name.
  local machine_val; machine_val="$(fm_scalar "$state" machine)"
  if [[ -n "$machine_val" && "$machine_val" != "$name" ]]; then
    report FAIL "$(rel "$state")" "machine: '$machine_val' does not match folder name '$name'"
  fi

  # Enum validation.
  check_enum "$state" type       "${VALID_TYPE[@]}"
  check_enum "$state" connection "${VALID_CONNECTION[@]}"
  check_enum "$state" ip_assignment "${VALID_IP_ASSIGNMENT[@]}"
  check_enum "$state" status     "${VALID_STATUS[@]}"

  # Nested mappings.
  check_subkeys "$state" backups configured destination last_verified
  check_subkeys "$state" auto_updates configured tool schedule

  # There is deliberately no `children` key — the tree is the source of truth.
  if in_list children ${keys[@]+"${keys[@]}"}; then
    report FAIL "$(rel "$state")" "'children:' key is forbidden — the child list is derived from the directory tree"
  fi

  # last_reconciled sanity.
  local lr; lr="$(fm_scalar "$state" last_reconciled)"
  if is_placeholder "$lr"; then
    report WARN "$(rel "$state")" "last_reconciled is a placeholder — run tools/reconcile.sh"
  elif [[ ! "$lr" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    report FAIL "$(rel "$state")" "last_reconciled '$lr' is not a YYYY-MM-DD date"
  fi
}

check_enum() {
  local file="$1" key="$2"; shift 2
  local value; value="$(fm_scalar "$file" "$key")"
  if is_placeholder "$value"; then
    # `unknown` is a legal status value, not a placeholder.
    if [[ "$key" == "status" && "$value" == "unknown" ]]; then
      report PASS "$(rel "$file")" "$key: unknown"
    else
      report WARN "$(rel "$file")" "$key is a placeholder ('${value:-<empty>}') — expected one of: $*"
    fi
    return 0
  fi
  if in_list "$value" "$@"; then
    report PASS "$(rel "$file")" "$key: $value"
  else
    report FAIL "$(rel "$file")" "invalid $key '$value' — expected one of: $*"
  fi
}

check_subkeys() {
  local file="$1" key="$2"; shift 2
  local found=() sk missing=()
  while IFS= read -r sk; do [[ -n "$sk" ]] && found+=("$sk"); done < <(fm_subkeys "$file" "$key")
  for sk in "$@"; do
    in_list "$sk" ${found[@]+"${found[@]}"} || missing+=("$sk")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    report WARN "$(rel "$file")" "$key: missing sub-key(s): ${missing[*]}"
  fi
}

# ── Check 4: referential integrity ─────────────────────────────────────────────

check_references() {
  local m="$1" name="$2"
  local state="$m/STATE.md"
  [[ -f "$state" ]] || return 0

  local declared_parent tree_parent
  declared_parent="$(fm_scalar "$state" parent)"
  tree_parent="$(tree_parent_of "$m")"

  if is_placeholder "$declared_parent"; then
    if [[ "$tree_parent" != "null" ]]; then
      report FAIL "$(rel "$state")" "parent is null but the machine lives under '$tree_parent' in the tree"
    else
      report PASS "$(rel "$state")" "parent: null (root machine)"
    fi
  elif [[ -z "${NAME_TO_DIR[$declared_parent]:-}" ]]; then
    report FAIL "$(rel "$state")" "parent '$declared_parent' does not resolve to any machine folder"
  elif [[ "$declared_parent" != "$tree_parent" ]]; then
    report FAIL "$(rel "$state")" "parent '$declared_parent' contradicts the tree (actual parent: '$tree_parent')"
  else
    report PASS "$(rel "$state")" "parent: $declared_parent (matches tree)"
  fi

  local key ref unresolved
  for key in depends_on provides_to; do
    unresolved=0
    while IFS= read -r ref; do
      [[ -n "$ref" ]] || continue
      if [[ -z "${NAME_TO_DIR[$ref]:-}" ]]; then
        report FAIL "$(rel "$state")" "$key references unknown machine '$ref'"
        unresolved=1
      fi
    done < <(fm_list_machines "$state" "$key")
    [[ $unresolved -eq 0 ]] && report PASS "$(rel "$state")" "$key references resolve"
  done
}

# ── Check 6: task-log size ─────────────────────────────────────────────────────

check_task_log() {
  local m="$1"
  local log="$m/vault/03_TASK_LOG.md"
  [[ -f "$log" ]] || return 0
  local entries
  entries="$(grep -c '^## ' "$log" || true)"
  entries="${entries:-0}"
  if [[ "$entries" -gt "$TASK_LOG_MAX_ENTRIES" ]]; then
    report WARN "$(rel "$log")" "$entries entries (max $TASK_LOG_MAX_ENTRIES) — run tools/rotate_tasklog.sh"
  else
    report PASS "$(rel "$log")" "$entries entries"
  fi
}

# ── Check 7: L1 context budget ─────────────────────────────────────────────────

file_size() {
  [[ -f "$1" ]] || { printf '0'; return 0; }
  wc -c < "$1" | tr -d ' '
}

check_l1_budget() {
  local m="$1"
  local total=$(( $(file_size "$m/STATE.md") + $(file_size "$m/CLAUDE.md") ))
  if [[ "$total" -gt "$L1_BUDGET_BYTES" ]]; then
    report WARN "$(rel "$m")" "L1 context (STATE.md + CLAUDE.md) is ${total} B, over the ${L1_BUDGET_BYTES} B budget"
  else
    report PASS "$(rel "$m")" "L1 context ${total} B / ${L1_BUDGET_BYTES} B"
  fi
}

# ── Check 5: secret scan ───────────────────────────────────────────────────────

# Lines matching any of these are never treated as live secrets:
# the redaction placeholder, SSH public keys, bcrypt/crypt hashes, and the
# obvious "fill this in" placeholders used throughout the templates.
SECRET_EXEMPT_RE='<redacted|ssh-ed25519 AAAA|ssh-rsa AAAA|ssh-dss AAAA|ecdsa-sha2-nistp[0-9]+ AAAA|\$2[aby]\$|\$6\$|\(TBD\)|<[A-Za-z_][A-Za-z0-9_ -]*>|\$\{[A-Za-z_]|[Rr][Ee][Dd][Aa][Cc][Tt][Ee][Dd]'

# Each entry is: <regex> TAB <label> TAB <extra per-pattern exemption regex>
SECRET_PATTERNS=(
  $'\\b[0-9a-fA-F]{32,}\\b\t32+ char hex string (possible key/hash)\thttps?://'
  $'[Pp]assword[[:space:]]*=[[:space:]]*[^[:space:]]+\tpassword assignment\t'
  $'api[_-]?key["\':= ]+[^[:space:]]{16,}\tapi key assignment\t'
  $'-----BEGIN .* PRIVATE KEY-----\tprivate key block\t'
  $'token["\':= ]+[^[:space:]]{20,}\ttoken assignment\t'
)

check_secrets() {
  local root="$1"
  local files=() f entry pat label extra hits found=0
  while IFS= read -r f; do files+=("$f"); done \
    < <(find "$root" -name '.git' -prune -o -type f -name '*.md' -print | sort)
  [[ ${#files[@]} -gt 0 ]] || return 0

  for entry in "${SECRET_PATTERNS[@]}"; do
    IFS=$'\t' read -r pat label extra <<< "$entry"
    if [[ -n "$extra" ]]; then
      hits="$(grep -InE -- "$pat" "${files[@]}" 2>/dev/null \
        | grep -vE -- "$SECRET_EXEMPT_RE" \
        | grep -vE -- "$extra" || true)"
    else
      hits="$(grep -InE -- "$pat" "${files[@]}" 2>/dev/null \
        | grep -vE -- "$SECRET_EXEMPT_RE" || true)"
    fi
    [[ -n "$hits" ]] || continue
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      local path rest lineno
      path="${f%%:*}"
      rest="${f#*:}"
      lineno="${rest%%:*}"
      report FAIL "$(rel "$path"):$lineno" "possible live secret — $label"
      found=1
    done <<< "$hits"
  done
  [[ $found -eq 0 ]] && report PASS "$(rel "$root")" "secret scan clean (${#files[@]} markdown files)"
  return 0
}

# ── Check 8: dangling documentation references ─────────────────────────────────

check_dangling_refs() {
  local root="$1"
  local files=() f
  while IFS= read -r f; do files+=("$f"); done < <(
    {
      find "$root" -name '.git' -prune -o -type f -name '*.md' -print
      if [[ "$root" == "$REPO_ROOT" ]]; then
        find "$REPO_ROOT/tools" -maxdepth 1 -type f -name '*.sh' -print
      fi
    } | sort -u
  )
  [[ ${#files[@]} -gt 0 ]] || return 0

  local self="$SCRIPT_DIR/validate.sh"
  local line lineno text target dir resolved
  for f in "${files[@]}"; do
    [[ "$f" == "$self" ]] && continue   # the validator names these files on purpose
    # vault/03_TASK_LOG.md and vault/archive/* are append-only historical record
    # (SPEC.md §4.3, §6): entries are never deleted or reworded, so a mention of
    # a file that existed when the entry was written is correct history, not a
    # stale reference. Warning there would be noise nobody is allowed to act on.
    # This exclusion is deliberate — it applies to this check only; the secret
    # scan (check 5) still covers the task log and the archive in full.
    [[ "$f" == */vault/03_TASK_LOG.md ]] && continue
    [[ "$f" == */vault/archive/* ]] && continue
    dir="$(dirname "$f")"

    # Bare mentions of files that no longer exist at the repo root.
    if grep -q 'REGISTRY\.md' "$f" 2>/dev/null && [[ ! -f "$REPO_ROOT/REGISTRY.md" ]]; then
      report WARN "$(rel "$f")" "references REGISTRY.md, which no longer exists in the repo"
    fi
    if grep -q 'SPEC\.md' "$f" 2>/dev/null && [[ ! -f "$REPO_ROOT/SPEC.md" ]]; then
      report WARN "$(rel "$f")" "references SPEC.md, which does not exist in the repo"
    fi
    if grep -q 'HIERARCHY\.md' "$f" 2>/dev/null; then
      report WARN "$(rel "$f")" "references HIERARCHY.md, superseded by STATE.md"
    fi

    # Relative markdown links: [text](some/path.md)
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      lineno="${line%%:*}"
      text="${line#*:}"
      target="$text"
      case "$target" in
        http://*|https://*|mailto:*|'#'*) continue ;;
      esac
      target="${target%%#*}"
      [[ -n "$target" ]] || continue
      if [[ "$target" == /* ]]; then
        resolved="$REPO_ROOT$target"
      else
        resolved="$dir/$target"
      fi
      if command -v realpath >/dev/null 2>&1; then
        resolved="$(realpath -m "$resolved" 2>/dev/null || printf '%s' "$resolved")"
      fi
      if [[ ! -e "$resolved" ]]; then
        report WARN "$(rel "$f"):$lineno" "dangling link to '$target'"
      fi
    done < <(grep -noE '\]\([^)]+\.md[^)]*\)' "$f" 2>/dev/null | sed -E 's/\]\(/:/; s/\)$//' | sed -E 's/^([0-9]+):[^:]*:?/\1:/' || true)
  done
  return 0
}

# ── Main ───────────────────────────────────────────────────────────────────────

detect_yq
discover_machines

if [[ ${#MACHINE_DIRS[@]} -eq 0 ]]; then
  echo "Error: no machine folders found under $(rel "$MACHINES_DIR")" >&2
  exit 2
fi

TARGETS=()
if [[ -n "$ONLY_MACHINE" ]]; then
  if [[ -z "${NAME_TO_DIR[$ONLY_MACHINE]:-}" ]]; then
    echo "Error: machine '$ONLY_MACHINE' not found under $(rel "$MACHINES_DIR")" >&2
    exit 2
  fi
  TARGETS=("${NAME_TO_DIR[$ONLY_MACHINE]}")
else
  TARGETS=("${MACHINE_DIRS[@]}")
fi

if [[ $QUIET -eq 0 ]]; then
  echo "Tuneladora validator — ${#TARGETS[@]} machine(s), yq: $([[ $YQ_OK -eq 1 ]] && echo yes || echo 'no (awk fallback)')"
  echo
fi

for MDIR in "${TARGETS[@]}"; do
  MNAME="$(basename "$MDIR")"
  [[ $QUIET -eq 0 ]] && echo "── $MNAME ($(rel "$MDIR"))"
  check_files "$MDIR" "$MNAME" || true
  check_state_frontmatter "$MDIR" "$MNAME"
  check_references "$MDIR" "$MNAME"
  check_task_log "$MDIR"
  check_l1_budget "$MDIR"
  [[ $QUIET -eq 0 ]] && echo
done

# Repo-wide checks (scoped to the machine folder when --machine is used).
SCAN_ROOT="$MACHINES_DIR"
REF_ROOT="$REPO_ROOT"
if [[ -n "$ONLY_MACHINE" ]]; then
  SCAN_ROOT="${NAME_TO_DIR[$ONLY_MACHINE]}"
  REF_ROOT="${NAME_TO_DIR[$ONLY_MACHINE]}"
fi

[[ $QUIET -eq 0 ]] && echo "── secrets"
check_secrets "$SCAN_ROOT"
[[ $QUIET -eq 0 ]] && echo
[[ $QUIET -eq 0 ]] && echo "── documentation references"
check_dangling_refs "$REF_ROOT"
[[ $QUIET -eq 0 ]] && echo

printf 'Summary: %d PASS, %d WARN, %d FAIL (%d machine(s) checked)\n' \
  "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT" "${#TARGETS[@]}"

[[ $FAIL_COUNT -eq 0 ]] || exit 1
exit 0
