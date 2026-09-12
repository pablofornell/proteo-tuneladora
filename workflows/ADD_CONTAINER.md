# Add a Container — Workflow

Onboarding an **LXC container** or a **Docker container** as a child machine. It
complements [`ADD_MACHINE.md`](ADD_MACHINE.md), which covers bare-metal hosts and VMs.

Structure (file names, vault numbering, `STATE.md` schema) is defined by
[`SPEC.md`](../SPEC.md). This document is procedure only.

**Running this with an agent:** the driver is the
`/add-container <name> --parent <parent> --type lxc|docker` slash command
([`.claude/commands/add-container.md`](../.claude/commands/add-container.md)). Execution
on a machine belongs to the `machine-operator` subagent and vault writes to
`vault-writer` ([`.claude/agents/`](../.claude/agents/)). Those definitions own the
orchestration protocol; it is not restated here.

**Prerequisites:**

- The parent exists and is fully operational (SSH works, `tuneladora` configured). Hosts
  live at `machines/<host>/`, VMs at `machines/<grandparent>/VMs/<host>/`.
- LXC: the container already exists in Proxmox — verify with `pct list` on the parent.
- Docker: the container is already running — verify with `docker ps` on the parent.

This workflow *onboards an existing container into the repo*; it does not create one.

Read **L1 only** to start (`SPEC.md §3`): root `CLAUDE.md`, the parent's `STATE.md`, the
parent's `CLAUDE.md`. Escalate to the parent's `02_SERVICES.md` / `04_NOTES.md` only if
the task touches one of its services.

---

## Phase A — Agent: scaffolding

```bash
# LXC    → machines/<parent>/CTs/LXC/<name>/
bash tools/new_machine.sh <name> --type lxc --parent <parent>

# Docker → machines/<parent>/CTs/Docker/<name>/
bash tools/new_machine.sh <name> --type docker --parent <parent>
```

The script creates `STATE.md`, `CLAUDE.md`, `CONTEXT.md`, `REFERENCES.md`, the canonical
vault (`00_INDEX.md` … `07_UPDATES.md`), `vault/archive/` and `TOOLS/`, and prints an
`~/.ssh/config` snippet.

**`08_CONTAINERS.md` and `--hosts-children`.** LXC and Docker nodes are treated as leaves
by default, so they get no `vault/08_CONTAINERS.md`. A container that itself hosts child
machines needs one — the real case in this repo is `hef-docker`, an LXC running a Docker
engine whose containers are machines in their own right. For that, scaffold with:

```bash
bash tools/new_machine.sh <name> --type lxc --parent <parent> --hosts-children
```

`--hosts-children` is only a flag on `new_machine.sh`; if you discover later that a node
hosts children, create `vault/08_CONTAINERS.md` by hand to the same shape.
`tools/validate.sh` reports a **FAIL** for any machine that has children in the tree but
no `08_CONTAINERS.md`.

**Do not add the SSH config snippet yet** — wait until Phase B confirms the real IP or
container name.

---

## Phase B — Agent: discover the container from the parent

All discovery runs **on the parent**. A child is never asked about its own lifecycle.

### LXC

```bash
ssh <parent> "pct list"
ssh <parent> "pct exec <vmid> -- ip -4 addr show eth0 | grep inet"
ssh <parent> "pct exec <vmid> -- systemctl is-active ssh"
```

Record the **VMID** and the **container IP**. They go into `STATE.md` as `container_id`
and `ip` (`SPEC.md §1.1`) — not into prose, and not into a hand-written child list
anywhere.

### Docker

```bash
ssh <parent> "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"
ssh <parent> "docker inspect <name> --format '{{json .NetworkSettings.Networks}}'"
```

Record the **container name** (that is the `container_id` for a Docker node) and its
network. A container on the host network has no IP of its own: use `ip_assignment: none`.

---

## Phase C — Access

### LXC — fully autonomous, no handoff

The parent already has `tuneladora` with passwordless sudo, so the agent does all of it.

**C1 — generate the key (agent, locally):**

```bash
bash tools/setup_tuneladora_control.sh --machine <name> --lxc --vmid <vmid>
```

This creates `~/.ssh/tuneladora_<name>` and prints the exact command for the parent.

**C2 — bootstrap the container (agent, via the parent):**

```bash
scp tools/setup_tuneladora_target.sh <parent>:/tmp/

ssh <parent> "bash /tmp/setup_tuneladora_target.sh \
  --pubkey '$(cat ~/.ssh/tuneladora_<name>.pub)' \
  --lxc --vmid <vmid>"
```

One command: creates `tuneladora` inside the container, configures passwordless sudo,
sets up `~/.ssh/`, installs the public key, installs `openssh-server` if missing, enables
the SSH daemon, and locks the password. Idempotent.

**C3 — add the SSH config snippet (agent):** the Phase A snippet, reaching the container
as `<name>` via `ProxyJump <parent>`. `STATE.md` records `connection: proxyjump`.

### Docker — one operator handoff

Docker children use `ProxyCommand ssh <parent> docker exec -i <name> ...` — no SSH daemon
and no credentials inside the container. `STATE.md` records `connection: docker-exec`.

**C1 — verify shell access (operator):** add the Phase A snippet to `~/.ssh/config`, then

```bash
ssh <name> "whoami"
```

If the image has no `/bin/bash`, the ProxyCommand must fall back to `/bin/sh` — ask which
shell exists rather than guessing.

**C2 — check the toolchain (agent):**

```bash
ssh <name> "which bash python3 curl 2>/dev/null || true"
```

> Docker containers do **not** use the `tuneladora` user model: commands run as the
> image's default user, often `root` *inside the container*. That is not an SSH root
> login and is fine — but `ssh root@...` is never used and is blocked by a `PreToolUse`
> hook. Record the actual user in `STATE.md` and `CLAUDE.md`.

---

## Phase D — Agent: finalise

1. **Complete `STATE.md`** with the Phase B data (`SPEC.md §1`): `container_id`, `ip`,
   `ip_assignment`, `status`, `os`, `connection`, `ssh_alias`, `parent`,
   `last_reconciled`, plus `depends_on` / `provides_to` for real service relationships.
   `parent` already carries containment, so do not restate the tree in `depends_on`, and
   there is **no `children:` key** — `tools/validate.sh` fails the machine if one appears.
   Write `## Services`, `## Open Issues` and `## Read Next`; keep the file under 2 KB.

2. **Populate `CONTEXT.md` and the vault** from discovery:

   ```bash
   # LXC (standard SSH)
   ssh <name> "uname -a && cat /etc/os-release && df -h && free -h && ip -4 addr show scope global"

   # Docker (via docker exec)
   ssh <name> "uname -a 2>/dev/null; cat /etc/os-release 2>/dev/null; df -h 2>/dev/null"
   ```

3. **LXC only — harden SSH.** Discover the subnet from the operator's current network;
   never hardcode it:

   ```bash
   SUBNET=$(ip -4 addr show scope global | awk '/inet / {split($2,a,"."); print a[1]"."a[2]"."a[3]".*"}' | head -1)
   PUBKEY=$(cat ~/.ssh/tuneladora_<name>.pub)
   ssh <name> "echo 'from=\"$SUBNET\",no-agent-forwarding,no-X11-forwarding $PUBKEY' > ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
   ssh <name> "sudo passwd -l tuneladora"
   ```

   Test: `ssh -o ConnectTimeout=5 <name> "whoami"` → `tuneladora`. Re-run the `from=`
   step after any change of the operator's network.

4. **Update the parent's `vault/08_CONTAINERS.md`** (renumbered from the old
   `06_CONTAINERS.md`, `SPEC.md §2.1`) with a row for this child:

   ```markdown
   | <name> | lxc | 101 | 192.168.0.x | ProxyJump | running | machines/<host>/CTs/LXC/<name> |
   ```

   That file belongs to the parent. The child never keeps a list of its siblings or of
   itself.

5. **Write the child's `CLAUDE.md`**: the real connection command, the documented
   fallback through the parent (`ssh <parent> "sudo pct exec <vmid> -- <cmd>"` for LXC),
   critical services, ports, restart-required quirks.

6. **Log the setup** in **both** `03_TASK_LOG.md` files — the child's and the parent's
   (`SPEC.md §4.1`, seven fields, `**Verification:**` included).

Secrets: never write a live value into any file under `machines/` — record where it
lives, `<redacted YYYY-MM-DD — live value: <location>>` (`SPEC.md §5`). A `PreToolUse`
hook enforces this.

---

## Phase E — Validate and reconcile (mandatory)

```bash
tools/validate.sh --machine <name>      # must be 0 FAIL
tools/reconcile.sh --machine <name>     # drift between the record and the live container
```

`validate.sh` checks required files, `STATE.md` schema and enums, legacy leftovers
(the legacy per-machine hierarchy descriptor and the old `06_`/`07_` names are FAILs),
referential integrity of `parent` / `depends_on` / `provides_to`, a secret scan, task-log
length and the L1 budget.

`reconcile.sh` compares `STATE.md` and the parent's `08_CONTAINERS.md` against what the
hypervisor and the container actually report over SSH — including guests present in
`pct` / `docker ps` but undocumented, and machine folders with no live counterpart. It
never writes to a remote machine. `--offline` skips SSH entirely; `--json` is for cron or
a hook; `--write` touches only `last_reconciled:` and `status:`.

Run `tools/rotate_tasklog.sh --machine <name>` when the log exceeds 5 entries
(`SPEC.md §4.2`); it moves entries verbatim into `vault/archive/<YYYY>-Q<N>.md`.

---

## Quick reference: connection models

| Type | `connection` | SSH config pattern | Notes |
|------|--------------|--------------------|-------|
| `lxc` | `proxyjump` | `ProxyJump <parent>` | Standard SSH through the parent as jump host |
| `docker` | `docker-exec` | `ProxyCommand ssh <parent> docker exec -i <name> /bin/sh` | No SSH daemon inside the container |

## Quick reference: which workflow

| Machine kind | Workflow |
|--------------|----------|
| Physical server / bare-metal | [`ADD_MACHINE.md`](ADD_MACHINE.md) |
| VM (KVM/QEMU) | [`ADD_MACHINE.md`](ADD_MACHINE.md) |
| LXC container | this file |
| Docker container | this file |
| NAS, router, appliance with a proprietary OS | [`ADD_NAS.md`](ADD_NAS.md) |
