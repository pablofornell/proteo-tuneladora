#!/usr/bin/env bash
# setup_tuneladora_control.sh — Generate the tuneladora SSH key and produce the
# setup command to hand to the admin for the target machine.
#
# Usage:
#   bash tools/setup_tuneladora_control.sh --machine <name> [options]
#
# Options:
#   --machine     <name>  Canonical machine name (required)
#   --replace-key         Regenerate the key even if one already exists, and pass
#                         --replace-key to the target command (use when recovering a lost key)
#   --lxc                 Target is an LXC container (changes the output command)
#   --vmid        <id>    LXC container VMID (required with --lxc)
#   --group       <name>  Pass a --group flag through to the target script (e.g. admin for UGOS)
#
# This script is run by the agent on the local control machine.
# It does NOT modify ~/.ssh/config — the agent handles that in the hardening phase
# (ADD_MACHINE.md Phase 4, ADD_NAS.md Phase 4, ADD_CONTAINER.md Phase C3).

set -euo pipefail

MACHINE=""
LXC_MODE=false
VMID=""
EXTRA_GROUP=""
REPLACE_KEY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --machine)     MACHINE="$2"; shift 2 ;;
        --replace-key) REPLACE_KEY=true; shift ;;
        --lxc)         LXC_MODE=true; shift ;;
        --vmid)        VMID="$2"; shift 2 ;;
        --group)       EXTRA_GROUP="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

[[ -z "$MACHINE" ]] && { echo "Error: --machine is required"; exit 1; }
[[ "$LXC_MODE" == true && -z "$VMID" ]] && { echo "Error: --vmid is required with --lxc"; exit 1; }

KEY_FILE="$HOME/.ssh/tuneladora_${MACHINE}"

# Generate key: always if missing, or if --replace-key is set
if [[ ! -f "$KEY_FILE" ]]; then
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "tuneladora@${MACHINE}"
    echo "[tuneladora-control] Key generated: $KEY_FILE"
elif [[ "$REPLACE_KEY" == true ]]; then
    rm -f "$KEY_FILE" "${KEY_FILE}.pub"
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "tuneladora@${MACHINE}"
    echo "[tuneladora-control] Key replaced (recovery): $KEY_FILE"
else
    echo "[tuneladora-control] Key already exists: $KEY_FILE"
fi

PUBKEY=$(cat "${KEY_FILE}.pub")
FINGERPRINT=$(ssh-keygen -lf "${KEY_FILE}.pub")

# Build the optional flags for the target command
EXTRA_FLAGS=""
[[ "$REPLACE_KEY" == true ]] && EXTRA_FLAGS+=" --replace-key"
[[ -n "$EXTRA_GROUP" ]] && EXTRA_FLAGS+=" --group $EXTRA_GROUP"
[[ "$LXC_MODE" == true ]] && EXTRA_FLAGS+=" --lxc --vmid $VMID"

echo ""
echo "================================================================"
echo " PUBLIC KEY"
echo "================================================================"
echo "$PUBKEY"
echo ""
echo "Fingerprint: $FINGERPRINT"
echo ""

if [[ "$LXC_MODE" == true ]]; then
    echo "================================================================"
    echo " AGENT COMMAND (run autonomously via SSH on parent)"
    echo "================================================================"
    echo "The agent will run this on the parent machine — no human action needed:"
    echo ""
    echo "  scp tools/setup_tuneladora_target.sh <parent-name>:/tmp/"
    echo "  ssh <parent-name> \"bash /tmp/setup_tuneladora_target.sh --pubkey '$PUBKEY'$EXTRA_FLAGS\""
else
    echo "================================================================"
    echo " ADMIN COMMAND (run on the target machine with sudo)"
    echo "================================================================"
    echo "Transfer the script, then ask the admin to run:"
    echo ""
    echo "  sudo bash /tmp/setup_tuneladora_target.sh --pubkey '$PUBKEY'$EXTRA_FLAGS"
fi

echo "================================================================"
echo ""
echo "[tuneladora-control] Next: the agent applies the from= restriction and updates"
echo "                     ~/.ssh/config — ADD_MACHINE.md Phase 4, ADD_NAS.md Phase 4,"
echo "                     ADD_CONTAINER.md Phase C3. Validate with Phase 4b / Phase E."
