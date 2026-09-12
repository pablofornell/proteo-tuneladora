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
# lxc    → machines/<parent>/CTs/LXC/<name>/
# docker → machines/<parent>/CTs/Docker/<name>/
./tools/new_machine.sh <name> --type <type> --parent <parent>
```

Add `--hosts-children` **only if this container itself hosts machines** — an LXC
running a Docker engine, for example. `bare-metal` and `vm` always get
`vault/08_CONTAINERS.md`; an `lxc`/`docker` leaf gets it only with that flag, and
`validate.sh` FAILs a machine that has children in the tree but no `08_CONTAINERS.md`.
The full CLI is `<machine-name> [--type ...] [--parent <name>] [--hosts-children]` —
there are no other flags.

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

1. **[sequential]** Complete `STATE.md` with the Phase B data. Keys stay in this
   canonical order and the enums are closed — `tools/validate.sh` FAILs on any other
   value (`SPEC.md §1.1`).

   **LXC:**

   ```yaml
   ---
   machine: <name>
   type: lxc                      # bare-metal | vm | lxc | docker
   parent: <parent>
   container_id: 106              # the Proxmox VMID, as an integer
   connection: proxyjump          # direct | proxyjump | docker-exec
   ssh_alias: <name>
   ip: 192.168.0.10
   ip_assignment: static          # static | dhcp | none
   status: running                # running | stopped | unknown
   os: "Debian 12"
   depends_on: []                 # service-level only — see below
   provides_to: []
   backups:
     configured: false
     destination: null
     last_verified: null
   auto_updates:
     configured: true
     tool: unattended-upgrades
     schedule: "daily"
   last_reconciled: 2026-09-12    # YYYY-MM-DD
   ---
   ```

   **Docker** — same shape, with these fields different:

   ```yaml
   type: docker
   container_id: my-app-container # the Docker container name, a string
   connection: docker-exec        # NOT "proxycommand-docker-exec"
   ip: null
   ip_assignment: none            # "none" = no IP of its own (host network).
                                  # Use static/dhcp when it does have one.
   ```

   - There is **no `children` key** — the directory tree is the topology, and
     `validate.sh` FAILs if you add one.
   - `depends_on` / `provides_to` are lists of mappings, and every `machine:` they
     name must resolve to a real machine folder:
     ```yaml
     depends_on:
       - machine: <parent>
         role: hypervisor
         detail: "lifecycle managed with pct on the parent"
     ```
     Record a relationship only when it is a real **service-level** dependency
     (`SPEC.md §1.2`). Plain containment is already carried by `parent` — do not
     restate the tree here just because this node has one.

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
./tools/validate.sh --machine <name>
./tools/validate.sh --machine <parent>     # the child changed the parent's records too
```

(`validate.sh` takes `--quiet` and `--machine <name>` only; a bare name is rejected
with "Unknown option". Exit status is 0 when nothing FAILed, 1 otherwise.)

Report the result and print the `/connect <name>` briefing.

Rules that apply throughout: never connect as root (hook-enforced); container
lifecycle is driven from the parent, never from inside the child; never write a
secret value into a vault file — record its location as
`<redacted YYYY-MM-DD — live value: <location>>`.
