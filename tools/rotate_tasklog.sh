#!/usr/bin/env bash
#
# rotate_tasklog.sh — bound the size of vault/03_TASK_LOG.md without ever losing history.
#
# Keeps the N most recent entries (by the date in the entry heading) in
# vault/03_TASK_LOG.md and MOVES the older ones, byte-for-byte, into
# vault/archive/<YYYY>-Q<N>.md, grouped by the quarter of the entry date.
#
# Guarantees:
#   * Entries are moved verbatim. Never reworded, reformatted, translated or dropped.
#     "Append-only" still holds: what changes is the file boundary, not the content.
#   * Byte integrity: total bytes of entry content before == after (log + archives).
#     If the check fails the whole machine is restored from backup and the tool aborts.
#   * Idempotent: a second run over an already rotated vault changes nothing.
#
# Usage:
#   tools/rotate_tasklog.sh [--dry-run] [--machine <name>] [--keep <n>]
#
# Exit codes: 0 success (or nothing to do), 1 warnings only, 2 tool error / integrity failure.

set -euo pipefail

# Byte semantics everywhere (awk length(), sort order, regex classes).
export LC_ALL=C

# ---------------------------------------------------------------------------
# Markers. These delimit tool-managed regions so re-runs are byte-stable.
# ---------------------------------------------------------------------------
NOTE_BEGIN='<!-- TASKLOG-ROTATION-NOTE:BEGIN -->'
NOTE_END='<!-- TASKLOG-ROTATION-NOTE:END -->'
INDEX_BEGIN='<!-- TASKLOG-ARCHIVE-INDEX:BEGIN -->'
INDEX_END='<!-- TASKLOG-ARCHIVE-INDEX:END -->'
LEGACY_NOTE='> Append-only. Never delete or rewrite past entries.'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
MACHINES_DIR="$REPO_ROOT/machines"

DRY_RUN=0
KEEP=5
ONLY_MACHINE=""
WARNINGS=0

TMPDIR_ROOT=""
# shellcheck disable=SC2329  # invoked indirectly by the EXIT trap below.
cleanup() { [[ -n "$TMPDIR_ROOT" && -d "$TMPDIR_ROOT" ]] && rm -rf -- "$TMPDIR_ROOT"; }
trap cleanup EXIT

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
warn() { printf 'WARN  %s\n' "$*"; WARNINGS=1; }
info() { printf '%s\n' "$*"; }

usage() {
  cat <<'EOF'
Usage: tools/rotate_tasklog.sh [options]

  --dry-run            Show what would change; write nothing. (default: OFF)
  --machine <name>     Rotate only this machine (folder name, e.g. hef-proxmox).
  --keep <n>           Number of most recent entries to keep in place. (default: 5)
  -h, --help           This help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --machine) [[ $# -ge 2 ]] || die "--machine needs a value"; ONLY_MACHINE="$2"; shift 2 ;;
    --keep)    [[ $# -ge 2 ]] || die "--keep needs a value"; KEEP="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ "$KEEP" =~ ^[0-9]+$ ]] || die "--keep must be a non-negative integer, got '$KEEP'"
[[ -d "$MACHINES_DIR" ]] || die "machines/ directory not found at $MACHINES_DIR"

TMPDIR_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rotate_tasklog.XXXXXX")"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# quarter_of <YYYY-MM-DD> -> <YYYY>-Q<N>
quarter_of() {
  local d="$1" y m q
  y="${d%%-*}"
  m="${d:5:2}"
  case "$m" in
    01|02|03) q=1 ;;
    04|05|06) q=2 ;;
    07|08|09) q=3 ;;
    10|11|12) q=4 ;;
    *) return 1 ;;
  esac
  printf '%s-Q%s' "$y" "$q"
}

quarter_range() {
  local q="$1" y n
  y="${q%%-Q*}"
  n="${q##*-Q}"
  case "$n" in
    1) printf '%s-01-01 … %s-03-31' "$y" "$y" ;;
    2) printf '%s-04-01 … %s-06-30' "$y" "$y" ;;
    3) printf '%s-07-01 … %s-09-30' "$y" "$y" ;;
    4) printf '%s-10-01 … %s-12-31' "$y" "$y" ;;
  esac
}

# Strip the tool-managed archive index from a task log.
# Content AFTER the closing marker is kept: an agent that appends a new entry at
# the very bottom of the file must not lose it. Only if the closing marker is
# missing (truncated file) do we cut to EOF.
strip_index() {
  local f="$1"
  if grep -Fq -- "$INDEX_END" "$f"; then
    awk -v b="$INDEX_BEGIN" -v e="$INDEX_END" '
      index($0, b) { skip = 1; next }
      index($0, e) { skip = 0; next }
      skip { next }
      { print }
    ' "$f"
  else
    awk -v b="$INDEX_BEGIN" '
      index($0, b) { exit }
      { print }
    ' "$f"
  fi
}

# Index the entries of a markdown log.
# Emits: idx <TAB> start_line <TAB> end_line <TAB> date|- <TAB> heading
# and a final line: HEADER_END <TAB> <last line of the header block>
index_entries() {
  awk '
    BEGIN { fence = 0; n = 0 }
    {
      if (substr($0, 1, 3) == "```") fence = 1 - fence
      if (!fence && substr($0, 1, 3) == "## ") { n++; hl[n] = NR; hd[n] = $0 }
      last = NR
    }
    END {
      for (i = 1; i <= n; i++) {
        e = (i < n) ? hl[i+1] - 1 : last
        d = "-"
        # Accept "## 2026-08-04 ..." and "## [2026-08-04] ..."
        if (match(hd[i], /^## \[?[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
          s = substr(hd[i], RSTART, RLENGTH)
          if (match(s, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/))
            d = substr(s, RSTART, RLENGTH)
        }
        printf "%d\t%d\t%d\t%s\t%s\n", i, hl[i], e, d, hd[i]
      }
      printf "HEADER_END\t%d\n", (n > 0 ? hl[1] - 1 : last)
    }
  ' "$1"
}

# Bytes of the entry region (first "## " heading .. EOF) of a file. 0 if no entries.
entry_region_bytes() {
  local f="$1" first
  [[ -s "$f" ]] || { printf '0'; return; }
  first="$(index_entries "$f" | awk -F'\t' '$1 != "HEADER_END" { print $2; exit }')"
  if [[ -z "$first" ]]; then printf '0'; return; fi
  sed -n "${first},\$p" "$f" | wc -c | tr -d ' '
}

# ---------------------------------------------------------------------------
# Build the header block of 03_TASK_LOG.md with the rotation note applied.
# Everything the human wrote is preserved; only the tool-managed note block and
# the superseded one-line legacy note are touched.
# ---------------------------------------------------------------------------
build_header() {
  local src_header="$1" keep="$2" out="$3"

  # Drop any previous tool-managed note block and the legacy one-liner.
  awk -v b="$NOTE_BEGIN" -v e="$NOTE_END" -v legacy="$LEGACY_NOTE" '
    index($0, b) { skip = 1; next }
    index($0, e) { skip = 0; next }
    skip { next }
    $0 == legacy { next }
    { print }
  ' "$src_header" > "$out.stripped"

  # Re-insert the note directly after the title line (first line starting with "# ").
  awk -v b="$NOTE_BEGIN" -v e="$NOTE_END" -v keep="$keep" '
    BEGIN { done = 0 }
    {
      print
      if (!done && substr($0, 1, 2) == "# ") {
        print ""
        print b
        print "> **Append-only.** Never delete, reword or rewrite a past entry."
        print "> This file is rotated by `tools/rotate_tasklog.sh`: the " keep " most recent entries"
        print "> stay here, older ones are moved **verbatim** to `archive/<YYYY>-Q<N>.md`."
        print "> The archive index at the end of this file says which quarter to grep."
        print e
        done = 1
      }
    }
  ' "$out.stripped" > "$out.noted"

  # Collapse runs of blank lines introduced by the strip/insert, and make sure the
  # header ends with exactly one blank line before the first entry.
  awk '
    { lines[NR] = $0 }
    END {
      n = NR
      while (n > 0 && lines[n] ~ /^[ \t]*$/) n--
      prev_blank = 0
      for (i = 1; i <= n; i++) {
        blank = (lines[i] ~ /^[ \t]*$/)
        if (blank && prev_blank) continue
        print lines[i]
        prev_blank = blank
      }
      print ""
    }
  ' "$out.noted" > "$out"

  rm -f -- "$out.stripped" "$out.noted"
}

# ---------------------------------------------------------------------------
# Build an archive file header (regenerated on every run; not part of the
# byte-integrity accounting, which covers entry content only).
# ---------------------------------------------------------------------------
build_archive_header() {
  local machine="$1" quarter="$2" count="$3" first="$4" last="$5"
  cat <<EOF
# $machine — Task Log Archive — $quarter

> Archived entries from [[$machine/vault/03_TASK_LOG]], moved **verbatim** by
> \`tools/rotate_tasklog.sh\`. Nothing here was reworded, reformatted or translated.
> Quarter window: $(quarter_range "$quarter"). Entries in this file: $count ($first → $last).
> Append-only: never edit or delete. Original ordering preserved.

EOF
}

# ---------------------------------------------------------------------------
# Rotate one machine.
# ---------------------------------------------------------------------------
rotate_one() {
  local log="$1"
  local vault_dir machine_dir machine archive_dir
  vault_dir="$(dirname -- "$log")"
  machine_dir="$(dirname -- "$vault_dir")"
  machine="$(basename -- "$machine_dir")"
  archive_dir="$vault_dir/archive"

  local wd="$TMPDIR_ROOT/$machine"
  rm -rf -- "$wd"; mkdir -p "$wd"

  # ---- 1. Working copy with the tool-managed archive index removed -------------
  local work="$wd/work.md"
  strip_index "$log" > "$work"

  # ---- 2. Index entries -------------------------------------------------------
  local idx="$wd/index.tsv"
  index_entries "$work" > "$idx"

  local header_end
  header_end="$(awk -F'\t' '$1 == "HEADER_END" { print $2 }' "$idx")"

  local -a e_start=() e_end=() e_date=() e_head=()
  local n=0
  while IFS=$'\t' read -r i s e d h; do
    [[ "$i" == "HEADER_END" ]] && continue
    n=$((n + 1))
    e_start[n]="$s"; e_end[n]="$e"; e_date[n]="$d"; e_head[n]="$h"
  done < "$idx"

  local before_entries
  before_entries="$(grep -c '^## ' "$log" || true)"

  if (( n == 0 )); then
    info "SKIP  $machine — no entries found in ${log#"$REPO_ROOT"/}"
    return 0
  fi

  # ---- 3. Decide what stays and what moves ------------------------------------
  # "Most recent" is decided by the date in the heading, not by file position:
  # these logs are appended to out of order. Ties break on file position (later
  # position wins, which is the append-only convention).
  local keepset="$wd/keep.txt" dated="$wd/dated.tsv"
  : > "$keepset"
  : > "$dated"
  local i
  for ((i = 1; i <= n; i++)); do
    if [[ "${e_date[i]}" == "-" ]]; then
      # Unparseable date: never guess. Leave it in place and warn.
      warn "$machine — entry #$i has no parseable date, left in place: ${e_head[i]}"
      printf '%d\n' "$i" >> "$keepset"
    else
      printf '%s\t%d\n' "${e_date[i]}" "$i" >> "$dated"
    fi
  done
  sort -t$'\t' -k1,1r -k2,2nr "$dated" | head -n "$KEEP" | cut -f2 >> "$keepset"

  local -A KEEPMAP=()
  while read -r i; do [[ -n "$i" ]] && KEEPMAP["$i"]=1; done < "$keepset"

  local -a move_idx=()
  for ((i = 1; i <= n; i++)); do
    [[ -n "${KEEPMAP[$i]:-}" ]] || move_idx+=("$i")
  done

  # Guard against moving an entry whose heading already exists in the target
  # archive (would duplicate history). Such an entry stays put and warns.
  local -a final_move=()
  local q target
  for i in "${move_idx[@]:-}"; do
    [[ -n "${i:-}" ]] || continue
    q="$(quarter_of "${e_date[i]}")" || { warn "$machine — bad date on entry #$i"; KEEPMAP["$i"]=1; continue; }
    target="$archive_dir/$q.md"
    if [[ -f "$target" ]] && grep -Fxq -- "${e_head[i]}" "$target"; then
      warn "$machine — entry already present in archive/$q.md, left in place: ${e_head[i]}"
      KEEPMAP["$i"]=1
      continue
    fi
    final_move+=("$i")
  done

  # ---- 4. Byte accounting: BEFORE --------------------------------------------
  local before_bytes after_bytes
  before_bytes="$(entry_region_bytes "$work")"
  local -a existing_archives=()
  if [[ -d "$archive_dir" ]]; then
    while IFS= read -r a; do existing_archives+=("$a"); done < <(find "$archive_dir" -maxdepth 1 -type f -name '*.md' | sort)
  fi
  local a b
  for a in "${existing_archives[@]:-}"; do
    [[ -n "${a:-}" ]] || continue
    b="$(entry_region_bytes "$a")"
    before_bytes=$((before_bytes + b))
  done

  # ---- 5. Compose the new log -------------------------------------------------
  local new_header="$wd/header.md"
  if (( header_end > 0 )); then
    sed -n "1,${header_end}p" "$work" > "$wd/src_header.md"
  else
    : > "$wd/src_header.md"
  fi
  build_header "$wd/src_header.md" "$KEEP" "$new_header"

  local new_body="$wd/body.md"
  : > "$new_body"
  for ((i = 1; i <= n; i++)); do
    if [[ -n "${KEEPMAP[$i]:-}" ]]; then
      sed -n "${e_start[i]},${e_end[i]}p" "$work" >> "$new_body"
    fi
  done

  # ---- 6. Compose the archives ------------------------------------------------
  # Group the moved entries by quarter, preserving original ordering.
  local -A Q_ENTRIES=()
  for i in "${final_move[@]:-}"; do
    [[ -n "${i:-}" ]] || continue
    q="$(quarter_of "${e_date[i]}")"
    Q_ENTRIES["$q"]="${Q_ENTRIES[$q]:-}$i "
  done

  local -a touched_quarters=()
  for q in "${!Q_ENTRIES[@]}"; do touched_quarters+=("$q"); done
  if ((${#touched_quarters[@]} > 1)); then
    mapfile -t touched_quarters < <(printf '%s\n' "${touched_quarters[@]}" | sort)
  fi

  # Planned archive bodies (existing entry region + newly appended entries).
  for q in "${touched_quarters[@]:-}"; do
    [[ -n "${q:-}" ]] || continue
    local qbody="$wd/arch-$q.body"
    : > "$qbody"
    if [[ -f "$archive_dir/$q.md" ]]; then
      local first_line
      first_line="$(index_entries "$archive_dir/$q.md" | awk -F'\t' '$1 != "HEADER_END" { print $2; exit }')"
      if [[ -n "$first_line" ]]; then
        sed -n "${first_line},\$p" "$archive_dir/$q.md" >> "$qbody"
      fi
    fi
    for i in ${Q_ENTRIES[$q]}; do
      sed -n "${e_start[i]},${e_end[i]}p" "$work" >> "$qbody"
    done
  done

  # ---- 7. Report --------------------------------------------------------------
  # Nothing to move is not an early exit: the log is still regenerated (note +
  # archive index) so the tool is self-healing, and written only if bytes differ.
  local moved=${#final_move[@]}
  local kept=$((n - moved))

  local plan="  $machine: $n entries -> keep $kept, move $moved"
  if (( moved > 0 )); then
    plan="$plan  [quarters: ${touched_quarters[*]}]"
  fi
  info "$plan"
  if (( DRY_RUN )); then
    for q in "${touched_quarters[@]:-}"; do
      [[ -n "${q:-}" ]] || continue
      local cnt=0
      for i in ${Q_ENTRIES[$q]}; do cnt=$((cnt + 1)); done
      info "      -> archive/$q.md  (+$cnt entries)"
    done
    for i in "${final_move[@]:-}"; do
      [[ -n "${i:-}" ]] || continue
      info "         move ${e_date[i]}  ${e_head[i]:0:96}"
    done
    return 0
  fi

  # ---- 8. Back up everything we are about to touch ----------------------------
  local bak="$wd/backup"
  mkdir -p "$bak"
  cp -p -- "$log" "$bak/03_TASK_LOG.md"
  # Always create the backup archive dir, even when empty: restore_backup uses it
  # as the authoritative "what existed before" list, so archives created by this
  # run are removed on rollback.
  mkdir -p "$bak/archive"
  if [[ -d "$archive_dir" ]]; then
    find "$archive_dir" -maxdepth 1 -type f -name '*.md' -exec cp -p -- {} "$bak/archive/" \;
  fi

  restore_backup() {
    local f base
    cp -p -- "$bak/03_TASK_LOG.md" "$log"
    # Remove archives created by this run, restore the ones that existed.
    if [[ -d "$archive_dir" ]]; then
      for f in "$archive_dir"/*.md; do
        [[ -e "$f" ]] || continue
        base="$(basename -- "$f")"
        [[ -f "$bak/archive/$base" ]] || rm -f -- "$f"
      done
      rmdir -- "$archive_dir" 2>/dev/null || true
    fi
    for f in "$bak"/archive/*.md; do
      [[ -e "$f" ]] || continue
      mkdir -p "$archive_dir"
      cp -p -- "$f" "$archive_dir/$(basename -- "$f")"
    done
  }

  # ---- 9. Write the archives --------------------------------------------------
  if ((${#touched_quarters[@]} > 0)); then
    mkdir -p "$archive_dir"
  fi
  for q in "${touched_quarters[@]:-}"; do
    [[ -n "${q:-}" ]] || continue
    local qbody="$wd/arch-$q.body"
    local cnt first_d last_d
    cnt="$(grep -c '^## ' "$qbody" || true)"
    first_d="$(index_entries "$qbody" | awk -F'\t' '$1 != "HEADER_END" { print $4 }' | grep -v '^-$' | sort | head -1)"
    last_d="$(index_entries "$qbody" | awk -F'\t' '$1 != "HEADER_END" { print $4 }' | grep -v '^-$' | sort | tail -1)"
    { build_archive_header "$machine" "$q" "$cnt" "${first_d:-?}" "${last_d:-?}"; cat "$qbody"; } > "$wd/arch-$q.md"
    cp -- "$wd/arch-$q.md" "$archive_dir/$q.md"
  done

  # ---- 10. Write the log with a fresh archive index ---------------------------
  local index_block="$wd/index_block.md"
  # NOTE: the block starts with the marker line and nothing before it. Any byte
  # emitted before the marker would fall inside the last kept entry's region and
  # break the byte-integrity check.
  {
    printf '%s\n' "$INDEX_BEGIN"
    printf -- '\n---\n\n'
    printf '### Archived entries\n\n'
    if [[ -d "$archive_dir" ]] && compgen -G "$archive_dir/*.md" > /dev/null; then
      # shellcheck disable=SC2016  # literal backticks for markdown code spans.
      printf 'Older entries were moved **verbatim** to `archive/`. Grep the quarter you need — no\n'
      printf 'need to list the directory.\n\n'
      printf '| Archive | Entries | Date range |\n'
      printf '|---------|---------|------------|\n'
      local f qname cnt lo hi
      for f in "$archive_dir"/*.md; do
        [[ -e "$f" ]] || continue
        qname="$(basename -- "$f" .md)"
        cnt="$(grep -c '^## ' "$f" || true)"
        lo="$(index_entries "$f" | awk -F'\t' '$1 != "HEADER_END" { print $4 }' | grep -v '^-$' | sort | head -1)"
        hi="$(index_entries "$f" | awk -F'\t' '$1 != "HEADER_END" { print $4 }' | grep -v '^-$' | sort | tail -1)"
        printf '| [[%s/vault/archive/%s]] | %s | %s → %s |\n' "$machine" "$qname" "$cnt" "${lo:-?}" "${hi:-?}"
      done
      printf '\n'
      # shellcheck disable=SC2016  # literal backticks for markdown code spans.
      printf 'Example: `grep -n "2026-05" %s/vault/archive/*.md`\n' "$machine"
      printf '\n'
      printf 'New entries may be appended above or below this block — the rotator handles both.\n'
    else
      printf 'No archived entries yet.\n'
    fi
    printf '%s\n' "$INDEX_END"
  } > "$index_block"

  local candidate="$wd/new_log.md"
  cat "$new_header" "$new_body" "$index_block" > "$candidate"

  if cmp -s "$candidate" "$log" && (( moved == 0 )); then
    info "      already rotated, no changes"
    return 0
  fi

  cp -- "$candidate" "$log"

  # ---- 11. Byte integrity -----------------------------------------------------
  # Measure against the index-stripped log so the archive index is excluded.
  strip_index "$log" > "$wd/after_work.md"
  after_bytes="$(entry_region_bytes "$wd/after_work.md")"
  if [[ -d "$archive_dir" ]]; then
    for a in "$archive_dir"/*.md; do
      [[ -e "$a" ]] || continue
      b="$(entry_region_bytes "$a")"
      after_bytes=$((after_bytes + b))
    done
  fi

  if [[ "$before_bytes" != "$after_bytes" ]]; then
    restore_backup
    die "$machine — BYTE INTEGRITY CHECK FAILED (before=$before_bytes after=$after_bytes). Restored from backup, nothing changed."
  fi

  local after_entries
  after_entries="$(grep -c '^## ' "$log" || true)"
  info "      OK  entries $before_entries -> $after_entries  |  bytes $before_bytes == $after_bytes (integrity OK)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
mapfile -t LOGS < <(find "$MACHINES_DIR" -name '.git' -prune -o -type f -path '*/vault/03_TASK_LOG.md' -print | sort)

(( ${#LOGS[@]} > 0 )) || die "no vault/03_TASK_LOG.md files found under $MACHINES_DIR"

if (( DRY_RUN )); then
  info "rotate_tasklog.sh — DRY RUN (keep=$KEEP) — nothing will be written"
else
  info "rotate_tasklog.sh — keep=$KEEP"
fi

FOUND=0
for log in "${LOGS[@]}"; do
  vd="$(dirname -- "$log")"
  md="$(dirname -- "$vd")"
  name="$(basename -- "$md")"
  if [[ -n "$ONLY_MACHINE" && "$name" != "$ONLY_MACHINE" ]]; then
    continue
  fi
  FOUND=1
  rotate_one "$log"
done

if [[ -n "$ONLY_MACHINE" && $FOUND -eq 0 ]]; then
  die "no machine named '$ONLY_MACHINE' with a vault/03_TASK_LOG.md"
fi

exit "$WARNINGS"
