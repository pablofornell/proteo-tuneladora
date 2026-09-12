#!/usr/bin/env bash
# setup_tuneladora_target.sh — Create the tuneladora user on a target machine.
#
# Usage (bare-metal / VM — run as admin with sudo on the target):
#   sudo bash /tmp/setup_tuneladora_target.sh --pubkey "ssh-ed25519 AAAA..."
#
# Usage (LXC container — run as tuneladora on the parent via SSH):
#   bash /tmp/setup_tuneladora_target.sh --pubkey "ssh-ed25519 AAAA..." --lxc --vmid 101
#
# Usage (key recovery — replace authorized_keys with a new key):
#   sudo bash /tmp/setup_tuneladora_target.sh --pubkey "ssh-ed25519 AAAA..." --replace-key
#
# Options:
#   --pubkey      "..."  Public key to install in authorized_keys (required)
#   --replace-key        Overwrite authorized_keys instead of appending (use when recovering a lost key)
#   --lxc                Run commands inside a container via pct exec instead of locally
#   --vmid        <id>   LXC container VMID (required with --lxc)
#   --group       <name> Additional group to add tuneladora to (e.g. admin for UGOS)
#
# The script is idempotent — safe to re-run.
# The from= restriction on authorized_keys is applied later by the agent, in the
# hardening phase: ADD_MACHINE.md Phase 4, ADD_NAS.md Phase 4, ADD_CONTAINER.md Phase C3.

set -euo pipefail

PUBKEY=""
LXC_MODE=false
VMID=""
EXTRA_GROUP=""
REPLACE_KEY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pubkey)      PUBKEY="$2"; shift 2 ;;
        --replace-key) REPLACE_KEY=true; shift ;;
        --lxc)         LXC_MODE=true; shift ;;
        --vmid)        VMID="$2"; shift 2 ;;
        --group)       EXTRA_GROUP="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

[[ -z "$PUBKEY" ]] && { echo "Error: --pubkey is required"; exit 1; }
[[ "$LXC_MODE" == true && -z "$VMID" ]] && { echo "Error: --vmid is required with --lxc"; exit 1; }

run() {
    if [[ "$LXC_MODE" == true ]]; then
        sudo pct exec "$VMID" -- bash -c "$1"
    else
        bash -c "$1"
    fi
}

echo "[tuneladora-setup] Starting..."

# Ensure sudo is installed (fresh containers may not have it)
run "which sudo &>/dev/null || (apt-get update -qq && apt-get install -y sudo); mkdir -p /etc/sudoers.d"

# Create user (idempotent)
run "id tuneladora &>/dev/null && echo 'User tuneladora already exists, skipping.' || useradd -m -s /bin/bash tuneladora"

# Sudoers
run "echo 'tuneladora ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/tuneladora && chmod 440 /etc/sudoers.d/tuneladora"

# SSH directory
run "mkdir -p /home/tuneladora/.ssh && chown tuneladora:tuneladora /home/tuneladora/.ssh && chmod 700 /home/tuneladora/.ssh"

# Install public key
ESCAPED="${PUBKEY//\'/\'\\\'\'}"
if [[ "$REPLACE_KEY" == true ]]; then
    # Recovery mode: wipe all previous keys and install only the new one
    run "echo '$ESCAPED' > /home/tuneladora/.ssh/authorized_keys; \
        chown tuneladora:tuneladora /home/tuneladora/.ssh/authorized_keys; \
        chmod 600 /home/tuneladora/.ssh/authorized_keys"
    echo "[tuneladora-setup] authorized_keys replaced (recovery mode — all previous keys removed)."
else
    # Normal mode: append if not already present (idempotent)
    run "grep -qxF '$ESCAPED' /home/tuneladora/.ssh/authorized_keys 2>/dev/null \
        || echo '$ESCAPED' >> /home/tuneladora/.ssh/authorized_keys; \
        chown tuneladora:tuneladora /home/tuneladora/.ssh/authorized_keys; \
        chmod 600 /home/tuneladora/.ssh/authorized_keys"
fi

# Optional group membership (e.g. admin on UGOS)
if [[ -n "$EXTRA_GROUP" ]]; then
    run "usermod -aG '$EXTRA_GROUP' tuneladora"
    echo "[tuneladora-setup] Added tuneladora to group: $EXTRA_GROUP"
fi

# Ensure openssh-server is installed and active (LXC containers may not have it)
if [[ "$LXC_MODE" == true ]]; then
    run "which sshd &>/dev/null \
        || (apt-get update -qq && apt-get install -y openssh-server); \
        systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true"
    echo "[tuneladora-setup] SSH daemon verified."
fi

# Lock password — key-only auth from this point
run "passwd -l tuneladora"

echo "[tuneladora-setup] Done. tuneladora is ready for SSH key-based login."
echo "[tuneladora-setup] Next: the agent applies the from= restriction and updates ~/.ssh/config"
echo "[tuneladora-setup] (ADD_MACHINE.md Phase 4, ADD_NAS.md Phase 4, ADD_CONTAINER.md Phase C3)."
