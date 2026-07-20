# Sol2Docker installer

Interactive installer for [Sol2Docker](https://github.com/sol2docker/sol2docker) — a self-hosted
Docker & Swarm management UI — and, optionally, its [node agent](https://github.com/sol2docker/agent).

It detects your Docker setup, asks a handful of questions, writes a compose (or swarm stack) file,
and brings it up.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/sol2docker/installer/main/install.sh | bash
```

> **Using Swarm?** Run this on a **manager node — specifically the one whose disk should hold
> Sol2Docker's database.** The service is pinned to the host you run it from.
> See [Swarm placement](#swarm-run-this-on-the-manager-that-should-own-the-data).

Prefer to look before you leap — **recommended**, and the whole point of the dry run:

```bash
curl -fsSL https://raw.githubusercontent.com/sol2docker/installer/main/install.sh -o install.sh
less install.sh          # it's one file, on purpose
bash install.sh --dry-run
```

`--dry-run` walks the entire flow against your real machine — the detection probes genuinely run —
but writes nothing, starts nothing, and installs nothing.

## Options

| Flag | Meaning |
|---|---|
| `--dry-run` | Walk the flow and print what *would* happen. Changes nothing. |
| `--dir PATH` | Where to keep the generated compose file (skips that prompt). |
| `--yes`, `-y` | Accept every default. Will **not** auto-install Docker. |
| `--help` | Usage. |

## What it asks

**Where the deployment files live** · **topology** (standalone or swarm — defaulted from your
engine) · **whether to publish a host port** · **an additional Docker network** · **HTTPS** (none,
behind a proxy, or terminated by Sol2Docker itself) · **admin username/password** ·
**where `/data` lives** · **image tag** · **whether to deploy the node agent**.

In swarm it does *not* ask where to run — it pins to the host you run it from. See below.

The encryption key and agent token are generated for you.

If the installer installs Docker for you, it also asks whether to **enable Swarm mode** — that
choice is much easier to make now than to migrate to later.

### Swarm: run this on the manager that should own the data

> **Run the installer on a manager node — the one you want Sol2Docker to live on.**

Sol2Docker keeps its database in `/data` on whichever node runs it. So the installer pins the
service to **the host you run it from**:

```yaml
placement:
  constraints: [node.hostname == <this host>]
```

This is deliberate, and it's why the node you choose matters. With a plain
`node.role == manager` constraint, any reschedule could move the service to a *different*
manager, where it would start against an empty data directory — indistinguishable from losing
everything. Pinning removes that whole class of accident.

Practically that means:

- Run it on a **manager** (`docker stack deploy` won't work from a worker, and the installer
  refuses the swarm topology there).
- Pick the manager whose disk should hold the database, and **run it there**. It is not chosen
  for you and cannot be changed from another node.
- To move Sol2Docker later, move `/data` to the new node and edit the `node.hostname`
  constraint in the generated stack file.

If your storage is genuinely shared between managers (NFS, a cluster volume), you can relax the
constraint to `node.role == manager` by editing that file yourself.

### Running behind a reverse proxy

Two of those answers matter together. You can decline to publish a host port, and instead attach
Sol2Docker to a network your proxy is already on — the proxy then reaches it at
`http://sol2docker:8080` with nothing exposed on the host at all:

```
Publish a port on the host?                     no
Attach an additional Docker network?            yes → proxy
```

If the network doesn't exist, the installer offers to create it. In **swarm** it asks two more
things, because they can't be inferred: whether the overlay should be **attachable** (required if
your proxy runs as a plain container rather than a swarm service), and whether to **encrypt**
inter-node traffic. It also refuses to silently attach a swarm service to a local-scoped network,
which would work on the manager and quietly fail everywhere else.

Declining a port *and* declining a network leaves nothing able to reach the UI, so the installer
warns and asks you to confirm.

## What it writes

A single compose file with the environment inlined:

- In a directory you choose. The default is `/etc/sol2docker/` when run as root on Linux and
  `~/.sol2docker/` otherwise; the first prompt lets you change it, or pass `--dir PATH`.
- `docker-compose.yml` (standalone) or `docker-stack.yml` (swarm)
- Mode `0600`, because **it contains your encryption key**

That directory is also where `/data` defaults to, so one answer keeps the config and the database
together. It doubles as the installer's record of an existing install: re-running against the same
directory reuses the encryption key rather than generating a new one.

`/data` is a **bind mount by default** (`/var/lib/sol2docker` as root, otherwise `<state dir>/data`),
so the database, your stack files, and the first-boot admin password are plainly visible on the
host — easy to back up and inspect. A named Docker volume is offered as the alternative.

### Health checks

The published image ships no `HEALTHCHECK`, so the installer adds one — in **both** topologies.
Health checks work in Swarm exactly as they do standalone, and matter more there, because the
orchestrator replaces a task that stops passing:

```yaml
healthcheck:
  test:
    - CMD-SHELL
    - wget -qO- http://127.0.0.1:8080/api/v2/ping | grep -q '"ok":true'
  interval: 30s
  timeout: 5s
  retries: 3
  start_period: 30s
```

`/api/v2/ping` is the right probe — it also reports database status, so a server that is up but
can't reach its DB is correctly unhealthy.

When Sol2Docker terminates TLS the probe switches to a small Node one-liner instead. The image's
busybox `wget` has no `--no-check-certificate`, so against a self-signed or private certificate a
wget probe would fail forever — and in Swarm that means a kill-and-reschedule loop. Node is the
runtime and is always present, so it can ignore the certificate.

The **agent gets no health check**: its image is distroless (no shell, no wget) and it is
outbound-only with nothing to probe. That it is running is the signal, which is what the
installer waits for.

Manage it afterwards like any compose project:

```bash
docker compose -f ~/.sol2docker/docker-compose.yml pull
docker compose -f ~/.sol2docker/docker-compose.yml up -d
```

> **Back up that file.** Losing `SOL2DOCKER_ENCRYPTION_KEY` makes any stored registry and git
> credentials permanently undecryptable. Re-running the installer reuses an existing key rather
> than generating a new one.

## Your admin password

If you leave the password blank, Sol2Docker generates one on first boot and writes it to
`/data/initial-admin-password` (mode `0600`) — deliberately *not* to the container logs. The
installer reads it back and prints it once.

To fetch it yourself, the simplest route with the default bind mount is to read it straight off
the host:

```bash
sudo cat ~/.sol2docker/data/initial-admin-password     # or <your --dir>/data/...
```

Otherwise go through the container. Note swarm names the task `sol2docker_sol2docker.1.<id>`, not
`sol2docker`, so the two cases differ:

```bash
# standalone
docker exec sol2docker cat /data/initial-admin-password

# swarm (on the node running it)
docker exec $(docker ps -q -f label=com.docker.swarm.service.name=sol2docker_sol2docker) \
  cat /data/initial-admin-password
```

Change it after logging in, then delete the file.

## Requirements

- **Docker** — if it's missing on Linux, the installer offers to run the official
  [get.docker.com](https://get.docker.com) script, but only after you explicitly type `y`. It never
  does this under `--yes`. On macOS and Windows it prints instructions instead (Docker Desktop or
  colima; Windows must run from a WSL2 shell).
- **A `linux/amd64` engine.** That's the only platform currently published. On other engines the
  compose file still pins `linux/amd64` and it runs under emulation — slower, and unsupported.
- `openssl` for secret generation (present on essentially every system that has Docker).

## Development

```bash
make check     # shellcheck + shfmt
bash -n install.sh
```

Written against bash 3.2 so it runs on a stock macOS shell.
