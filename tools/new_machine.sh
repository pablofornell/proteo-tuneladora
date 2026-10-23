#!/usr/bin/env bash
# new_machine.sh — Scaffold a new machine folder for Tuneladora
#
# Usage:
#   ./tools/new_machine.sh <machine-name> [--type bare-metal|vm|lxc|docker] [--parent <machine-name>] [--hosts-children]
#   ./tools/new_machine.sh <machine-name> --containers-note
#
# Options:
#   --type             Node type: bare-metal (default), vm, lxc, docker
#   --parent           Parent machine name (required for vm, lxc, and docker)
#   --hosts-children   Force generation of vault/08_CONTAINERS.md for an lxc or
#                      docker node that itself hosts child machines (e.g. an LXC
#                      running a Docker engine). bare-metal and vm always get it.
#   --containers-note  Retrofit mode: write vault/08_CONTAINERS.md into an
#                      EXISTING machine folder and do nothing else. Use when a
#                      leaf node starts hosting children (the hef-docker case)
#                      and tools/validate.sh FAILs it for the missing note.
#                      Idempotent: refuses to overwrite an existing file.
#
# Creates the canonical folder and vault structure under the correct path:
#   bare-metal → machines/<name>/
#   vm         → machines/<parent>/VMs/<name>/
#   lxc        → machines/<parent>/CTs/LXC/<name>/
#   docker     → machines/<parent>/CTs/Docker/<name>/
#
# This script is the single source of truth for machine folder structure.
# Run it instead of manually creating files to ensure consistency with SPEC.md.

set -euo pipefail

# ── Defaults ───────────────────────────────────────────────────────────────────

MACHINE_TYPE="bare-metal"
PARENT=""
HOSTS_CHILDREN=0
RETROFIT_CONTAINERS=0

# ── Parse arguments ────────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
  printf '%b\n' "Usage: $0 <machine-name> [--type bare-metal|vm|lxc|docker] [--parent <machine-name>] [--hosts-children]\n       $0 <machine-name> --containers-note   # retrofit vault/08_CONTAINERS.md into an existing machine" >&2
  exit 1
fi

MACHINE="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)
      MACHINE_TYPE="$2"
      shift 2
      ;;
    --parent)
      PARENT="$2"
      shift 2
      ;;
    --hosts-children)
      HOSTS_CHILDREN=1
      shift
      ;;
    --containers-note)
      RETROFIT_CONTAINERS=1
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      printf '%b\n' "Usage: $0 <machine-name> [--type bare-metal|vm|lxc|docker] [--parent <machine-name>] [--hosts-children]\n       $0 <machine-name> --containers-note   # retrofit vault/08_CONTAINERS.md into an existing machine" >&2
      exit 1
      ;;
  esac
done

# ── Validate machine name ──────────────────────────────────────────────────────

if [[ ! "$MACHINE" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$ ]]; then
  echo "Error: machine name must be lowercase alphanumeric with hyphens (e.g. 'web-prod', 'db-01')" >&2
  exit 1
fi

# ── Validate type ──────────────────────────────────────────────────────────────

case "$MACHINE_TYPE" in
  bare-metal|vm|lxc|docker) ;;
  *)
    echo "Error: --type must be one of: bare-metal, vm, lxc, docker" >&2
    exit 1
    ;;
esac

# ── Validate parent requirement ────────────────────────────────────────────────

if [[ "$MACHINE_TYPE" != "bare-metal" ]] && [[ -z "$PARENT" ]]; then
  echo "Error: --parent is required when --type is vm, lxc, or docker" >&2
  exit 1
fi

if [[ -n "$PARENT" ]] && [[ ! "$PARENT" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$ ]]; then
  echo "Error: parent name must be lowercase alphanumeric with hyphens" >&2
  exit 1
fi

# ── Resolve paths ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DATE="$(date +%Y-%m-%d)"

# Determine the subfolder based on type
case "$MACHINE_TYPE" in
  bare-metal) SUBDIR="" ;;
  vm)         SUBDIR="VMs" ;;
  lxc)        SUBDIR="CTs/LXC" ;;
  docker)     SUBDIR="CTs/Docker" ;;
esac

# Build the full machine directory path
if [[ -n "$PARENT" && -n "$SUBDIR" ]]; then
  MACHINE_DIR="$REPO_ROOT/machines/$PARENT/$SUBDIR/$MACHINE"
else
  MACHINE_DIR="$REPO_ROOT/machines/$MACHINE"
fi

VAULT_DIR="$MACHINE_DIR/vault"

# ── Guard: already exists ──────────────────────────────────────────────────────

# Retrofit mode (--containers-note) targets an existing folder on purpose, so
# this guard applies to the scaffold path only.
if [[ "$RETROFIT_CONTAINERS" -eq 0 ]] && [[ -d "$MACHINE_DIR" ]]; then
  echo "Error: $MACHINE_DIR already exists. Aborting to avoid overwriting." >&2
  exit 1
fi

# ── Guard: parent must exist (if specified) ────────────────────────────────────

if [[ -n "$PARENT" ]]; then
  # Resolve the parent directory path
  if [[ -n "$SUBDIR" ]]; then
    # Parent could be bare-metal or itself a child; check both possibilities
    PARENT_DIR="$REPO_ROOT/machines/$PARENT"
    if [[ ! -d "$PARENT_DIR" ]]; then
      echo "Error: parent machine '$PARENT' not found." >&2
      echo "       Expected at: machines/$PARENT/" >&2
      echo "       (Or machines/<grandparent>/VMs/$PARENT/ if the parent is itself a child)" >&2
      exit 1
    fi
  fi
fi

# ── Derive connection model ────────────────────────────────────────────────────

case "$MACHINE_TYPE" in
  bare-metal) CONNECTION_MODEL="direct" ;;
  vm)         CONNECTION_MODEL="direct" ;;
  lxc)        CONNECTION_MODEL="proxyjump" ;;
  docker)     CONNECTION_MODEL="docker-exec" ;;
esac

# ── Compute relative path for messages ─────────────────────────────────────────

REL_PATH="${MACHINE_DIR#$REPO_ROOT/}"

# ── 08_CONTAINERS.md template (single copy — used by both the scaffold path and
#    the --containers-note retrofit path; never duplicate this heredoc) ────────

emit_containers_note() {
  local target="$1"
  cat > "$target" << HEREDOC
# $MACHINE — Child Machines

> Last updated: $DATE (scaffolded — populate when children are added)
>
> This note documents the children this machine hosts. The authoritative child
> list is the directory tree (\`VMs/\`, \`CTs/LXC/\`, \`CTs/Docker/\`); this note adds
> the operational detail the tree cannot carry.

## Inventory

| Child | Type | ID | Connection | Status | Folder |
|-------|------|----|------------|--------|--------|
| *(none yet)* | — | — | — | — | — |

## Lifecycle

*(How children are started, stopped and destroyed from this host — always
manage a child's lifecycle through this parent, never through the child's own
connection.)*

\`\`\`bash
# e.g. Proxmox: pct list / pct start <vmid> / qm list
# e.g. Docker:  docker ps -a / docker start <name>
\`\`\`

## Resource Allocation

| Child | CPU | RAM | Disk | Notes |
|-------|-----|-----|------|-------|
| *(TBD)* | *(TBD)* | *(TBD)* | *(TBD)* | *(TBD)* |

## History

- $DATE: File scaffolded. No children registered yet.
HEREDOC
}

# ── Retrofit mode: --containers-note ───────────────────────────────────────────
# Writes vault/08_CONTAINERS.md into an EXISTING machine folder and exits. Used
# when a node that was scaffolded as a leaf starts hosting children and
# tools/validate.sh FAILs it for the missing note. Never overwrites.

if [[ "$RETROFIT_CONTAINERS" -eq 1 ]]; then
  # The machine may sit anywhere in the tree, so locate it by folder name.
  FOUND=()
  while IFS= read -r d; do
    [[ -n "$d" ]] && FOUND+=("$d")
  done < <(find "$REPO_ROOT/machines" -name '.git' -prune -o -type d -name "$MACHINE" -print | sort)

  if [[ ${#FOUND[@]} -eq 0 ]]; then
    echo "Error: machine '$MACHINE' not found under machines/." >&2
    echo "       --containers-note only retrofits an existing machine folder." >&2
    exit 1
  fi
  if [[ ${#FOUND[@]} -gt 1 ]]; then
    echo "Error: machine name '$MACHINE' is ambiguous — found:" >&2
    printf '       %s\n' "${FOUND[@]#"$REPO_ROOT/"}" >&2
    exit 1
  fi

  MACHINE_DIR="${FOUND[0]}"
  VAULT_DIR="$MACHINE_DIR/vault"
  REL_PATH="${MACHINE_DIR#$REPO_ROOT/}"

  if [[ ! -d "$VAULT_DIR" ]]; then
    echo "Error: $REL_PATH/vault/ does not exist — is '$MACHINE' really a machine folder?" >&2
    exit 1
  fi

  if [[ -e "$VAULT_DIR/08_CONTAINERS.md" ]]; then
    echo "$REL_PATH/vault/08_CONTAINERS.md already exists — refusing to overwrite."
    echo "No changes made."
    exit 0
  fi

  emit_containers_note "$VAULT_DIR/08_CONTAINERS.md"
  echo "Created: $REL_PATH/vault/08_CONTAINERS.md"
  echo ""
  echo "Next steps:"
  echo "  1. Fill in the Inventory table with the children already in the tree."
  echo "  2. Log the change in vault/03_TASK_LOG.md (SPEC.md §4.1)."
  echo "  3. Re-run: tools/validate.sh --machine $MACHINE"
  exit 0
fi


# ── Create structure ───────────────────────────────────────────────────────────

echo "Creating machine: $MACHINE (type: $MACHINE_TYPE${PARENT:+, parent: $PARENT})"
echo "Path: $REL_PATH"
mkdir -p "$VAULT_DIR" "$VAULT_DIR/archive" "$MACHINE_DIR/TOOLS"
touch "$MACHINE_DIR/TOOLS/.gitkeep" "$VAULT_DIR/archive/.gitkeep"

# 08_CONTAINERS.md belongs to machines that can host children. bare-metal and vm
# always can; an lxc/docker leaf only when --hosts-children says so (hef-docker
# is an LXC that runs a Docker engine and therefore does host children).
case "$MACHINE_TYPE" in
  bare-metal|vm) GENERATE_CONTAINERS=1 ;;
  *)             GENERATE_CONTAINERS=$HOSTS_CHILDREN ;;
esac

# ── STATE.md ───────────────────────────────────────────────────────────────────
# L1 context: YAML frontmatter + a short body, kept under 2 KB.
# There is deliberately no `children:` key — the child list is derived from the
# directory tree, which is the only source of truth for containment.

cat > "$MACHINE_DIR/STATE.md" << HEREDOC
---
machine: $MACHINE
type: $MACHINE_TYPE
parent: ${PARENT:-null}
container_id: null
connection: $CONNECTION_MODEL
ssh_alias: $MACHINE
ip: null
ip_assignment: unknown
status: unknown
os: unknown
depends_on: []
provides_to: []
backups:
  configured: false
  destination: null
  last_verified: null
auto_updates:
  configured: false
  tool: null
  schedule: null
last_reconciled: $DATE
---

# $MACHINE

*(One line: what this machine is for. Populate during setup.)*

## Services

| Service | Port | Unit | Status |
|---------|------|------|--------|
| *(TBD)* | *(TBD)* | *(TBD)* | *(TBD)* |

## Open Issues

- Scaffolded $DATE — not yet set up or reconciled against the live host.

## Read Next

- \`CONTEXT.md\` — purpose, network, quirks
- \`vault/02_SERVICES.md\` — service detail
- \`vault/04_NOTES.md\` — warnings and scope limits
HEREDOC

# ── CLAUDE.md ──────────────────────────────────────────────────────────────────

cat > "$MACHINE_DIR/CLAUDE.md" << HEREDOC
# $MACHINE — Machine Rules

## Identity

You are operating on **$MACHINE** (type: $MACHINE_TYPE${PARENT:+, hosted on $PARENT}).

## Machine-Specific Rules

- Add real machine-specific rules here during setup (after system discovery).
- These rules override the global CLAUDE.md when they conflict.
- Delete this placeholder block once real rules are in place.

## Key Paths

*(Populate during setup)*
HEREDOC

# ── CONTEXT.md ─────────────────────────────────────────────────────────────────

cat > "$MACHINE_DIR/CONTEXT.md" << HEREDOC
# $MACHINE — Context

> Populated during setup. Do not leave this as a template.

## OS

*(Populate during setup)*

## Purpose

*(What does this machine do?)*

## Network

*(IP, interfaces, bridge, port mappings, etc.)*

## Known Quirks

*(Any non-obvious behaviors, resource constraints, or operational warnings)*

## History

- $DATE: Machine scaffolded via new_machine.sh.
HEREDOC

# ── REFERENCES.md ──────────────────────────────────────────────────────────────

cat > "$MACHINE_DIR/REFERENCES.md" << HEREDOC
# $MACHINE — References

## Documentation Links

## Runbooks

## Vendor Contacts

## Tools
HEREDOC

# ── 00_INDEX.md ────────────────────────────────────────────────────────────────

cat > "$VAULT_DIR/00_INDEX.md" << HEREDOC
# $MACHINE — Vault Index

## Notes

| File | Contents |
|------|----------|
| [[01_SYSTEM_INFO]] | OS, kernel, hardware, IPs, admin users |
| [[02_SERVICES]] | Running services, ports, config paths |
| [[03_TASK_LOG]] | Chronological log of all tasks performed |
| [[04_NOTES]] | Free-form observations, warnings, scope limits |
| [[05_SECURITY]] | SSH access policies, user accounts, restrictions |
| [[06_BACKUPS]] | Backup jobs, retention, restore procedures, credentials location |
| [[07_UPDATES]] | Auto-update system, maintenance schedule, manual update procedure |
| [[08_CONTAINERS]] | Child machines hosted here (parent machines only) |
| [[09_TROUBLESHOOTING]] | Recurring incidents and their fixes (optional) |
| \`archive/\` | Rotated task-log entries, one file per quarter (YYYY-QN.md) |

## Status

- Vault created: $DATE
- Machine type: $MACHINE_TYPE
- Parent: ${PARENT:-none}
- Setup status: awaiting setup
- Backup status: not configured
- Auto-updates: not configured
HEREDOC

# ── 01_SYSTEM_INFO.md ──────────────────────────────────────────────────────────

cat > "$VAULT_DIR/01_SYSTEM_INFO.md" << HEREDOC
# $MACHINE — System Info

> Last updated: $DATE (scaffolded — populate during setup)

## OS

| Field | Value |
|-------|-------|
| OS | *(TBD)* |
| Kernel | *(TBD)* |
| Architecture | *(TBD)* |
| Hostname | *(TBD)* |

## Hardware

| Field | Value |
|-------|-------|
| CPU | *(TBD)* |
| RAM | *(TBD)* |

## Network

| Interface | IP | Notes |
|-----------|----|-------|
| *(TBD)* | *(TBD)* | *(TBD)* |

## Storage

| Filesystem | Size | Used | Avail | Use% | Mount |
|------------|------|------|-------|------|-------|
| *(TBD)* | *(TBD)* | *(TBD)* | *(TBD)* | *(TBD)* | / |

## Admin Users

| User | SSH Key | Sudo | Notes |
|------|---------|------|-------|
| tuneladora | \`~/.ssh/tuneladora_$MACHINE\` | NOPASSWD | Dedicated admin user |
| *(personal)* | *(TBD)* | sudo (with password) | Personal fallback |
HEREDOC

# ── 02_SERVICES.md ─────────────────────────────────────────────────────────────

cat > "$VAULT_DIR/02_SERVICES.md" << HEREDOC
# $MACHINE — Services

> Last updated: $DATE (scaffolded — populate during setup)

## Active Services

| Service | Status | Port | Config Path | Notes |
|---------|--------|------|-------------|-------|
| *(TBD)* | *(TBD)* | *(TBD)* | *(TBD)* | *(TBD)* |
HEREDOC

# ── 03_TASK_LOG.md ─────────────────────────────────────────────────────────────

cat > "$VAULT_DIR/03_TASK_LOG.md" << HEREDOC
# $MACHINE — Task Log

> Append-only. Never delete or rewrite past entries.
> Format: see SPEC.md §4 (task log entry format).

## $DATE — Machine Scaffolded
**Requested by:** user
**Status:** success
**Summary:** Created machine folder structure via \`tools/new_machine.sh $MACHINE --type $MACHINE_TYPE${PARENT:+ --parent $PARENT}\` at \`$REL_PATH\`.
**Commands run:**
- \`tools/new_machine.sh $MACHINE --type $MACHINE_TYPE${PARENT:+ --parent $PARENT}\`
**Rollback:** \`rm -rf "$REL_PATH"\`
**Notes:** Awaiting setup before any server operations.
HEREDOC

# ── 04_NOTES.md ────────────────────────────────────────────────────────────────

cat > "$VAULT_DIR/04_NOTES.md" << HEREDOC
# $MACHINE — Notes

> Free-form observations, warnings, and tips.

## Setup Status

- [ ] SSH connectivity verified
- [ ] tuneladora user configured
- [ ] SSH hardened
- [ ] System discovered and context files populated
- [ ] STATE.md populated
- [ ] Reconciled against live host (tools/reconcile.sh)
- [ ] Parent vault (08_CONTAINERS.md) updated${PARENT:+: $PARENT}
- [ ] Backup job configured (06_BACKUPS.md)
- [ ] Auto-update system configured (07_UPDATES.md)
HEREDOC

# ── 05_SECURITY.md ─────────────────────────────────────────────────────────────

cat > "$VAULT_DIR/05_SECURITY.md" << HEREDOC
# $MACHINE — Security

> Last updated: $DATE (scaffolded — populate during setup)

## SSH Access

| User | Key File | Fingerprint | Restrictions | Status |
|------|----------|-------------|--------------|--------|
| tuneladora | \`~/.ssh/tuneladora_$MACHINE\` | *(TBD)* | \`from="<subnet>"\`, no-agent-forwarding, no-X11-forwarding | Pending |
| *(personal)* | *(TBD)* | — | None | Fallback |

## User Accounts

| User | Shell | Sudo | Password Login | Notes |
|------|-------|------|----------------|-------|
| tuneladora | /bin/bash | NOPASSWD: ALL | Disabled | Primary admin — pending setup |
| *(personal)* | /bin/bash | sudo (with password) | Enabled | Personal fallback |

## Firewall

*(Not configured yet)*

## Audit Notes

- $DATE: Machine scaffolded. SSH setup pending.
HEREDOC

# ── 06_BACKUPS.md ──────────────────────────────────────────────────────────────

cat > "$VAULT_DIR/06_BACKUPS.md" << HEREDOC
# $MACHINE — Backups

> Last updated: $DATE (scaffolded — populate when backups are configured)

## Status

| Field | Value |
|-------|-------|
| Backup configured | no |
| Last verified | *(TBD)* |
| Offsite copy | *(TBD — yes / no)* |

## Backup Jobs

*(Populate when a backup job is configured for this machine)*

| Job | Tool | Source | Destination | Schedule | Status |
|-----|------|--------|-------------|----------|--------|
| *(TBD)* | *(TBD)* | *(TBD)* | *(TBD)* | *(TBD)* | *(TBD)* |

## Backup Role

- **As source:** *(does this machine produce backups of its data? describe what and where)*
- **As destination:** *(does this machine receive backups from others? describe what and from whom)*

## Credentials & Keys

*(List all secrets required to access or decrypt backups — never store the values here, only the paths)*

| Secret | Location | Notes |
|--------|----------|-------|
| *(TBD)* | *(TBD)* | *(TBD)* |

> ⚠️ If any encryption key is lost, the backup becomes unrecoverable. Ensure keys are stored in at least two locations.

## Restore Procedure

*(Populate with exact commands — this section is meant to be actionable under pressure)*

\`\`\`bash
# Step-by-step restore commands go here
\`\`\`

## Retention Policy

*(Describe what is kept and for how long)*

## History

- $DATE: File scaffolded. No backups configured yet.
HEREDOC

# ── 07_UPDATES.md ──────────────────────────────────────────────────────────────

cat > "$VAULT_DIR/07_UPDATES.md" << HEREDOC
# $MACHINE — Updates

> Last updated: $DATE (scaffolded — populate during setup)

## Status

| Field | Value |
|-------|-------|
| Auto-updates | not configured |
| Tool | *(TBD)* |
| Scope | *(TBD — security only / all packages)* |
| Schedule | *(TBD)* |
| Auto-reboot | *(TBD — yes / no / if-needed)* |
| Last verified | *(TBD)* |

## Configuration

*(Populate when the auto-update system is configured)*

| Field | Value |
|-------|-------|
| Config file | *(TBD)* |
| Service/unit | *(TBD)* |
| Log location | *(TBD)* |
| Notification | *(TBD — email / log-only / none)* |

## Manual Update Procedure

*(How to safely run updates on this machine)*

\`\`\`bash
# Commands go here — e.g. for Debian/Ubuntu:
# sudo apt update && sudo apt upgrade -y
\`\`\`

## Maintenance Notes

*(Reboot constraints, maintenance windows, services that need explicit restart)*

## History

- $DATE: File scaffolded. No automatic updates configured yet.
HEREDOC

# ── 08_CONTAINERS.md (parent machines only) ────────────────────────────────────

if [[ "$GENERATE_CONTAINERS" -eq 1 ]]; then
  emit_containers_note "$VAULT_DIR/08_CONTAINERS.md"
fi

# ── Done ───────────────────────────────────────────────────────────────────────

echo ""
echo "Done. Structure created at: $REL_PATH/"
if [[ "$GENERATE_CONTAINERS" -eq 1 ]]; then
  echo "Generated vault/08_CONTAINERS.md (this machine can host children)."
else
  echo "No vault/08_CONTAINERS.md (leaf node). Re-run with --hosts-children if it hosts children."
fi
echo ""

# Print SSH config snippet based on type
case "$MACHINE_TYPE" in
  bare-metal|vm)
    echo "Add to ~/.ssh/config:"
    echo "──────────────────────────────────────────"
    echo "Host $MACHINE"
    echo "  HostName <ip-or-hostname>"
    echo "  User tuneladora"
    echo "  IdentityFile ~/.ssh/tuneladora_$MACHINE"
    echo "  IdentitiesOnly yes"
    echo "  IdentityAgent none"
    echo "  AddKeysToAgent no"
    echo "  BatchMode yes"
    echo "  PasswordAuthentication no"
    echo "  KbdInteractiveAuthentication no"
    echo "──────────────────────────────────────────"
    echo ""
    echo "Next steps:"
    echo "  1. Follow workflows/ADD_MACHINE.md: configure personal SSH access"
    echo "  2. Tell Tuneladora: 'SSH ready for $MACHINE'"
    ;;
  lxc)
    echo "Add to ~/.ssh/config:"
    echo "──────────────────────────────────────────"
    echo "Host $MACHINE"
    echo "  HostName <container-ip>"
    echo "  User tuneladora"
    echo "  IdentityFile ~/.ssh/tuneladora_$MACHINE"
    echo "  IdentitiesOnly yes"
    echo "  IdentityAgent none"
    echo "  AddKeysToAgent no"
    echo "  BatchMode yes"
    echo "  PasswordAuthentication no"
    echo "  KbdInteractiveAuthentication no"
    echo "  ProxyJump $PARENT"
    echo "──────────────────────────────────────────"
    echo ""
    echo "Discover container IP on parent:"
    echo "  ssh $PARENT \"pct exec <vmid> -- ip -4 addr show eth0\""
    echo ""
    echo "Next steps:"
    echo "  1. Follow workflows/ADD_CONTAINER.md: LXC setup workflow"
    echo "  2. Update STATE.md with container_id, ip and ip_assignment"
    echo "  3. Tell Tuneladora: 'Container ready for $MACHINE'"
    ;;
  docker)
    echo "Add to ~/.ssh/config:"
    echo "──────────────────────────────────────────"
    echo "Host $MACHINE"
    echo "  HostName unused"
    echo "  ProxyCommand ssh $PARENT \"docker exec -i <container-name> sh -c 'if [ -x /bin/bash ]; then exec /bin/bash; else exec /bin/sh; fi'\""
    echo "  StrictHostKeyChecking no"
    echo "  UserKnownHostsFile /dev/null"
    echo "──────────────────────────────────────────"
    echo ""
    echo "Discover running containers on parent:"
    echo "  ssh $PARENT \"docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'\""
    echo ""
    echo "Next steps:"
    echo "  1. Follow workflows/ADD_CONTAINER.md: Docker setup workflow"
    echo "  2. Update STATE.md with container_id and the container's default user"
    echo "  3. Tell Tuneladora: 'Container ready for $MACHINE'"
    ;;
esac
