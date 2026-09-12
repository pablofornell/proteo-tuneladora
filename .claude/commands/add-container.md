---
description: Drive workflows/ADD_CONTAINER.md to onboard an LXC or Docker container as a child machine under an existing parent. LXC is fully autonomous; Docker needs the operator for shell access.
argument-hint: <name> --parent <parent> --type lxc|docker
---

# Add container

Arguments: `$ARGUMENTS` — expected `<name> --parent <parent> --type lxc|docker`.

Parse `name`, `parent` and `type`. If any is missing, ask for it and stop; do not
guess a parent or infer a type from the name.

**Read `workflows/ADD_CONTAINER.md` now** — it is the authority; this command is the
driver around it.

## Preconditions (check before anything)

- The parent exists at `machines/<parent>/` (or `machines/<grandparent>/VMs/<parent>/`)
  and is operational. Read the parent's `STATE.md` (L1).
- LXC: the container already exists in Proxmox — `ssh <parent> "pct list"`.
- Docker: the container is already running — `ssh <parent> "docker ps"`.

If a precondition fails, report it and stop. This workflow onboards an existing
container into the repo; it does not create one.

---

## Phase A — AGENT: scaffolding

```bash
# lxc   → machines/<parent>/CTs/LXC/<name>/
# docker → machines/<parent>/CTs/Docker/<name>/
bash tools/new_machine.sh <name> --type <type> --parent <parent>
```

The script prints an SSH config snippet. **Do not add it to `~/.ssh/config` yet** —
wait for Phase B to confirm the real IP / container name.

---

## Phase B — AGENT: discover the container from the parent

All discovery runs **on the parent**. A child is never queried about its own
lifecycle.

**LXC** — record the VMID and IP:

```bash
ssh <parent> "pct list"
ssh <parent> "pct exec <vmid> -- ip -4 addr show eth0 | grep inet"
ssh <parent> "pct exec <vmid> -- systemctl is-active ssh"
```

**Docker** — record the container name/ID and its network:

```bash
ssh <parent> "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"
ssh <parent> "docker inspect <name> --format '{{json .NetworkSettings.Networks}}'"
```

These values go into `STATE.md` (`container_id`, `ip`, `ip_assignment`, `status`,
`os`), not into prose.

---

## Phase C — access

### LXC — fully autonomous, no handoff

The parent already has `tuneladora` with passwordless sudo, so the agent does all of it:

```bash
bash tools/setup_tuneladora_control.sh --machine <name> --lxc --vmid <vmid>

scp tools/setup_tuneladora_target.sh <parent>:/tmp/
ssh <parent> "bash /tmp/setup_tuneladora_target.sh \
  --pubkey '$(cat ~/.ssh/tuneladora_<name>.pub)' \
  --lxc --vmid <vmid>"
```

Then add the Phase A snippet to `~/.ssh/config` (`ProxyJump <parent>`) and test.

### ⏸ HANDOFF — Docker only: AGENT → HUMAN

Docker children use `ProxyCommand ssh <parent> docker exec -i <name> /bin/sh` — no
SSH daemon and no credentials inside the container.

Give the operator the snippet and ask them to add it and confirm:

```bash
ssh <name> "whoami"
```

**Wait for their confirmation.** If the image has `/bin/bash` rather than `/bin/sh`,
they will need the ProxyCommand adjusted — ask which shell exists.

Then check the toolchain:

```bash
ssh <name> "which bash python3 curl 2>/dev/null || true"
```

> Docker containers do **not** use the `tuneladora` user model — commands run as the
> image's default user (often `root` *inside the container*, which is not an SSH root
> login and is fine). Record the actual user in `STATE.md`/`CLAUDE.md`. Never
> `ssh root@...` — that is blocked.

---

## Phase D — AGENT: finalise

1. **[sequential]** Complete `STATE.md` with the Phase B data:
   ```yaml
   machine: <name>
   type: lxc | docker
   parent: <parent>
   container_id: <vmid | container name>
   connection: proxyjump | proxycommand-docker-exec
   ssh_alias: <name>
   ip: <ip>
   ip_assignment: <static | dhcp | dhcp-reservation>
   status: running
   os: <distro + version>
   depends_on: [<parent>, ...]
   provides_to: []
   backups: <...>
   auto_updates: <...>
   last_reconciled: <YYYY-MM-DD>
   ```
   No `children` key anywhere — the folder tree is the topology.

2. **[parallel — launch as `machine-operator` subagents in one message]**
   - Populate `CONTEXT.md` and the vault from discovery (OS, resources, network).
   - **LXC only:** harden SSH — discover the subnet dynamically, restrict
     `authorized_keys` with `from="<subnet>"`, lock the password, then verify
     `ssh <name> "whoami"` → `tuneladora`.

3. **[sequential — after 2]** Update the **parent's** `vault/08_CONTAINERS.md` with a
   row for this child: name, type, container_id, ip, connection, status, folder path.
   This is the parent's file; the child never maintains its own children list.

4. **[sequential — after 2]** Write the child's `CLAUDE.md`: the real connection
   command, the documented fallback via the parent
   (`ssh <parent> "sudo pct exec <vmid> -- <cmd>"` for LXC), critical services, ports,
   and any restart-required quirks found during setup.

5. **[sequential]** Log the setup in **both** `03_TASK_LOG.md` files — the child's and
   the parent's — via `vault-writer`.

---

## Finish

```bash
bash tools/validate.sh <name>
```

Report the result and print the `/connect <name>` briefing.

Rules that apply throughout: never connect as root (hook-enforced); container
lifecycle is driven from the parent, never from inside the child; never write a
secret value into a vault file — record its location as
`<redacted YYYY-MM-DD — live value: <location>>`.
