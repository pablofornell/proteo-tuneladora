#!/usr/bin/env bash
#
# reconcile.sh — documentation-vs-reality drift detection for the machine vault.
#
# Turns the manual annual audit into something a weekly cron can run. It compares
# what STATE.md / vault/08_CONTAINERS.md claim against what the machines actually
# report over SSH, and prints one line per discrepancy.
#
# READ-ONLY BY DEFAULT. It NEVER writes to a remote machine: it only runs
# discovery commands over SSH. The only local write it can ever do is --write,
# which touches nothing but `last_reconciled:` and `status:` in STATE.md.
#
# What it checks:
#   * STATE.md ip / status / os / parent / type against the live host and the
#     directory tree, plus enum validity and depends_on/provides_to resolution.
#   * vault/08_CONTAINERS.md against the hypervisor's pct/qm list and against
#     the child machine folders on disk (undocumented guests, orphan folders).
#   * Root filesystem usage against a threshold, and the systemd units named in
#     STATE.md's `## Services` table.
#   * TOOLS/ against the deployed copies. A repo TOOLS/ copy is NOT evidence of
#     what is deployed: these are snapshots that nothing keeps in sync, and they
#     drift silently in both directions. When they differ the tool says so and
#     stops there — which copy is authoritative is a human judgement, and it is
#     often the DEPLOYED one that is correct.
#
# Usage:
#   tools/reconcile.sh [--machine <name>] [--offline] [--json] [--write]
#
# Exit codes:
#   0  no drift
#   1  drift and/or threshold alerts found
#   2  tool error

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
MACHINES_DIR="$REPO_ROOT/machines"

SSH_OPTS=(-o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR)
DISK_ALERT_PCT=85
TODAY="$(date +%F)"

ONLY_MACHINE=""
OFFLINE=0
JSON=0
DO_WRITE=0

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

usage() {
  cat <<'EOF'
Usage: tools/reconcile.sh [options]

  --machine <name>   Reconcile only this machine (folder name).
  --offline          Skip all SSH. Vault-internal consistency only (no live
                     checks, so no TOOLS/ deployment comparison):
                     directory tree vs STATE.md parent/type, enum validity,
                     depends_on/provides_to resolution, IP collisions,
                     parent 08_CONTAINERS.md vs child folders.
  --json             Machine-readable output (for a cron job or a hook).
  --write            Update ONLY `last_reconciled:` and `status:` in STATE.md,
                     and only for machines whose sole finding is a status drift.
                     Everything else stays a human/agent decision.
  -h, --help         This help.

Exit: 0 clean, 1 drift/alerts, 2 tool error.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --machine) [[ $# -ge 2 ]] || die "--machine needs a value"; ONLY_MACHINE="$2"; shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    --json)    JSON=1; shift ;;
    --write)   DO_WRITE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ -d "$MACHINES_DIR" ]] || die "machines/ directory not found at $MACHINES_DIR"
command -v awk >/dev/null 2>&1 || die "awk is required"
if (( ! OFFLINE )); then
  command -v ssh >/dev/null 2>&1 || die "ssh is required (or use --offline)"
fi

# ---------------------------------------------------------------------------
# Findings
# ---------------------------------------------------------------------------
F_SEV=(); F_MACHINE=(); F_FIELD=(); F_DOC=(); F_ACT=(); F_NOTE=()
DRIFT_COUNT=0
ALERT_COUNT=0

# add_finding <SEV> <machine> <field> <documented> <actual> <note>
add_finding() {
  F_SEV+=("$1"); F_MACHINE+=("$2"); F_FIELD+=("$3"); F_DOC+=("$4"); F_ACT+=("$5"); F_NOTE+=("${6:-}")
  case "$1" in
    DRIFT) DRIFT_COUNT=$((DRIFT_COUNT + 1)) ;;
    ALERT) ALERT_COUNT=$((ALERT_COUNT + 1)) ;;
  esac
}

# Findings that are not "pure status drift" block --write for that machine.
declare -A BLOCKING_FINDINGS=()
note_blocking() {
  local sev="$1" machine="$2" field="$3"
  case "$sev" in
    DRIFT|ALERT) ;;
    *) return 0 ;;
  esac
  [[ "$field" == "status" ]] && return 0
  BLOCKING_FINDINGS["$machine"]=1
}

report() {
  add_finding "$@"
  note_blocking "$1" "$2" "$3"
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr -d '\r' | awk 'NR>1{printf "\\n"} {printf "%s", $0}'
}

# ---------------------------------------------------------------------------
# STATE.md parsing
# ---------------------------------------------------------------------------

# Print the YAML frontmatter block of a file (without the --- fences).
fm_block() {
  awk '
    NR == 1 && $0 == "---" { inside = 1; next }
    inside && $0 == "---" { exit }
    inside { print }
  ' "$1"
}

# fm_get <state.md> <key>  -> scalar value, quotes and whitespace trimmed.
fm_get() {
  fm_block "$1" | awk -v k="$2" '
    {
      if (substr($0, 1, 1) == " " || substr($0, 1, 1) == "\t") next
      i = index($0, ":")
      if (i == 0) next
      key = substr($0, 1, i - 1)
      if (key != k) next
      v = substr($0, i + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      gsub(/^"|"$/, "", v)
      gsub(/^'\''|'\''$/, "", v)
      print v
      exit
    }
  '
}

# fm_has_key <state.md> <key> -> 0 if the top-level key exists
fm_has_key() {
  fm_block "$1" | grep -qE "^$2:"
}

# fm_list <state.md> <key> -> one machine name per line.
# Handles the three shapes these files use:
#   k: []            /  k: [a, b]
#   k:\n  - a        (plain scalar items)
#   k:\n  - machine: a\n    role: ...\n    detail: ...   (mapping items)
# For mapping items only the `machine:` (or `name:`) key is taken; the item's other
# attributes are attributes, not references, and must not be resolved as machines.
fm_list() {
  fm_block "$1" | awk -v k="$2" '
    BEGIN { inlist = 0 }
    {
      line = $0
      if (substr(line, 1, 1) != " " && substr(line, 1, 1) != "\t") {
        i = index(line, ":")
        if (i > 0 && substr(line, 1, i - 1) == k) {
          v = substr(line, i + 1)
          gsub(/^[ \t]+|[ \t]+$/, "", v)
          if (v ~ /^\[.*\]$/) {
            gsub(/^\[|\]$/, "", v)
            n = split(v, parts, ",")
            for (j = 1; j <= n; j++) {
              p = parts[j]
              gsub(/^[ \t"'\'']+|[ \t"'\'']+$/, "", p)
              if (p != "") print p
            }
            exit
          }
          if (v == "") { inlist = 1; next }
          print v; exit
        } else if (inlist) { exit }
        next
      }
      if (inlist) {
        # Only a line carrying the "-" starts an item. Indented lines without one
        # are attributes of the current item (role:, detail:, ...) — skip them.
        if (line !~ /^[ \t]*-[ \t]*/) next
        v = line
        sub(/^[ \t]*-[ \t]*/, "", v)
        gsub(/[ \t]+$/, "", v)
        if (v ~ /^[A-Za-z_][A-Za-z0-9_-]*[ \t]*:/) {
          mk = v
          sub(/[ \t]*:.*$/, "", mk)
          if (mk != "machine" && mk != "name") next
          sub(/^[^:]*:[ \t]*/, "", v)
        }
        gsub(/^[ \t"'\'']+|[ \t"'\'']+$/, "", v)
        if (v != "") print v
      }
    }
  ' | grep -v '^$' || true
}

# Systemd units named in the `## Services` table of STATE.md.
state_units() {
  awk '
    BEGIN { in_services = 0; col = 0 }
    /^##[ \t]/ {
      in_services = ($0 ~ /^##[ \t]+Services[ \t]*$/) ? 1 : 0
      col = 0
      next
    }
    !in_services { next }
    substr($0, 1, 1) != "|" { next }
    {
      n = split($0, cells, "|")
      if (col == 0) {
        for (i = 2; i < n; i++) {
          c = cells[i]
          gsub(/^[ \t]+|[ \t]+$/, "", c)
          lc = tolower(c)
          if (lc == "unit" || lc == "systemd unit" || lc == "systemd") { col = i; break }
        }
        if (col == 0) col = -1   # no Unit column in this table
        next
      }
      if (col < 0) next
      if ($0 ~ /^\|[ \t]*-+/) next            # separator row
      if (col >= n) next
      c = cells[col]
      gsub(/^[ \t]+|[ \t]+$/, "", c)
      gsub(/^`|`$/, "", c)
      gsub(/^\*+|\*+$/, "", c)
      lc = tolower(c)
      if (c == "" || c == "-" || c == "—" || lc == "(tbd)" || lc == "tbd" || lc == "n/a" || lc == "none") next
      if (c !~ /^[A-Za-z0-9@._:+-]+$/) next
      print c
    }
  ' "$1"
}

# ---------------------------------------------------------------------------
# 08_CONTAINERS.md parsing (falls back to the pre-renumber 06_CONTAINERS.md)
# ---------------------------------------------------------------------------
containers_file() {
  local vault="$1"
  if [[ -f "$vault/08_CONTAINERS.md" ]]; then printf '%s' "$vault/08_CONTAINERS.md"
  elif [[ -f "$vault/06_CONTAINERS.md" ]]; then printf '%s' "$vault/06_CONTAINERS.md"
  fi
}

# Emits: name <TAB> type <TAB> vmid <TAB> ip <TAB> status <TAB> machine_folder
containers_rows() {
  awk '
    BEGIN { col = 0 }
    substr($0, 1, 1) != "|" { next }
    {
      n = split($0, c, "|")
      for (i = 1; i <= n; i++) gsub(/^[ \t]+|[ \t]+$/, "", c[i])
      if (col == 0) {
        for (i = 2; i < n; i++) {
          lc = tolower(c[i])
          if (lc == "name") cn = i
          else if (lc == "type") ct = i
          else if (lc == "vmid" || lc == "id") cv = i
          else if (lc == "ip") ci = i
          else if (lc == "status") cs = i
          else if (lc ~ /machine folder/ || lc == "folder") cf = i
        }
        if (cn > 0) col = 1
        next
      }
      if ($0 ~ /^\|[ \t]*-+/) next
      name = (cn ? c[cn] : "")
      gsub(/\*+/, "", name)
      if (name == "" || tolower(name) == "name") next
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", name, (ct ? c[ct] : ""), (cv ? c[cv] : ""), \
        (ci ? c[ci] : ""), (cs ? c[cs] : ""), (cf ? c[cf] : "")
    }
  ' "$1"
}

# ---------------------------------------------------------------------------
# Machine discovery: a machine folder has a STATE.md or a vault/ directory.
# Topology is DERIVED FROM THE TREE — STATE.md has no `children` key.
# ---------------------------------------------------------------------------
discover_machines() {
  find "$MACHINES_DIR" \
    \( -name '.git' -o -name 'vault' -o -name 'TOOLS' -o -name 'archive' -o -name '.obsidian' \) -prune -o \
    -type d -print |
  while IFS= read -r d; do
    [[ "$d" == "$MACHINES_DIR" ]] && continue
    local_base="$(basename -- "$d")"
    case "$local_base" in VMs|CTs|LXC|Docker) continue ;; esac
    if [[ -f "$d/STATE.md" || -d "$d/vault" ]]; then
      printf '%s\n' "$d"
    fi
  done | sort
}

# expected_parent_type <machine_dir> -> "<parent>\t<type>"
expected_parent_type() {
  local rel parent_path parent type
  rel="${1#"$MACHINES_DIR"/}"
  parent_path="$(dirname -- "$rel")"
  case "$parent_path" in
    .)                 parent="null";                              type="bare-metal" ;;
    */VMs|VMs)         parent="$(basename -- "$(dirname -- "$parent_path")")"; type="vm" ;;
    */CTs/LXC|CTs/LXC) parent="$(basename -- "${parent_path%/CTs/LXC}")";      type="lxc" ;;
    */CTs/Docker|CTs/Docker) parent="$(basename -- "${parent_path%/CTs/Docker}")"; type="docker" ;;
    *)                 parent="UNKNOWN";                           type="unknown" ;;
  esac
  [[ "$parent" == "." ]] && parent="null"
  printf '%s\t%s\n' "$parent" "$type"
}

# ---------------------------------------------------------------------------
# TOOLS/ deployment mapping.
#
# A file in a machine's TOOLS/ folder is a snapshot of something deployed on the
# live host. Nothing keeps the two in sync. Map repo basename -> the candidate
# deployed paths; the remote side picks the first one that actually exists.
# An unrecognised basename yields NO candidates and is reported UNMAPPED rather
# than guessed at — a wrong guess would produce a false DRIFT.
# ---------------------------------------------------------------------------
tool_candidates() {
  local base="$1" stem
  case "$base" in
    *.sh)
      printf '/usr/local/bin/%s\n' "$base"
      ;;
    *.service|*.timer|*.socket|*.path|*.mount|*.target)
      printf '/etc/systemd/system/%s\n' "$base"
      ;;
    *.cron)
      # run-parts and cron.d ignore filenames containing a dot, so the deployed
      # name is the stem; the dotted name is tried second just in case.
      stem="${base%.cron}"
      printf '/etc/cron.d/%s\n/etc/cron.daily/%s\n/etc/cron.d/%s\n/etc/cron.daily/%s\n' \
        "$stem" "$stem" "$base" "$base"
      ;;
    *.*)
      # Unknown extension: no convention to resolve it against.
      ;;
    *)
      # Extensionless: apt.conf.d fragments (50unattended-upgrades, 02periodic),
      # cron fragments, or a plain script in /usr/local/bin.
      printf '/etc/apt/apt.conf.d/%s\n/etc/cron.d/%s\n/etc/cron.daily/%s\n/usr/local/bin/%s\n' \
        "$base" "$base" "$base" "$base"
      ;;
  esac
}

# Files in <machine>/TOOLS worth comparing (skip placeholders and docs).
tool_files() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -maxdepth 1 -type f -print |
    while IFS= read -r f; do
      case "$(basename -- "$f")" in
        .gitkeep|README*.md|README*.MD) continue ;;
      esac
      printf '%s\n' "$f"
    done | sort
}

# ---------------------------------------------------------------------------
# Remote probe. One SSH round trip per machine, read-only commands only.
# ---------------------------------------------------------------------------
# remote_probe <alias> <n_units> <unit>... <toolspec>...
# A toolspec is "<name>|<candidate path>|<candidate path>...": the remote side
# reports the FIRST candidate that exists plus its sha256. Nothing is written.
remote_probe() {
  local alias="$1"; shift
  local args=""
  local u
  for u in "$@"; do args="$args $(printf '%q' "$u")"; done
  # shellcheck disable=SC2029  # $args is printf %q-quoted above: expanding it
  # client-side is exactly what we want.
  ssh "${SSH_OPTS[@]}" "$alias" "bash -s --$args" <<'REMOTE' 2>/dev/null
set -u
p() { printf '%s\t%s\n' "$1" "$2"; }

# Positional args: <n_units> <unit>... then the tool specs.
n_units=${1:-0}
shift || true
units=""
i=0
while [ "$i" -lt "$n_units" ]; do
  units="$units $1"
  shift
  i=$((i + 1))
done

p HOSTNAME "$(hostname 2>/dev/null || echo unknown)"

pretty=unknown
if [ -r /etc/os-release ]; then
  pretty=$(awk -F= '/^PRETTY_NAME=/ { v=$2; gsub(/^"|"$/,"",v); print v; exit }' /etc/os-release)
fi
p OS "${pretty:-unknown}"
p KERNEL "$(uname -r 2>/dev/null || echo unknown)"
p IP "$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | head -1)"

dl=$(df -h / --output=pcent,avail 2>/dev/null | tail -1)
p DISK_PCENT "$(printf '%s' "$dl" | awk '{gsub(/%/,"",$1); print $1}')"
p DISK_AVAIL "$(printf '%s' "$dl" | awk '{print $2}')"

if command -v pct >/dev/null 2>&1; then
  p HAS_PCT yes
  sudo -n pct list 2>/dev/null | tail -n +2 | while read -r vmid status rest; do
    name=$(printf '%s' "$rest" | awk '{print $NF}')
    printf 'PCT\t%s\t%s\t%s\n' "$vmid" "$status" "$name"
  done
  sudo -n qm list 2>/dev/null | tail -n +2 | while read -r vmid name status rest; do
    printf 'QM\t%s\t%s\t%s\n' "$vmid" "$status" "$name"
  done
else
  p HAS_PCT no
fi

if command -v docker >/dev/null 2>&1; then
  p HAS_DOCKER yes
  if ! docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null |
       while IFS='|' read -r n i s; do printf 'DOCKER\t%s\t%s\t%s\n' "$n" "$i" "$s"; done |
       grep -q .; then
    sudo -n docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null |
      while IFS='|' read -r n i s; do printf 'DOCKER\t%s\t%s\t%s\n' "$n" "$i" "$s"; done
  fi
else
  p HAS_DOCKER no
fi

for unit in $units; do
  st=$(systemctl is-active "$unit" 2>/dev/null || true)
  printf 'SVC\t%s\t%s\n' "$unit" "${st:-unknown}"
done

# TOOLS/ deployment check. Read-only: resolve the first candidate path that
# exists and checksum it. Nothing is copied, moved or written either way.
for spec in "$@"; do
  tname=${spec%%|*}
  rest=${spec#*|}
  found=""
  while [ -n "$rest" ]; do
    case "$rest" in
      *"|"*) cand=${rest%%|*}; rest=${rest#*|} ;;
      *)     cand=$rest; rest="" ;;
    esac
    [ -z "$cand" ] && continue
    if [ -f "$cand" ]; then found=$cand; break; fi
  done
  if [ -z "$found" ]; then
    printf 'TOOL\t%s\t\t\n' "$tname"
    continue
  fi
  sum=$(sha256sum "$found" 2>/dev/null | awk '{print $1}')
  if [ -z "$sum" ]; then
    sum=$(sudo -n sha256sum "$found" 2>/dev/null | awk '{print $1}')
  fi
  printf 'TOOL\t%s\t%s\t%s\n' "$tname" "$found" "${sum:-unreadable}"
done

echo "PROBE_END"
REMOTE
}

# ---------------------------------------------------------------------------
# Collect machines
# ---------------------------------------------------------------------------
mapfile -t MACHINE_DIRS < <(discover_machines)
(( ${#MACHINE_DIRS[@]} > 0 )) || die "no machine folders found under $MACHINES_DIR"

declare -A M_DIR=() M_STATE=() M_TYPE=() M_PARENT=() M_IP=() M_STATUS=() M_OS=() M_ALIAS=() M_CID=()
declare -A KNOWN=()
MACHINES=()

for d in "${MACHINE_DIRS[@]}"; do
  name="$(basename -- "$d")"
  MACHINES+=("$name")
  M_DIR["$name"]="$d"
  KNOWN["$name"]=1
  s="$d/STATE.md"
  if [[ -f "$s" ]]; then
    M_STATE["$name"]="$s"
    M_TYPE["$name"]="$(fm_get "$s" type)"
    M_PARENT["$name"]="$(fm_get "$s" parent)"
    M_IP["$name"]="$(fm_get "$s" ip)"
    M_STATUS["$name"]="$(fm_get "$s" status)"
    M_OS["$name"]="$(fm_get "$s" os)"
    M_ALIAS["$name"]="$(fm_get "$s" ssh_alias)"
    M_CID["$name"]="$(fm_get "$s" container_id)"
  else
    M_STATE["$name"]=""
  fi
done

selected() {
  [[ -z "$ONLY_MACHINE" || "$1" == "$ONLY_MACHINE" ]]
}

if [[ -n "$ONLY_MACHINE" && -z "${KNOWN[$ONLY_MACHINE]:-}" ]]; then
  die "no machine folder named '$ONLY_MACHINE' under machines/"
fi

is_null() {
  local v
  v="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ -z "$v" || "$v" == "null" || "$v" == "none" || "$v" == "~" || "$v" == "unknown" || "$v" == "-" ]]
}

# ---------------------------------------------------------------------------
# PASS 1 — vault-internal consistency (always runs, also in --offline)
# ---------------------------------------------------------------------------
declare -A IP_OWNER=()

for name in "${MACHINES[@]}"; do
  selected "$name" || continue
  d="${M_DIR[$name]}"
  s="${M_STATE[$name]}"

  if [[ -z "$s" ]]; then
    report DRIFT "$name" "STATE.md" "present" "missing" "machine folder ${d#"$REPO_ROOT"/} has no STATE.md"
    continue
  fi

  # `|| true`: read returns non-zero at EOF, which set -e would treat as fatal.
  IFS=$'\t' read -r exp_parent exp_type < <(expected_parent_type "$d") || true

  # machine: must match the folder name
  doc_machine="$(fm_get "$s" machine)"
  [[ "$doc_machine" == "$name" ]] || \
    report DRIFT "$name" "machine" "$doc_machine" "$name" "STATE.md machine: does not match the folder name"

  # parent: derived from the directory tree, never from a children list
  doc_parent="${M_PARENT[$name]}"
  norm_parent="$doc_parent"; is_null "$norm_parent" && norm_parent="null"
  [[ "$norm_parent" == "$exp_parent" ]] || \
    report DRIFT "$name" "parent" "$norm_parent" "$exp_parent" "derived from the directory tree"

  # type: must be consistent with where the folder lives
  doc_type="${M_TYPE[$name]}"
  case "$doc_type" in
    bare-metal|vm|lxc|docker) ;;
    *) report DRIFT "$name" "type" "$doc_type" "bare-metal|vm|lxc|docker" "invalid type value" ;;
  esac
  if [[ "$exp_type" != "unknown" && -n "$doc_type" && "$doc_type" != "$exp_type" ]]; then
    report DRIFT "$name" "type" "$doc_type" "$exp_type" "directory tree says $exp_type"
  fi
  [[ "$exp_type" == "unknown" ]] && \
    report WARN "$name" "path" "machines/<host>[/VMs|/CTs/LXC|/CTs/Docker]/<name>" "${d#"$MACHINES_DIR"/}" "folder is not in a canonical location"

  # connection / status enums
  doc_conn="$(fm_get "$s" connection)"
  case "$doc_conn" in
    direct|proxyjump|docker-exec) ;;
    *) report DRIFT "$name" "connection" "$doc_conn" "direct|proxyjump|docker-exec" "invalid connection value" ;;
  esac
  case "${M_STATUS[$name]}" in
    running|stopped|unknown) ;;
    *) report DRIFT "$name" "status" "${M_STATUS[$name]}" "running|stopped|unknown" "invalid status value" ;;
  esac

  # container_id must exist for guests and be absent for bare metal
  if [[ "$exp_type" == "vm" || "$exp_type" == "lxc" ]]; then
    is_null "${M_CID[$name]}" && \
      report WARN "$name" "container_id" "<vmid>" "null" "a $exp_type guest needs its VMID to be managed from the parent"
  fi

  # topology is derived; a children key would be a second source of truth
  if fm_has_key "$s" children; then
    report DRIFT "$name" "children" "absent" "present" "topology is derived from the directory tree; remove the children key"
  fi

  # required keys present
  for k in machine type parent container_id connection ssh_alias ip ip_assignment status os \
           depends_on provides_to backups auto_updates last_reconciled; do
    fm_has_key "$s" "$k" || \
      report DRIFT "$name" "$k" "present" "missing" "STATE.md is missing a contract key"
  done

  # depends_on / provides_to must resolve to real machines
  for k in depends_on provides_to; do
    while IFS= read -r ref; do
      [[ -z "$ref" ]] && continue
      is_null "$ref" && continue
      [[ -n "${KNOWN[$ref]:-}" ]] || \
        report DRIFT "$name" "$k" "$ref" "no such machine folder" "unresolved reference"
    done < <(fm_list "$s" "$k")
  done

  # IP collisions across the fleet
  ip="${M_IP[$name]}"
  if ! is_null "$ip"; then
    ipbare="${ip%%/*}"
    ipbare="${ipbare%% *}"
    if [[ "$ipbare" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      if [[ -n "${IP_OWNER[$ipbare]:-}" ]]; then
        report DRIFT "$name" "ip" "$ipbare" "also claimed by ${IP_OWNER[$ipbare]}" "IP collision between documented machines"
      else
        IP_OWNER["$ipbare"]="$name"
      fi
    fi
  fi

  # Parents: the container inventory must match the child folders on disk
  child_dirs=()
  for sub in "$d"/VMs/* "$d"/CTs/LXC/* "$d"/CTs/Docker/*; do
    [[ -d "$sub" ]] || continue
    child_dirs+=("$(basename -- "$sub")")
  done

  if (( ${#child_dirs[@]} > 0 )); then
    cfile="$(containers_file "$d/vault")"
    if [[ -z "$cfile" ]]; then
      report DRIFT "$name" "08_CONTAINERS.md" "present" "missing" "a parent machine must document its guests"
    else
      if [[ "$(basename -- "$cfile")" == "06_CONTAINERS.md" ]]; then
        report DRIFT "$name" "08_CONTAINERS.md" "vault/08_CONTAINERS.md" "vault/06_CONTAINERS.md" "not yet renumbered to the canonical name"
      fi
      documented_folders=()
      while IFS=$'\t' read -r _ _ _ _ c_status c_folder; do
        [[ -z "$c_folder" || "$c_folder" == "—" || "$c_folder" == "-" ]] && continue
        fb="$(basename -- "$c_folder")"
        documented_folders+=("$fb")
        if [[ ! -d "$REPO_ROOT/$c_folder" && ! -d "$d/../$c_folder" ]]; then
          if [[ -z "${KNOWN[$fb]:-}" ]]; then
            report DRIFT "$name" "08_CONTAINERS.md" "$c_folder" "no such folder" "inventory points at a machine folder that does not exist"
          fi
        fi
        # inventory status vs the guest's own STATE.md
        if [[ -n "${M_STATE[$fb]:-}" && -n "$c_status" ]]; then
          cs="$(printf '%s' "$c_status" | tr '[:upper:]' '[:lower:]')"
          gs="${M_STATUS[$fb]}"
          if [[ -n "$gs" && "$cs" != "$gs" ]]; then
            report DRIFT "$name" "08_CONTAINERS.md:$fb.status" "$cs" "$gs" "inventory disagrees with $fb/STATE.md"
          fi
        fi
      done < <(containers_rows "$cfile")

      for cd_name in "${child_dirs[@]}"; do
        found=0
        for df in "${documented_folders[@]:-}"; do
          [[ "$df" == "$cd_name" ]] && { found=1; break; }
        done
        (( found )) || \
          report DRIFT "$name" "08_CONTAINERS.md" "$cd_name listed" "absent" "child folder is not in the inventory table"
      done
    fi
  fi
done

# ---------------------------------------------------------------------------
# PASS 2 — live discovery over SSH (skipped with --offline)
# ---------------------------------------------------------------------------
PROBE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/reconcile.XXXXXX")"
trap 'rm -rf -- "$PROBE_TMP"' EXIT

if (( ! OFFLINE )); then
  for name in "${MACHINES[@]}"; do
    selected "$name" || continue
    s="${M_STATE[$name]:-}"
    [[ -n "$s" ]] || continue
    alias="${M_ALIAS[$name]}"
    if is_null "$alias"; then
      report WARN "$name" "ssh_alias" "<alias>" "null" "no ssh_alias in STATE.md; skipped live discovery"
      continue
    fi

    mapfile -t units < <(state_units "$s")

    # TOOLS/ specs: "<basename>|<candidate>|<candidate>..." (no candidates =>
    # unmappable, reported locally without bothering the remote host).
    tool_specs=()
    declare -A LOCAL_SUM=()
    while IFS= read -r tf; do
      [[ -n "$tf" ]] || continue
      tb="$(basename -- "$tf")"
      mapfile -t cands < <(tool_candidates "$tb")
      if (( ${#cands[@]} == 0 )); then
        report UNMAPPED "$name" "TOOLS/$tb" "" \
          "no known deployed location for this basename" \
          "not compared; add a mapping in tool_candidates() if it is deployed somewhere"
        continue
      fi
      LOCAL_SUM["$tb"]="$(sha256sum "$tf" | awk '{print $1}')"
      spec="$tb"
      for c in "${cands[@]}"; do spec="$spec|$c"; done
      tool_specs+=("$spec")
    done < <(tool_files "${M_DIR[$name]}/TOOLS")

    # Build the arg vector by hand: "${arr[@]:-}" on an empty array yields one
    # empty argument, which would shift the unit count out of alignment.
    probe_args=("${#units[@]}")
    (( ${#units[@]} > 0 )) && probe_args+=("${units[@]}")
    (( ${#tool_specs[@]} > 0 )) && probe_args+=("${tool_specs[@]}")

    out="$PROBE_TMP/$name.probe"
    if ! remote_probe "$alias" "${probe_args[@]}" > "$out" || ! grep -q '^PROBE_END$' "$out"; then
      if [[ "${M_STATUS[$name]}" == "running" ]]; then
        report DRIFT "$name" "reachability" "running" "unreachable" "ssh to the documented alias failed"
      else
        report INFO "$name" "reachability" "${M_STATUS[$name]}" "unreachable" "consistent with the documented status"
      fi
      continue
    fi

    get() { awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$out"; }

    # status
    [[ "${M_STATUS[$name]}" == "running" ]] || \
      report DRIFT "$name" "status" "${M_STATUS[$name]}" "running" "machine answered over SSH"

    # ip
    actual_ip="$(get IP)"; actual_ip="${actual_ip%%/*}"
    doc_ip="${M_IP[$name]}"; doc_ip="${doc_ip%%/*}"; doc_ip="${doc_ip%% *}"
    if [[ -n "$actual_ip" ]]; then
      if is_null "$doc_ip"; then
        report DRIFT "$name" "ip" "null" "$actual_ip" "live IP is not documented"
      elif [[ "$doc_ip" != "$actual_ip" ]]; then
        report DRIFT "$name" "ip" "$doc_ip" "$actual_ip" ""
      fi
    fi

    # os
    actual_os="$(get OS)"
    doc_os="${M_OS[$name]}"
    if [[ -n "$actual_os" && "$actual_os" != "unknown" ]]; then
      if is_null "$doc_os"; then
        report DRIFT "$name" "os" "unknown" "$actual_os" ""
      else
        lo_doc="$(printf '%s' "$doc_os" | tr '[:upper:]' '[:lower:]')"
        lo_act="$(printf '%s' "$actual_os" | tr '[:upper:]' '[:lower:]')"
        if [[ "$lo_act" != *"$lo_doc"* && "$lo_doc" != *"$lo_act"* ]]; then
          report DRIFT "$name" "os" "$doc_os" "$actual_os" ""
        fi
      fi
    fi

    # hostname (informational: a rename is worth surfacing)
    actual_host="$(get HOSTNAME)"
    if [[ -n "$actual_host" && "$actual_host" != "unknown" && "$actual_host" != "$name" ]]; then
      report INFO "$name" "hostname" "$name" "$actual_host" "folder name and live hostname differ"
    fi

    # disk threshold
    pct="$(get DISK_PCENT)"
    avail="$(get DISK_AVAIL)"
    if [[ "$pct" =~ ^[0-9]+$ ]] && (( pct >= DISK_ALERT_PCT )); then
      report ALERT "$name" "disk" "< ${DISK_ALERT_PCT}%" "${pct}% used" "root filesystem, ${avail} available"
    fi

    # services
    while IFS=$'\t' read -r _ unit st; do
      [[ -z "${unit:-}" ]] && continue
      [[ "$st" == "active" ]] || \
        report DRIFT "$name" "service:$unit" "active" "$st" "unit named in STATE.md ## Services"
    done < <(grep '^SVC	' "$out" || true)

    # ---- TOOLS/ vs deployed copies -------------------------------------------
    # Read-only comparison. The tool never copies in either direction and never
    # names a winner: on hef-proxmox the DEPLOYED copy is the correct one and the
    # repo snapshot is the dangerous one, which is the opposite of the intuition.
    while IFS=$'	' read -r _ tname tpath tsum; do
      [[ -z "${tname:-}" ]] && continue
      lsum="${LOCAL_SUM[$tname]:-}"
      if [[ -z "$tpath" ]]; then
        report DRIFT "$name" "TOOLS/$tname" "sha256:${lsum:0:12} (repo)" \
          "deployed counterpart missing" \
          "none of the candidate paths exist on the host"
        continue
      fi
      if [[ "$tsum" == "unreadable" || -z "$tsum" ]]; then
        report WARN "$name" "TOOLS/$tname" "sha256:${lsum:0:12} (repo)" \
          "could not checksum $tpath" "not readable by the tuneladora user"
        continue
      fi
      if [[ "$tsum" != "$lsum" ]]; then
        report DRIFT "$name" "TOOLS/$tname" "sha256:${lsum:0:12} (repo)" \
          "repo copy differs from $tpath" \
          "deployed sha256:${tsum:0:12}; which copy is authoritative is a human decision"
      fi
    done < <(grep '^TOOL	' "$out" || true)

    # ---- hypervisor guests ---------------------------------------------------
    if [[ "$(get HAS_PCT)" == "yes" ]]; then
      live_ids=""
      while IFS=$'\t' read -r kind vmid st gname; do
        [[ -z "${vmid:-}" ]] && continue
        live_ids="$live_ids $vmid"
        # A guest on the hypervisor with no machine folder is undocumented.
        matched=""
        for cand in "${MACHINES[@]}"; do
          [[ "${M_CID[$cand]:-}" == "$vmid" ]] && { matched="$cand"; break; }
        done
        if [[ -z "$matched" ]]; then
          for cand in "${MACHINES[@]}"; do
            [[ "$cand" == "$gname" ]] && { matched="$cand"; break; }
          done
        fi
        if [[ -z "$matched" ]]; then
          report DRIFT "$name" "undocumented guest" "documented" "$kind $vmid ($gname) has no machine folder" "run tools/new_machine.sh or record it in 08_CONTAINERS.md"
        elif [[ -n "${M_STATE[$matched]:-}" ]]; then
          want="${M_STATUS[$matched]}"
          got="$st"
          [[ "$got" == "running" || "$got" == "stopped" ]] || got="unknown"
          if [[ -n "$want" && "$want" != "$got" ]]; then
            report DRIFT "$matched" "status" "$want" "$got" "from $kind list on $name"
          fi
        fi
      done < <(grep -E '^(PCT|QM)	' "$out" || true)

      # A machine folder whose guest is gone from the hypervisor is an orphan.
      for cand in "${MACHINES[@]}"; do
        [[ "${M_PARENT[$cand]:-}" == "$name" ]] || continue
        cid="${M_CID[$cand]:-}"
        is_null "$cid" && continue
        case " $live_ids " in
          *" $cid "*) ;;
          *) report DRIFT "$cand" "orphan folder" "VMID $cid on $name" "absent from pct/qm list" "the guest no longer exists on the hypervisor" ;;
        esac
      done
    fi

    # ---- docker containers ---------------------------------------------------
    if [[ "$(get HAS_DOCKER)" == "yes" ]]; then
      live_names=""
      while IFS=$'\t' read -r _ cname _ _; do
        [[ -z "${cname:-}" ]] && continue
        live_names="$live_names $cname"
      done < <(grep '^DOCKER	' "$out" || true)

      for cand in "${MACHINES[@]}"; do
        [[ "${M_PARENT[$cand]:-}" == "$name" ]] || continue
        [[ "${M_TYPE[$cand]:-}" == "docker" ]] || continue
        case " $live_names " in
          *" $cand "*)
            [[ "${M_STATUS[$cand]}" == "running" ]] || \
              report DRIFT "$cand" "status" "${M_STATUS[$cand]}" "running" "container is up on $name"
            ;;
          *)
            [[ "${M_STATUS[$cand]}" == "running" ]] && \
              report DRIFT "$cand" "status" "running" "not in docker ps" "on $name"
            ;;
        esac
      done
    fi
  done
fi

# ---------------------------------------------------------------------------
# --write: last_reconciled + status only, and only when nothing else drifted.
# ---------------------------------------------------------------------------
if (( DO_WRITE )); then
  declare -A NEW_STATUS=()
  for i in "${!F_SEV[@]}"; do
    [[ "${F_SEV[$i]}" == "DRIFT" && "${F_FIELD[$i]}" == "status" ]] || continue
    case "${F_ACT[$i]}" in
      running|stopped|unknown) NEW_STATUS["${F_MACHINE[$i]}"]="${F_ACT[$i]}" ;;
    esac
  done

  for name in "${MACHINES[@]}"; do
    selected "$name" || continue
    s="${M_STATE[$name]:-}"
    [[ -n "$s" ]] || continue
    if [[ -n "${BLOCKING_FINDINGS[$name]:-}" ]]; then
      printf 'SKIP-WRITE %s: other drift present, STATE.md left untouched\n' "$name"
      continue
    fi
    if (( OFFLINE )); then
      printf 'SKIP-WRITE %s: --offline cannot confirm reality\n' "$name"
      continue
    fi
    new_status="${NEW_STATUS[$name]:-${M_STATUS[$name]}}"
    tmp="$PROBE_TMP/$name.state"
    awk -v today="$TODAY" -v st="$new_status" '
      BEGIN { fm = 0 }
      NR == 1 && $0 == "---" { fm = 1; print; next }
      fm == 1 && $0 == "---" { fm = 2; print; next }
      fm == 1 && /^status:/ { print "status: " st; next }
      fm == 1 && /^last_reconciled:/ { print "last_reconciled: " today; next }
      { print }
    ' "$s" > "$tmp"
    if cmp -s "$tmp" "$s"; then
      printf 'WRITE %s: already current (%s, %s)\n' "$name" "$new_status" "$TODAY"
    else
      cp -- "$tmp" "$s"
      printf 'WRITE %s: status=%s last_reconciled=%s\n' "$name" "$new_status" "$TODAY"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
TOTAL=${#F_SEV[@]}

if (( JSON )); then
  printf '{\n'
  printf '  "generated": "%s",\n' "$TODAY"
  printf '  "mode": "%s",\n' "$( ((OFFLINE)) && printf 'offline' || printf 'live' )"
  printf '  "drift": %d,\n' "$DRIFT_COUNT"
  printf '  "alerts": %d,\n' "$ALERT_COUNT"
  printf '  "findings": [\n'
  for i in "${!F_SEV[@]}"; do
    printf '    {"severity": "%s", "machine": "%s", "field": "%s", "documented": "%s", "actual": "%s", "note": "%s"}' \
      "$(json_escape "${F_SEV[$i]}")" "$(json_escape "${F_MACHINE[$i]}")" "$(json_escape "${F_FIELD[$i]}")" \
      "$(json_escape "${F_DOC[$i]}")" "$(json_escape "${F_ACT[$i]}")" "$(json_escape "${F_NOTE[$i]}")"
    if (( i < TOTAL - 1 )); then printf ',\n'; else printf '\n'; fi
  done
  printf '  ]\n}\n'
else
  mode="live"; (( OFFLINE )) && mode="offline (vault-internal only)"
  printf 'reconcile.sh — %s — %s\n' "$TODAY" "$mode"
  printf 'machines: %d   findings: %d   drift: %d   alerts: %d\n\n' \
    "$( (( ${#MACHINES[@]} )) && { c=0; for m in "${MACHINES[@]}"; do selected "$m" && c=$((c+1)); done; printf '%s' "$c"; } )" \
    "$TOTAL" "$DRIFT_COUNT" "$ALERT_COUNT"
  if (( TOTAL == 0 )); then
    printf 'OK — no drift detected.\n'
  else
    for i in "${!F_SEV[@]}"; do
      case "${F_SEV[$i]}" in
        DRIFT)
          if [[ "${F_FIELD[$i]}" == TOOLS/* ]]; then
            # These read as a sentence: the interesting part is which deployed
            # path differs, not a documented-vs-actual pair.
            printf 'DRIFT %s %s: %s' "${F_MACHINE[$i]}" "${F_FIELD[$i]}" "${F_ACT[$i]}"
          else
            printf "DRIFT %s %s: documented='%s' actual='%s'" \
              "${F_MACHINE[$i]}" "${F_FIELD[$i]}" "${F_DOC[$i]}" "${F_ACT[$i]}"
          fi
          [[ -n "${F_NOTE[$i]}" ]] && printf '  (%s)' "${F_NOTE[$i]}"
          printf '\n'
          ;;
        *)
          printf '%-8s %s %s: %s' "${F_SEV[$i]}" "${F_MACHINE[$i]}" "${F_FIELD[$i]}" "${F_ACT[$i]}"
          [[ -n "${F_NOTE[$i]}" ]] && printf '  (%s)' "${F_NOTE[$i]}"
          printf '\n'
          ;;
      esac
    done
  fi
fi

if (( DRIFT_COUNT > 0 || ALERT_COUNT > 0 )); then
  exit 1
fi
exit 0
