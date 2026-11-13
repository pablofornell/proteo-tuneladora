# Add a Deploy App — Workflow

Onboarding a **new project** onto the installed push-to-deploy system: a push to `main` is
built on the CI host, shipped to the Docker host and health-checked, with automatic rollback.
It complements [`ADD_CONTAINER.md`](ADD_CONTAINER.md), which onboards machines into the
repo; this one adds an *application* to a pipeline that already exists.

The system itself (scripts, install order, archive handling, tests) is the **ci-kit** in the
CI host's vault: `machines/<proxmox-host>/CTs/LXC/<ci-host>/TOOLS/ci-kit/` (read its
`README.md` first). This document is procedure only. In the commands below `<ci-host>` and
`<docker-host>` are the SSH aliases of the CI machine and the Docker machine, and `<ci-kit>`
is the kit directory above.

**Prerequisites**

- The kit is installed on both hosts (`<ci-kit>/README.md`, "Install order") and a previous
  app already deploys end to end. Do **not** re-run the kit's `install.sh` scripts to add an
  app: they touch every app. Install only the new files (step 4).
- `gh` is logged in on the workstation with **admin** on the repo (private-repo runners).
- The app is a container served on one TCP port (the examples assume a static site behind
  unprivileged nginx). Anything that needs data or a database also needs a `BACKUP=` policy
  in the Docker-side conf (`<ci-kit>/hef-docker/sbin/ci-deploy-run`, `parse_conf`): decide it
  with the operator before the first deploy.

Read **L1 only** to start (`SPEC.md §3`): root `CLAUDE.md`, both hosts' `STATE.md` and
`CLAUDE.md`. Take the Docker host's `CLAUDE.md` rules (build elsewhere, disk, ports) as binding.

Pick names once and use them everywhere:

| Placeholder | Meaning | Rule |
|---|---|---|
| `<app>` | pipeline app name | `^[a-z0-9-]{1,40}$` |
| `<image>` | image name (no registry) | `^[a-z0-9][a-z0-9_.-]*$` |
| `<dir>` | compose directory on the Docker host | `/opt/<something>` |
| `<service>` | compose service | one service per image, same order |
| `<port>` | host port | free on the Docker host |
| `<owner/repo>` | GitHub repository | |

---

## Step 1 — Decide private vs public (runner vs poller)

| Repo visibility | Mechanism | Why |
|---|---|---|
| **Private** | self-hosted GitHub Actions runner on the CI host, one per repo | pushes are trusted; the job runs `ci-deploy` directly and the result shows in the Actions UI |
| **Public** | `ci-poll` (systemd timer, ~2 min), no runner | on a public repo anyone can open a fork pull request, and a self-hosted runner on the LAN would execute that code. The poller only ever fetches `main` with `git ls-remote` and builds what is on it |

This is enforced, not just advised: `ci-register-runner` refuses a repo that is not
`PRIVATE`, and the runner's job-started hook fails any job whose event is not `push` /
`workflow_dispatch` or whose repo is not private. Never make a runner-backed repo public
without removing its runner first.

**When a private repo goes public**, move it to the poller and remove **both** the runner
and `.github/workflows/deploy.yml`. Left in place, the workflow creates a run on every push
that no runner picks up, so runs sit `queued` or `pending` and the repo looks undeployable
while the poller is deploying normally. A commit that changes only `.github/` is recorded
without a deploy. On a public repo, judge a deploy by `ci-deploy-run status <app>` on the
Docker host, not by the Actions UI.

---

## Step 2 — Write the recipe (kit, workstation)

Add `<ci-kit>/hef-ci/recipes/<app>/` by copying the closest existing recipe. Contract of
`build.sh <src-dir> <short7sha>`:

- `<src-dir>` is a clean checkout; refuse (exit 2) if it is not this project's checkout.
- Leave the local image `<image>:<short7sha>` with the label
  `org.opencontainers.image.revision=<full sha>`.
- Finish with `docker run --rm --read-only --tmpfs /tmp:size=16m,mode=1777 --cap-drop ALL
  --security-opt no-new-privileges:true <image>:<sha7> -t` so the image is proven under the
  production restrictions.
- Never build or install on the Docker host. Needs network on the CI host only; no secrets.

Dockerfile rules:

- Multi-stage: toolchain stage (for example `npm ci` + `npm run build`), then the runtime stage.
- **Pin every base image by digest** (`name:tag@sha256:...`), reusing the digests the other
  recipes already use so the host keeps one copy. Re-pin deliberately, never with `:latest`.
- Runtime runs unprivileged (`USER 101:101` for nginx), listens above 1024, serves
  `/healthz` (static `return 200`) next to `/`, and has a `HEALTHCHECK`.
- Add a `Dockerfile.dockerignore` allow-list (`*` then `!path` for what the build needs) so
  `.git`, `node_modules`, `dist` and docs never enter the build context. Remember what the
  type-checker or tests read (for example a `tests/` directory in `tsconfig.json`).
- Copy served files with `--chmod=0644`: a `403` on `/` is almost always an unreadable file
  for uid 101.

**Test it exactly as CI will run it**, from a clean export, as the CI user:

```bash
git archive HEAD > src.tar        # workstation, in the project
ssh <ci-host> 'sudo -n install -d -o ci-runner -g ci-runner /tmp/apptest/src /tmp/apptest/recipes'
ssh <ci-host> 'sudo -n -u ci-runner tar -C /tmp/apptest/src -xf -' < src.tar
tar -C <ci-kit>/hef-ci/recipes -cf - <app> | ssh <ci-host> 'sudo -n -u ci-runner tar -C /tmp/apptest/recipes -xf -'
ssh <ci-host> 'sudo -n -u ci-runner bash /tmp/apptest/recipes/<app>/build.sh /tmp/apptest/src <sha7>'
```

Then run the image on a spare local port with the production flags and check: `/` is `200`
(not `403`) and its body holds a string only the real app contains, `/healthz` is `200`, the
`revision` label is right, `Config.User` is not root. Remove the test image and
`/tmp/apptest` afterwards.

---

## Step 3 — Write the two app confs (kit, workstation)

Both are root-owned `KEY=VALUE` files that are **parsed, never sourced**; values may not
contain `" ' \ ` $ ; | < > ( ) { } *` (a double-quoted value is unwrapped first).

`<ci-kit>/hef-ci/apps/<app>.conf` (CI side):

```
TYPE=image
IMAGES=<image>
# Public repos only (read by ci-poll):
# POLL_REPO=https://github.com/<owner/repo>
# POLL_BRANCH=main
```

`<ci-kit>/hef-docker/apps/<app>.conf` (Docker side, the privileged half):

```
TYPE=image
DIR=<dir>
SERVICES=<service>
IMAGES=<image>
HEALTH_URLS="http://127.0.0.1:<port>/healthz http://127.0.0.1:<port>/"
HEALTH_TIMEOUT=90
BACKUP=none
```

`SERVICES` and `IMAGES` pair up one to one. Health URLs must be `http://<ipv4>:<port>/...`
and every one must answer `200`; always include `/` as well as `/healthz`, because
`/healthz` alone does not prove the site files are readable.

---

## Step 4 — Install ONLY the new files

Check the port first, **on the Docker host**, including host-network containers:

```bash
ssh <docker-host> 'ss -ltn | grep ":<port>\b" || echo free; docker ps --format "{{.Names}} {{.Ports}}" | grep "<port>" || true'
```

Install with the same owner and mode as the neighbouring files (`root:root`, `0755` for
directories and `build.sh`, `0644` for the rest). The SSH user is not root, so pipe through
`sudo tee`:

```bash
ssh <ci-host> 'sudo -n install -d -o root -g root -m 755 /opt/ci/recipes/<app>'
for f in Dockerfile Dockerfile.dockerignore nginx.conf build.sh; do        # whatever the recipe holds
  m=644; [ "$f" = build.sh ] && m=755
  ssh <ci-host> "sudo -n tee /opt/ci/recipes/<app>/$f >/dev/null && sudo -n chown root:root /opt/ci/recipes/<app>/$f && sudo -n chmod $m /opt/ci/recipes/<app>/$f" < <ci-kit>/hef-ci/recipes/<app>/$f
done
ssh <ci-host>     'sudo -n tee /opt/ci/apps/<app>.conf >/dev/null && sudo -n chown root:root /opt/ci/apps/<app>.conf && sudo -n chmod 644 /opt/ci/apps/<app>.conf' < <ci-kit>/hef-ci/apps/<app>.conf
ssh <docker-host> 'sudo -n tee /etc/ci-deploy/apps/<app>.conf >/dev/null && sudo -n chown root:root /etc/ci-deploy/apps/<app>.conf && sudo -n chmod 644 /etc/ci-deploy/apps/<app>.conf' < <ci-kit>/hef-docker/apps/<app>.conf
```

Verify by hash that the installed files equal the kit's (`sha256sum`), and that the
privileged script accepts the conf: `ssh <docker-host> 'sudo -n /usr/local/sbin/ci-deploy-run status <app>'`
must exit 0 (it fails with a precise message if the conf or the compose dir is wrong).

**Compose directory** on the Docker host (root-owned, `0755`; the file `0644`). Model it on an
existing static app:

```yaml
services:
  <service>:
    image: <image>:deployed          # the pipeline only ever moves this tag
    pull_policy: never               # never pull: the image is loaded, not pulled
    container_name: <image>
    restart: unless-stopped
    ports:
      - "<port>:8080"
    read_only: true
    tmpfs:
      - /tmp:size=16m,mode=1777
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    mem_limit: 64m
    cpus: 0.5
```

Check it with `docker compose config --quiet` in `<dir>`. Do not run `compose up`: no
`:deployed` image exists yet.

**First deploy.** The first deploy has no `:deployed` tag. `ci-deploy-run deploy` handles
that: it skips the `:previous` retag, tags `<sha7>` as `:deployed`, brings the service up and
health-checks it. `:previous` only appears from the second deploy. If the *first* deploy is
unhealthy there is nothing to roll back to: the run ends with exit 2 and
`ROLLBACK IMPOSSIBLE` (the `:deployed` tag stays on the failed image). Fix the cause, push
again; do not hand-edit tags.

**Stateful apps and secrets** (the example above is a static site; first used by
`sotel-autoclock`, 2026-11-13):

- **Data:** bind-mount `./data` under `<dir>`, never a named volume: `BACKUP=tar` with
  `BACKUP_PATHS=data` can only see paths under `DIR`. Create `data/` owned by the image's
  uid (`install -d -o <uid> -g <uid> -m 700`), as the kairos app does.
- **Secrets:** files under `<dir>/secrets/` (directory `root 0700`, each file
  `<uid>:<uid> 0400`) passed as compose `secrets:` and read through `*_FILE` variables; a
  non-secret `env_file` at `root 0600`. Send values over SSH stdin (`sudo -n tee`), never as
  arguments, and compare `sha256sum` on both ends instead of printing them. Record only the
  location in the vault.
- **Smoke test:** a non-nginx image has no `-t`. Run the binary's `--help` (or the kairos
  `--entrypoint` pattern) under the same production flags in `build.sh`.
- **Health URLs:** an app with its own login needs an unauthenticated `/healthz`, and `/`
  must return 200 without a session (a login page is fine). If the app checks the `Host`
  header, allow `127.0.0.1:<port>` (the health check) and the proxy name.
- **Must run after every boot** (for example, a service that acts on a schedule): use
  `restart: always`, not `unless-stopped`, and confirm `docker.service` is enabled and the
  Proxmox guest has `onboot: 1`.
- **Status page:** when the repo name differs from the app name, add `<app> <runner-dir>` to
  `<ci-kit>/hef-ci/status/runners.map` and install only that file on the CI host (atomic
  `install` + `mv`, compare `sha256sum`). Re-running `status/install.sh` is not needed.

---

## Step 5 — Route and DNS (not part of the kit)

The pipeline stops at `http://<docker-host-ip>:<port>`. Publishing it is the reverse proxy's
and the DNS server's job, in their own machines' vaults:

- add the route `<name>.<lan-domain>` to `<docker-host-ip>:<port>` on the reverse proxy
  (TLS terminates there; the app speaks plain HTTP),
- add the DNS record if the domain is not a wildcard,
- ask the operator before touching either: a bad proxy config affects every other site.

Test without waiting for DNS:
`curl -sk --resolve <name>.<lan-domain>:443:<proxy-ip> https://<name>.<lan-domain>/ -o /dev/null -w '%{http_code}\n'`.

---

## Step 6 — Register the repo

**Private repo**, from the workstation (not on the CI host):

```bash
bash <ci-kit>/hef-ci/bin/ci-register-runner <owner/repo>
```

It refuses a non-private repo, checks the repo's existing workflows against the trigger
allowlist, installs a runner service for that repo carrying the label the workflow template
targets (`runs-on`), wires the job-started hook, and waits until GitHub sees it online. The registration token travels over SSH stdin only. Idempotent.

**Public repo**: no runner. Seed the poller so it does not treat the current `main` as an
undeployed change (`ci-poll --seed`, see its header), and confirm the timer is active.

---

## Step 7 — Add the workflow, alone, and prove it does not deploy

Private repos only. In a **fresh temporary clone** (never the working copy):

```bash
git clone https://github.com/<owner/repo>.git /tmp/<scratch>/clone && cd /tmp/<scratch>/clone
mkdir -p .github/workflows
sed 's/APP/<app>/g' <ci-kit>/workflows/deploy.yml.tmpl > .github/workflows/deploy.yml
```

Then:

1. `sed` also rewrites the word `APP` in the template's comment (`replace APP with ...`); put
   that one word back so the comment still reads correctly.
2. `python3 <ci-kit>/workflows/check-workflow.py .github/workflows/deploy.yml` must print
   `OK`. The workflow may use only `push` and `workflow_dispatch`: never `pull_request`,
   `pull_request_target`, `workflow_run` or similar, because the runner is on the LAN.
3. Commit **only** `.github/workflows/deploy.yml` and push to `main`.
4. Confirm no run started: wait ~20 s, then `gh run list -R <owner/repo>` must be empty.
   The template has `paths-ignore: ['.github/**']`, so a push whose changed files are all under
   `.github/` never deploys; a push that also touches anything else does.

This ordering is deliberate: it proves the workflow and the runner are in place before any
real build, and that a workflow-only change cannot cause a deploy.

---

## Step 8 — The real push, and verification

Make the first real change to `main` (any non-`.github` file) and push. Then:

```bash
gh run watch "$(gh run list -R <owner/repo> --limit 1 --json databaseId --jq '.[0].databaseId')" -R <owner/repo> --exit-status
```

Verify end to end; each line is a claim that needs its own output:

- The run concluded `success` (`gh run list --json conclusion,headSha`) for the pushed SHA.
- On the Docker host, the container is `running` and `healthy`, its image is `<image>:deployed`,
  and `org.opencontainers.image.revision` equals the pushed full SHA.
- `ss -ltn` shows `<port>`; `curl` on `/` and `/healthz` returns `200` locally and through
  the route.
- The content served through the route is byte-identical to a local clean build of that
  commit (`git archive` + the project's build, compare `sha256sum`). A difference must be
  explained (different toolchain, embedded timestamp), not ignored.
- `/var/log/ci-deploy.log` on the Docker host has `<app> <sha7> load OK` and `deploy OK`.
- Every **other** container's `StartedAt` is unchanged: snapshot
  `docker ps -aq | xargs docker inspect --format '{{.Name}} {{.State.StartedAt}}'` before the
  push and diff it after. Only the new container may differ.

Then `git pull --ff-only` the project's working clone if it is clean.

---

## Rollback

- **Automatic.** If the new version is not healthy within `HEALTH_TIMEOUT`, `ci-deploy-run`
  retags `:previous` as `:deployed`, recreates the service and health-checks again. The run
  fails with `ROLLED BACK`; the old version keeps serving. Exit 2 means the rollback itself
  was unhealthy (or there was no `:previous`) and needs manual attention.
- **Intentional, preferred.** `git revert <bad-commit>` and push. It goes through the same
  build, health check and log trail. Do not re-run `deploy` for an old SHA by hand: stale
  `<sha7>` images are evicted on the next load, so that image is usually gone.
- **Emergency, Docker host only** (pipeline down). Make the previous image current and
  recreate only this service:
  `docker tag <image>:previous <image>:deployed && cd <dir> && docker compose up -d --no-build --pull never --no-deps <service>`.
  Afterwards push a real fix or revert so the repo and the host agree again. Confirm with the
  operator first if other services share the host's load.
- **Stop an app.** Lifecycle goes through the Docker host (`docker compose stop` in `<dir>`).
  Removing an app means removing its conf files on both hosts, its runner
  (`./config.sh remove` in the runner directory, using a removal token) or poller entry, the
  route, and the compose directory; each of these is destructive: ask first.

---

## Vault duty

Per `CLAUDE.md` "Vault duty after every task", on **both** the CI host and the Docker host:

1. Append a `03_TASK_LOG.md` entry per `SPEC.md §4.1` (all seven fields, **Verification**
   included, newest first; keep the newest 5 and move older ones to `vault/archive/`).
2. Docker host `STATE.md`: add the service (port, user, health) to `## Services`; bump
   `last_reconciled`. Keep L1 under ~4 KB.
3. `02_SERVICES.md` on both hosts: the app, its port, its conf paths, how it deploys
   (runner or poller), and the repo.
4. `05_SECURITY.md` on the CI host: a runner now exists for this repo (private only). On the
   reverse-proxy machine, record the new route in its vault.
5. If the container should be a tracked child machine, run [`ADD_CONTAINER.md`](ADD_CONTAINER.md)
   for it and update the parent's `08_CONTAINERS.md`.
6. If the work changed the kit (a new recipe, a fix), the kit is part of the repo: update
   `<ci-kit>/README.md` and run the unit suite (`bash <ci-kit>/tests/run-tests.sh <ci-kit> [workdir]`)
   before reporting. A change to a privileged script is described precisely in the log:
   what changed, why, which test covers it.

Secrets: the runner registration token and the deploy key are never written down. Record
**where** the live values live (`SPEC.md §5`).
