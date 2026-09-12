#!/usr/bin/env bash
#
# fleet_index.sh — regenerate machines/00_FLEET.md from every machine's STATE.md.
#
# The single Obsidian vault (SPEC.md §7) makes a fleet-wide view possible: links
# can cross machine folders, so one generated note can carry the whole topology.
# This tool writes that note. It is GENERATED, never hand-maintained — a
# hand-maintained fleet list is exactly the drift the audit found in the old
# `children:` field (SPEC.md §1.2).
#
# What it emits:
#   1. Inventory table          — one row per machine, wikilinked to its STATE.md.
#   2. Dependency graph         — every depends_on / provides_to edge, with detail.
#   3. Reciprocity check        — edges with no matching edge on the other end.
#   4. Posture summary          — backups / auto_updates not configured, staleness.
#   5. Open issues digest       — the `## Open Issues` bullets of every STATE.md.
#
# Usage:
#   tools/fleet_index.sh [--output <file>] [--stdout] [--quiet]
#
# Exit codes: 0 written (or printed), 2 tool error.
#
# The frontmatter parsing is the awk approach already proven in tools/validate.sh
# and tools/reconcile.sh — no yq, no external dependency.

set -euo pipefail

export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
MACHINES_DIR="$REPO_ROOT/machines"
OUTPUT="$MACHINES_DIR/00_FLEET.md"
TO_STDOUT=0
QUIET=0

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

usage() {
  cat <<'EOF'
Usage: tools/fleet_index.sh [options]

  --output <file>   Write somewhere other than machines/00_FLEET.md.
  --stdout          Print to stdout instead of writing a file.
  --quiet           Suppress the closing summary line.
  -h, --help        This help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) [[ $# -ge 2 ]] || die "--output needs a value"; OUTPUT="$2"; shift 2 ;;
    --stdout) TO_STDOUT=1; shift ;;
    --quiet)  QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ -d "$MACHINES_DIR" ]] || die "machines/ directory not found at $MACHINES_DIR"

# ---------------------------------------------------------------------------
# Frontmatter helpers (same shapes as validate.sh / reconcile.sh)
# ---------------------------------------------------------------------------

# fm_block <file> -> the YAML frontmatter, without the --- fences.
fm_block() {
  awk '
    NR == 1 && $0 == "---" { inside = 1; next }
    inside && $0 == "---" { exit }
    inside { print }
  ' "$1"
}

# fm_get <file> <key> -> scalar value of a top-level key, quotes/space trimmed.
fm_get() {
  fm_block "$1" | awk -v k="$2" '
    {
      if (substr($0, 1, 1) == " " || substr($0, 1, 1) == "\t") next
      i = index($0, ":")
      if (i == 0) next
      if (substr($0, 1, i - 1) != k) next
      v = substr($0, i + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      gsub(/^"|"$/, "", v)
      gsub(/^'\''|'\''$/, "", v)
      print v
      exit
    }
  '
}

# fm_sub <file> <key> <subkey> -> scalar value nested one level under a mapping key.
fm_sub() {
  fm_block "$1" | awk -v k="$2" -v sk="$3" '
    {
      if (substr($0, 1, 1) != " " && substr($0, 1, 1) != "\t") {
        i = index($0, ":")
        inblk = (i > 0 && substr($0, 1, i - 1) == k) ? 1 : 0
        next
      }
      if (!inblk) next
      line = $0
      sub(/^[ \t]+/, "", line)
      i = index(line, ":")
      if (i == 0) next
      if (substr(line, 1, i - 1) != sk) next
      v = substr(line, i + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      gsub(/^"|"$/, "", v)
      gsub(/^'\''|'\''$/, "", v)
      print v
      exit
    }
  '
}

# fm_items <file> <key> -> one edge per line: machine <TAB> role <TAB> detail
#
# Same list shapes reconcile.sh's fm_list handles, but the whole mapping is kept
# rather than just `machine:` — the role and the detail ARE the payload here:
#   k: []                       -> nothing
#   k: [a, b]                   -> a/b with empty role+detail
#   k:\n  - a                   -> plain scalar item
#   k:\n  - machine: a
#         role: r
#         detail: "d"           -> the mapping shape SPEC.md §1.1 specifies
fm_items() {
  fm_block "$1" | awk -v k="$2" '
    function unquote(v) {
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (v ~ /^".*"$/) { v = substr(v, 2, length(v) - 2); gsub(/\\"/, "\"", v) }
      else if (v ~ /^'\''.*'\''$/) { v = substr(v, 2, length(v) - 2) }
      return v
    }
    function flush() {
      if (m != "") printf "%s\t%s\t%s\n", m, r, d
      m = ""; r = ""; d = ""
    }
    BEGIN { inlist = 0; m = ""; r = ""; d = "" }
    {
      line = $0
      # A non-indented line either opens the key or closes the list.
      if (substr(line, 1, 1) != " " && substr(line, 1, 1) != "\t") {
        if (inlist) { flush(); exit }
        i = index(line, ":")
        if (i > 0 && substr(line, 1, i - 1) == k) {
          v = substr(line, i + 1)
          gsub(/^[ \t]+|[ \t]+$/, "", v)
          if (v ~ /^\[.*\]$/) {
            gsub(/^\[|\]$/, "", v)
            n = split(v, parts, ",")
            for (j = 1; j <= n; j++) {
              p = unquote(parts[j])
              if (p != "" && p != "null") printf "%s\t\t\n", p
            }
            exit
          }
          if (v == "" || v == "null") { inlist = (v == "") ; next }
          printf "%s\t\t\n", unquote(v)
          exit
        }
        next
      }
      if (!inlist) next

      if (line ~ /^[ \t]*-[ \t]*/) {
        flush()
        v = line
        sub(/^[ \t]*-[ \t]*/, "", v)
        i = index(v, ":")
        if (i == 0) { m = unquote(v); next }
        key = substr(v, 1, i - 1)
        gsub(/^[ \t]+|[ \t]+$/, "", key)
        val = unquote(substr(v, i + 1))
        if (key == "machine" || key == "name") m = val
        else if (key == "role") r = val
        else if (key == "detail") d = val
        next
      }

      # An indented line without a dash is an attribute of the current item.
      v = line
      sub(/^[ \t]+/, "", v)
      i = index(v, ":")
      if (i == 0) next
      key = substr(v, 1, i - 1)
      val = unquote(substr(v, i + 1))
      if (key == "machine" || key == "name") m = val
      else if (key == "role") r = val
      else if (key == "detail") d = val
    }
    END { if (inlist) flush() }
  '
}

# Pull the bullets of the STATE.md `## Open Issues` section, one bullet per line.
# Continuation lines are folded into their bullet so the digest stays a flat list.
open_issues() {
  awk '
    /^## / { inblk = ($0 ~ /^##[ \t]+Open Issues[ \t]*$/) ? 1 : 0; if (!inblk && started) exit; if (inblk) started = 1; next }
    !inblk { next }
    {
      line = $0
      if (line ~ /^[ \t]*-[ \t]+/) {
        if (buf != "") print buf
        sub(/^[ \t]*-[ \t]+/, "", line)
        buf = line
        next
      }
      if (line ~ /^[ \t]*$/) { if (buf != "") { print buf; buf = "" } ; next }
      sub(/^[ \t]+/, "", line)
      if (buf != "") buf = buf " " line
      else buf = line
    }
    END { if (buf != "") print buf }
  ' "$1"
}

# Escape the markdown table cell separator.
cell() { printf '%s' "${1//|/\\|}"; }

# "" / null / unknown -> a dash, so empty cells read as deliberate.
dash() {
  case "${1:-}" in
    ""|null|Null|NULL|"~") printf '—' ;;
    *) printf '%s' "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

declare -a NAMES=()
declare -A REL=()          # name -> path relative to machines/
declare -A STATE=()        # name -> absolute STATE.md path

while IFS= read -r state; do
  [[ -n "$state" ]] || continue
  dir="$(dirname -- "$state")"
  rel="${dir#"$MACHINES_DIR"/}"
  name="$(fm_get "$state" machine)"
  [[ -n "$name" ]] || name="$(basename -- "$dir")"
  if [[ -n "${REL[$name]:-}" ]]; then
    die "duplicate machine name '$name' (${REL[$name]} and $rel)"
  fi
  NAMES+=("$name")
  REL["$name"]="$rel"
  STATE["$name"]="$state"
done < <(find "$MACHINES_DIR" -name '.git' -prune -o -name '.obsidian' -prune -o \
              -type f -name 'STATE.md' -print | sort)

(( ${#NAMES[@]} > 0 )) || die "no STATE.md found under $MACHINES_DIR"

# Order by folder path, so the listing reads as the tree: each parent is followed
# by its guests. Stable across runs, and independent of name capitalisation.
mapfile -t NAMES < <(
  for n in "${NAMES[@]}"; do printf '%s\t%s\n' "${REL[$n]}" "$n"; done | sort | cut -f2
)

# ---------------------------------------------------------------------------
# Edge collection
#
# EDGES lines: src <TAB> dst <TAB> role <TAB> detail <TAB> kind(dep|prov)
# HAVE keys:   "<kind>|<src>|<dst>|<role>"  -> 1
# PAIR keys:   "<kind>|<src>|<dst>"         -> space-separated roles
# ---------------------------------------------------------------------------

declare -a EDGES=()
declare -A HAVE=()
declare -A PAIR=()

for name in "${NAMES[@]}"; do
  for kind in dep prov; do
    key="depends_on"; [[ "$kind" == prov ]] && key="provides_to"
    while IFS=$'\t' read -r dst role detail; do
      [[ -n "${dst:-}" ]] || continue
      EDGES+=("$name"$'\t'"$dst"$'\t'"$role"$'\t'"$detail"$'\t'"$kind")
      HAVE["$kind|$name|$dst|$role"]=1
      PAIR["$kind|$name|$dst"]="${PAIR["$kind|$name|$dst"]:-} $role"
    done < <(fm_items "${STATE[$name]}" "$key")
  done
done

# link <machine> [<note>] -> a path-qualified wikilink (SPEC.md §7)
link() {
  local n="$1" note="${2:-STATE}"
  if [[ -n "${REL[$n]:-}" ]]; then
    printf '[[%s/%s|%s]]' "${REL[$n]}" "$note" "$n"
  else
    printf '`%s`' "$n"
  fi
}

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------

render() {
  local name

  cat <<EOF
# Fleet Index

<!-- GENERATED FILE — DO NOT HAND-EDIT -->

> **GENERATED — do not hand-edit.** Every line below is derived from the
> \`STATE.md\` frontmatter of each machine. Edit the machine's \`STATE.md\`, then
> re-run \`tools/fleet_index.sh\` to regenerate this file. Hand-edits are lost on
> the next run, and a hand-maintained fleet list is the drift \`SPEC.md §1.2\`
> exists to prevent.
>
> Vault root is \`machines/\` (\`SPEC.md §7\`); links are path-qualified.

## Inventory

| Machine | Type | Parent | IP | Status | OS | container_id |
|---------|------|--------|----|--------|----|--------------|
EOF

  for name in "${NAMES[@]}"; do
    local s="${STATE[$name]}" parent
    parent="$(fm_get "$s" parent)"
    printf '| %s | %s | %s | %s | %s | %s | %s |\n' \
      "$(link "$name")" \
      "$(cell "$(dash "$(fm_get "$s" type)")")" \
      "$( [[ -n "$parent" && "$parent" != "null" ]] && link "$parent" || printf '— (root)' )" \
      "$(cell "$(dash "$(fm_get "$s" ip)")")" \
      "$(cell "$(dash "$(fm_get "$s" status)")")" \
      "$(cell "$(dash "$(fm_get "$s" os)")")" \
      "$(cell "$(dash "$(fm_get "$s" container_id)")")"
  done

  cat <<'EOF'

## Dependencies

Service-level edges only (`SPEC.md §1.2`): what a machine needs from another to
function, and what it serves to another. Containment lives in the tree and in the
`Parent` column above, not here.

### Declared `depends_on`
EOF
  printf '\n'
  local found=0 e src dst role detail kind
  for e in ${EDGES[@]+"${EDGES[@]}"}; do
    IFS=$'\t' read -r src dst role detail kind <<< "$e"
    [[ "$kind" == dep ]] || continue
    found=1
    printf -- '- %s --(%s)--> %s\n' "$(link "$src")" "${role:-?}" "$(link "$dst")"
    [[ -n "$detail" ]] && printf -- '    - %s\n' "$detail"
  done
  (( found )) || printf -- '- none declared\n'

  printf '\n### Declared `provides_to`\n\n'
  found=0
  for e in ${EDGES[@]+"${EDGES[@]}"}; do
    IFS=$'\t' read -r src dst role detail kind <<< "$e"
    [[ "$kind" == prov ]] || continue
    found=1
    printf -- '- %s --(%s)--> %s\n' "$(link "$src")" "${role:-?}" "$(link "$dst")"
    [[ -n "$detail" ]] && printf -- '    - %s\n' "$detail"
  done
  (( found )) || printf -- '- none declared\n'

  cat <<'EOF'

## Reciprocity check

`SPEC.md §8.1.3`: a relationship is recorded on **both** ends. Every
`A depends_on B (role)` should have a matching `B provides_to A (role)`, and
every `provides_to` a matching `depends_on`. Unmatched edges are listed below —
each is either a missing entry on the other machine or a role the two ends
disagree about.

EOF

  # Pass 1 — which edges have an exact (machine + role) reciprocal?
  local rkind
  declare -A UNMATCHED=()
  for e in ${EDGES[@]+"${EDGES[@]}"}; do
    IFS=$'\t' read -r src dst role detail kind <<< "$e"
    rkind=prov; [[ "$kind" == prov ]] && rkind=dep
    [[ -n "${HAVE["$rkind|$dst|$src|$role"]:-}" ]] && continue
    UNMATCHED["$kind|$src|$dst|$role"]=1
  done

  # Pass 2 — report. An unmatched edge whose counterpart machine declares a
  # reverse edge that is ALSO unmatched is one relationship the two ends name
  # differently, not two missing entries; it is reported once, as a role
  # disagreement. Everything else is a genuinely missing entry.
  local missing=0 rolemismatch=0 cand r other reported
  declare -A SEEN_PAIR=()
  {
    for e in ${EDGES[@]+"${EDGES[@]}"}; do
      IFS=$'\t' read -r src dst role detail kind <<< "$e"
      [[ -n "${UNMATCHED["$kind|$src|$dst|$role"]:-}" ]] || continue
      rkind=prov; [[ "$kind" == prov ]] && rkind=dep

      cand=""
      for r in ${PAIR["$rkind|$dst|$src"]:-}; do
        [[ -n "${UNMATCHED["$rkind|$dst|$src|$r"]:-}" ]] && cand="${cand:+$cand, }\`$r\`"
      done

      if [[ -n "$cand" ]]; then
        # One disagreement, two ends: key on the unordered machine pair.
        if [[ "$src" < "$dst" ]]; then reported="$src|$dst"; else reported="$dst|$src"; fi
        [[ -n "${SEEN_PAIR[$reported]:-}" ]] && continue
        SEEN_PAIR["$reported"]=1
        rolemismatch=$((rolemismatch + 1))
        printf -- '- **role disagreement** — %s declares `%s` --(`%s`)--> %s, while %s names the same relationship %s. One relationship, two names: pick one role and write it on both ends.\n' \
          "$(link "$src")" "$( [[ "$kind" == dep ]] && printf depends_on || printf provides_to )" \
          "$role" "$(link "$dst")" "$(link "$dst")" "$cand"
      else
        missing=$((missing + 1))
        printf -- '- **missing reciprocal** — %s declares `%s` --(`%s`)--> %s, but %s has no `%s` entry for %s with that role.\n' \
          "$(link "$src")" "$( [[ "$kind" == dep ]] && printf depends_on || printf provides_to )" \
          "$role" "$(link "$dst")" "$(link "$dst")" \
          "$( [[ "$kind" == dep ]] && printf provides_to || printf depends_on )" "$(link "$src")"
      fi
    done
    if (( missing == 0 && rolemismatch == 0 )); then
      printf -- '- All %d declared edges reciprocate. No unmatched edges.\n' "${#EDGES[@]}"
    fi
    printf '\n**%d missing reciprocal(s)** and **%d role disagreement(s)** across %d declared edge(s).\n' \
      "$missing" "$rolemismatch" "${#EDGES[@]}"
  }

  cat <<'EOF'

## Posture

### `backups.configured: false`

EOF
  local n found_b=0
  for name in "${NAMES[@]}"; do
    if [[ "$(fm_sub "${STATE[$name]}" backups configured)" == "false" ]]; then
      found_b=1
      printf -- '- %s\n' "$(link "$name")"
    fi
  done
  (( found_b )) || printf -- '- none — every machine declares a configured backup\n'

  printf '\n### `auto_updates.configured: false`\n\n'
  local found_u=0 tool
  for name in "${NAMES[@]}"; do
    if [[ "$(fm_sub "${STATE[$name]}" auto_updates configured)" == "false" ]]; then
      found_u=1
      tool="$(fm_sub "${STATE[$name]}" auto_updates tool)"
      case "$tool" in
        ""|null|Null|NULL|"~") printf -- '- %s\n' "$(link "$name")" ;;
        *) printf -- '- %s — %s\n' "$(link "$name")" "$tool" ;;
      esac
    fi
  done
  (( found_u )) || printf -- '- none — every machine declares configured auto-updates\n'

  cat <<'EOF'

### `last_reconciled`, oldest first

`SPEC.md §1.2`: this is the date the frontmatter was last checked against the
live machine, not the date the file was last edited. The top of this list is
where the documentation is most likely to have drifted.

| Machine | last_reconciled | backups.last_verified |
|---------|-----------------|-----------------------|
EOF
  for name in "${NAMES[@]}"; do
    printf '%s\t%s\t%s\n' \
      "$(fm_get "${STATE[$name]}" last_reconciled)" \
      "$name" \
      "$(fm_sub "${STATE[$name]}" backups last_verified)"
  done | sort | while IFS=$'\t' read -r lr n lv; do
    printf '| %s | %s | %s |\n' "$(link "$n")" "$(dash "$lr")" "$(dash "$lv")"
  done

  cat <<'EOF'

## Open issues

Every `## Open Issues` bullet from every `STATE.md`, in one place. Close an issue
in the machine's own `STATE.md` (`SPEC.md §1.3`) and re-run this tool; the history
stays in the task log.

EOF
  local total=0
  for name in "${NAMES[@]}"; do
    local issues count
    issues="$(open_issues "${STATE[$name]}")"
    count="$(printf '%s' "$issues" | grep -c . || true)"
    printf '### %s\n\n' "$(link "$name")"
    if [[ -z "${issues//[[:space:]]/}" || "$issues" == "none" ]]; then
      printf -- '- none\n\n'
      continue
    fi
    total=$((total + count))
    printf '%s\n' "$issues" | sed 's/^/- /'
    printf '\n'
  done
  printf -- '**%d open issue(s) across %d machine(s).**\n' "$total" "${#NAMES[@]}"
}

if (( TO_STDOUT )); then
  render
  exit 0
fi

# Write beside the target (same filesystem, so the move is atomic) and give the
# result the repository's normal file mode rather than mktemp's 0600.
tmp="$(mktemp "$(dirname -- "$OUTPUT")/.fleet_index.XXXXXX")"
trap 'rm -f -- "$tmp"' EXIT
render > "$tmp"
chmod 644 -- "$tmp"
mv -- "$tmp" "$OUTPUT"
trap - EXIT

(( QUIET )) || printf 'fleet_index.sh — %d machine(s), %d edge(s) -> %s\n' \
  "${#NAMES[@]}" "${#EDGES[@]}" "${OUTPUT#"$REPO_ROOT"/}"
