#!/usr/bin/env bash
# Sol2Docker installer — interactive deploy for the server (and optionally the node agent).
#
#   curl -fsSL https://raw.githubusercontent.com/sol2docker/installer/main/install.sh | bash
#   ./install.sh --dry-run      # walk the whole flow, change nothing
#
# Everything that MUTATES goes through run()/write_file(); everything read-only (docker info,
# arch, port probes) runs for real in both modes — so --dry-run reflects this actual machine.
#
# Written for bash 3.2 (macOS ships it): no associative arrays, no ${var,,}, no mapfile.

set -euo pipefail

VERSION="0.1.0"
SERVER_IMAGE="ghcr.io/sol2docker/sol2docker"
AGENT_IMAGE="ghcr.io/sol2docker/agent"
STACK_NAME="sol2docker"
CONTAINER_NAME="sol2docker"
# Platforms the project actually publishes today. arm64 is not built yet, so an arm64 engine
# gets an explicit amd64 pin plus an emulation warning rather than a broken pull.
PUBLISHED_PLATFORMS="linux/amd64"

DRY_RUN=0
ASSUME_YES=0
STATE_DIR_FLAG=""

# ---------------------------------------------------------------- output helpers

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$(printf '\033[1m')
  DIM=$(printf '\033[2m')
  RED=$(printf '\033[31m')
  GREEN=$(printf '\033[32m')
  YELLOW=$(printf '\033[33m')
  CYAN=$(printf '\033[36m')
  RESET=$(printf '\033[0m')
else
  BOLD=""
  DIM=""
  RED=""
  GREEN=""
  YELLOW=""
  CYAN=""
  RESET=""
fi

say() { printf '%s\n' "$*"; }
ok() { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
bad() { printf '  %s✗%s %s\n' "$RED" "$RESET" "$*"; }
info() { printf '  %s%s%s\n' "$DIM" "$*" "$RESET"; }
head2() { printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }

die() {
  printf '\n%serror:%s %s\n' "$RED" "$RESET" "$1" >&2
  exit "${2:-1}"
}

# Every mutating command goes through here. In dry-run it is printed, never executed.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %s[dry-run]%s %s\n' "$CYAN" "$RESET" "$*"
  else
    "$@"
  fi
}

# Write $2 to $1 with a restrictive umask so it is never briefly world-readable.
# The generated compose file carries the encryption key, so this matters.
write_file() {
  _wf_path="$1"
  _wf_content="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %s[dry-run]%s would write %s (mode 0600, %s lines)\n' \
      "$CYAN" "$RESET" "$_wf_path" "$(printf '%s\n' "$_wf_content" | wc -l | tr -d ' ')"
    return 0
  fi
  mkdir -p "$(dirname "$_wf_path")"
  (
    umask 077
    printf '%s\n' "$_wf_content" >"$_wf_path"
  )
}

# ---------------------------------------------------------------- prompts

# Under `curl … | bash` stdin is the SCRIPT, not the user — every `read` would hit EOF and
# silently take the default, so an "interactive" installer would answer all of its own questions
# and deploy. Bind prompts to the real terminal instead, and refuse to guess if there isn't one.
NO_TTY=0
if [ -t 0 ]; then
  exec 3<&0
elif [ -r /dev/tty ]; then
  exec 3</dev/tty 2>/dev/null || NO_TTY=1
else
  NO_TTY=1
fi

# Read one line from the terminal into the named variable. Empty on EOF/no terminal.
read_line() {
  if [ "$NO_TTY" -eq 1 ]; then
    eval "$1=''"
    return 0
  fi
  IFS= read -r _rl <&3 || _rl=""
  eval "$1=\"\$_rl\""
}

# Called once the flags are parsed: without a terminal the only honest options are --yes
# (accept documented defaults) or downloading the script and running it directly.
require_tty() {
  [ "$NO_TTY" -eq 1 ] || return 0
  [ "$ASSUME_YES" -eq 1 ] && return 0
  die "No terminal available for prompts (are you piping this into bash?).
  Either download it first:  curl -fsSL <url> -o install.sh && bash install.sh
  or accept all defaults:    curl -fsSL <url> | bash -s -- --yes"
}

# ask <var> <question> <default>
ask() {
  _a_var="$1"
  _a_q="$2"
  _a_def="${3:-}"
  if [ "$ASSUME_YES" -eq 1 ]; then
    eval "$_a_var=\"\$_a_def\""
    printf '  %s %s%s%s\n' "$_a_q" "$DIM" "${_a_def:-<blank>}" "$RESET"
    return 0
  fi
  if [ -n "$_a_def" ]; then
    printf '  %s [%s]: ' "$_a_q" "$_a_def"
  else
    printf '  %s: ' "$_a_q"
  fi
  read_line _a_reply
  [ -z "$_a_reply" ] && _a_reply="$_a_def"
  eval "$_a_var=\"\$_a_reply\""
}

# ask_secret <var> <question>  — hidden input, blank allowed
ask_secret() {
  _s_var="$1"
  _s_q="$2"
  if [ "$ASSUME_YES" -eq 1 ]; then
    eval "$_s_var=''"
    printf '  %s %s<auto>%s\n' "$_s_q" "$DIM" "$RESET"
    return 0
  fi
  printf '  %s: ' "$_s_q"
  stty -echo <&3 2>/dev/null || true
  read_line _s_reply
  stty echo <&3 2>/dev/null || true
  printf '\n'
  eval "$_s_var=\"\$_s_reply\""
}

# confirm <question> <default y|n>
confirm() {
  _c_q="$1"
  _c_def="${2:-y}"
  if [ "$ASSUME_YES" -eq 1 ]; then
    [ "$_c_def" = "y" ]
    return $?
  fi
  if [ "$_c_def" = "y" ]; then printf '  %s [Y/n]: ' "$_c_q"; else printf '  %s [y/N]: ' "$_c_q"; fi
  read_line _c_reply
  [ -z "$_c_reply" ] && _c_reply="$_c_def"
  case "$_c_reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# choose <var> <question> <default> <opt1> <opt2> ...
choose() {
  _ch_var="$1"
  _ch_q="$2"
  _ch_def="$3"
  shift 3
  if [ "$ASSUME_YES" -eq 1 ]; then
    eval "$_ch_var=\"\$_ch_def\""
    printf '  %s %s%s%s\n' "$_ch_q" "$DIM" "$_ch_def" "$RESET"
    return 0
  fi
  printf '  %s\n' "$_ch_q"
  _ch_i=1
  for _ch_o in "$@"; do
    if [ "$_ch_o" = "$_ch_def" ]; then
      printf '    %s) %s %s(default)%s\n' "$_ch_i" "$_ch_o" "$DIM" "$RESET"
    else printf '    %s) %s\n' "$_ch_i" "$_ch_o"; fi
    _ch_i=$((_ch_i + 1))
  done
  printf '  choose [%s]: ' "$_ch_def"
  read_line _ch_reply
  [ -z "$_ch_reply" ] && {
    eval "$_ch_var=\"\$_ch_def\""
    return 0
  }
  # accept either the number or the literal name
  _ch_i=1
  for _ch_o in "$@"; do
    if [ "$_ch_reply" = "$_ch_i" ] || [ "$_ch_reply" = "$_ch_o" ]; then
      eval "$_ch_var=\"\$_ch_o\""
      return 0
    fi
    _ch_i=$((_ch_i + 1))
  done
  warn "not an option — using $_ch_def"
  eval "$_ch_var=\"\$_ch_def\""
}

# Show just enough of a secret to be recognisable in the review screen.
mask() {
  _m="$1"
  if [ -z "$_m" ]; then
    printf '<none>'
    return
  fi
  printf '%s…%s' "$(printf '%s' "$_m" | cut -c1-4)" "$(printf '%s' "$_m" | tail -c 4)"
}

# ---------------------------------------------------------------- preflight

HOST_OS=""
ENGINE_PLATFORM=""
SWARM_STATE=""
COMPOSE_CMD=""
EXISTING=""
SELF_NODE=""
DOCKER_SOCK="/var/run/docker.sock"
SELINUX=0
DOCKER_JUST_INSTALLED=0

detect_host_os() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Linux) HOST_OS="linux" ;;
    Darwin) HOST_OS="macos" ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS="windows" ;;
    *) HOST_OS="unknown" ;;
  esac
}

install_docker_offer() {
  head2 "Docker is not installed"
  case "$HOST_OS" in
    linux)
      info "The official convenience script can install it: https://get.docker.com"
      info "It runs as root and executes code fetched from the network."
      # Deliberately NOT honouring --yes here: accepting prompt defaults is not consent to
      # escalate privileges unattended.
      if [ "$ASSUME_YES" -eq 1 ]; then
        die "Docker is missing. Install it, then re-run. (--yes will not auto-install Docker.)"
      fi
      if confirm "Install Docker now with the official script?" n; then
        if [ "$(id -u)" -eq 0 ]; then
          run sh -c 'curl -fsSL https://get.docker.com | sh'
          run systemctl enable --now docker
        else
          run sh -c 'curl -fsSL https://get.docker.com | sudo sh'
          run sudo systemctl enable --now docker
          run sudo usermod -aG docker "$(id -un)"
          warn "You were added to the 'docker' group — log out and back in (or run: newgrp docker)."
        fi
        DOCKER_JUST_INSTALLED=1
      else
        die "Docker is required. Install it, then re-run this script."
      fi
      ;;
    macos)
      info "Docker Desktop:  brew install --cask docker    (then launch it once)"
      info "or colima:       brew install colima docker docker-compose && colima start"
      die "Docker is required. Install it, then re-run this script."
      ;;
    windows)
      info "Install Docker Desktop with the WSL2 backend, then re-run this script from inside WSL2."
      die "Docker is required (run this installer from a WSL2 shell, not Git Bash)."
      ;;
    *)
      die "Docker is required, and this platform wasn't recognised."
      ;;
  esac
}

# A freshly installed engine is never in swarm mode, so the choice is genuinely open here —
# and it's much easier to decide now than to migrate later.
offer_swarm_init() {
  [ "$DOCKER_JUST_INSTALLED" -eq 1 ] || return 0
  [ "$SWARM_STATE" = "standalone" ] || return 0

  head2 "Swarm mode"
  info "Standalone manages this one host. Swarm adds services, stacks, and multi-node scheduling"
  info "— and lets the node agent run everywhere automatically. You can enable it later."
  if ! confirm "Enable Swarm mode on this host?" n; then
    return 0
  fi
  if ! swarm_init; then
    warn "Swarm was not initialised — continuing in standalone mode."
    return 0
  fi
  SWARM_STATE="manager"
  ok "swarm mode enabled (this host is now a manager)"
}

# `docker swarm init` fails on hosts with several addresses until told which to advertise.
swarm_init() {
  if [ "$DRY_RUN" -eq 1 ]; then
    run docker swarm init
    return 0
  fi
  if docker swarm init >/dev/null 2>&1; then
    return 0
  fi
  _init_err=$(docker swarm init 2>&1 || true)
  case "$_init_err" in
    *"could not choose an IP address"* | *"must specify"* | *"--advertise-addr"*)
      warn "This host has several addresses, so Docker needs to be told which to advertise."
      ask _adv "Advertise address (IP or interface)" ""
      [ -n "$_adv" ] || return 1
      docker swarm init --advertise-addr "$_adv" >/dev/null 2>&1 || return 1
      return 0
      ;;
    *)
      warn "swarm init failed: $(printf '%s' "$_init_err" | head -n1)"
      return 1
      ;;
  esac
}

# manager | worker | standalone
detect_swarm_state() {
  _control=$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null || echo false)
  _node=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive)
  if [ "$_control" = "true" ]; then
    SWARM_STATE="manager"
  elif [ "$_node" = "active" ]; then
    SWARM_STATE="worker"
  else SWARM_STATE="standalone"; fi
}

port_in_use() {
  _p="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$_p" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$_p\$" && return 0
  fi
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$_p" >/dev/null 2>&1 && return 0
  fi
  return 1
}

preflight() {
  head2 "Preflight"
  detect_host_os
  ok "host: $HOST_OS ($(uname -m 2>/dev/null || echo '?'))"

  command -v docker >/dev/null 2>&1 || install_docker_offer
  command -v docker >/dev/null 2>&1 || die "Docker still not on PATH."
  ok "docker CLI: $(docker --version 2>/dev/null | head -n1)"

  # Daemon reachable? Distinguish "not running" from "no permission" — different fixes.
  if ! docker info >/dev/null 2>&1; then
    _err=$(docker info 2>&1 >/dev/null || true)
    case "$_err" in
      *"permission denied"*)
        bad "cannot talk to the Docker daemon: permission denied"
        die "Add yourself to the docker group:  sudo usermod -aG docker \$USER && newgrp docker"
        ;;
      *)
        bad "cannot connect to the Docker daemon"
        die "Start Docker (Docker Desktop, or: sudo systemctl start docker) and re-run."
        ;;
    esac
  fi
  ok "docker daemon: reachable"

  # Engine platform, NOT host uname — Docker Desktop on Apple Silicon emulates amd64, which a
  # host-only check would miss entirely.
  ENGINE_PLATFORM=$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}' 2>/dev/null || echo "")
  [ -n "$ENGINE_PLATFORM" ] || ENGINE_PLATFORM="linux/amd64"
  case " $PUBLISHED_PLATFORMS " in
    *" $ENGINE_PLATFORM "*)
      ok "engine platform: $ENGINE_PLATFORM"
      ;;
    *)
      warn "engine platform: $ENGINE_PLATFORM — images are published for $PUBLISHED_PLATFORMS only"
      info "The compose file will pin linux/amd64; it will run under emulation (slower, unsupported)."
      ;;
  esac

  # Which engine are we actually talking to? A non-default context (or DOCKER_HOST) silently
  # points everything at another machine — worth stating rather than discovering afterwards.
  _ctx=$(docker context show 2>/dev/null || echo "")
  if [ -n "${DOCKER_HOST:-}" ]; then
    warn "DOCKER_HOST is set to ${DOCKER_HOST} — deploying there, not necessarily to this machine"
  elif [ -n "$_ctx" ] && [ "$_ctx" != "default" ]; then
    _ctx_host=$(docker context inspect "$_ctx" --format '{{.Endpoints.docker.Host}}' 2>/dev/null || echo "?")
    ok "docker context: $_ctx ($_ctx_host)"
  fi

  # Rootless Docker puts its socket under XDG_RUNTIME_DIR, and that is the path the daemon
  # itself sees. VM-backed engines (Docker Desktop, colima) keep /var/run/docker.sock inside
  # the VM regardless of where the CLI's socket lives on the host, so only rootless differs.
  if docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q rootless; then
    DOCKER_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock"
    warn "rootless Docker detected — mounting ${DOCKER_SOCK}"
  fi

  # SELinux denies a container write access to a bind mount without a relabel.
  if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
    SELINUX=1
    ok "SELinux enforcing — bind mounts will be labelled :z"
  fi

  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
    ok "compose plugin: $(docker compose version --short 2>/dev/null || echo present)"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
    warn "using legacy docker-compose v1"
  else
    COMPOSE_CMD=""
    warn "no compose plugin found (only the swarm topology will be available)"
  fi

  SELF_NODE=$(docker info --format '{{.Name}}' 2>/dev/null || echo "")
  detect_swarm_state
  offer_swarm_init # only fires right after we installed Docker ourselves
  case "$SWARM_STATE" in
    manager) ok "swarm: this node is a manager" ;;
    worker) warn "swarm: this node is a WORKER — it cannot host the server's data volume" ;;
    standalone) ok "swarm: not enabled (standalone engine)" ;;
  esac

  # Host capacity, read from the engine (so it reflects where the containers actually run —
  # e.g. the Docker Desktop / colima VM, not the laptop). Used in render() to decide whether the
  # resource caps are affordable. Integer bytes → MiB; guard against non-numeric output.
  _mem_bytes=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
  _ncpu=$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)
  case "$_mem_bytes" in ''|*[!0-9]*) _mem_bytes=0 ;; esac
  case "$_ncpu" in ''|*[!0-9]*) _ncpu=0 ;; esac
  HOST_MEM_MB=$(( _mem_bytes / 1048576 ))
  HOST_NCPU=$_ncpu
  ok "host capacity: ${HOST_MEM_MB} MiB RAM, ${HOST_NCPU} CPU (engine)"

}

# Existing install? The deployment directory is the source of truth, not docker ps: a container
# can be removed while the encryption key survives, and that key must never be regenerated.
# Runs once the directory is known, so it can't be folded into preflight.
detect_existing() {
  if [ -f "$STATE_DIR/docker-compose.yml" ] || [ -f "$STATE_DIR/docker-stack.yml" ]; then
    EXISTING="config"
    warn "existing config found at $STATE_DIR — the encryption key will be reused, not regenerated"
  elif docker ps -a --filter "name=^/${CONTAINER_NAME}\$" --format '{{.Names}}' 2>/dev/null | grep -q .; then
    EXISTING="container"
    warn "a container named '$CONTAINER_NAME' already exists"
  elif docker stack ls --format '{{.Name}}' 2>/dev/null | grep -qx "$STACK_NAME"; then
    EXISTING="stack"
    warn "a swarm stack named '$STACK_NAME' already exists"
  else
    ok "no existing Sol2Docker install detected"
  fi
}

# ---------------------------------------------------------------- config gathering

TOPOLOGY=""
PUBLISH_PORT=""
PORT=""
EXTRA_NET=""
EXTRA_NET_EXISTS=0
EXTRA_NET_ATTACHABLE=""
EXTRA_NET_ENCRYPTED=""
PLACEMENT_NODE=""
TLS_MODE=""
TLS_CERT=""
TLS_KEY=""
ADMIN_USER=""
ADMIN_PASS=""
ENC_KEY=""
AGENT_TOKEN=""
DATA_MODE=""
DATA_PATH=""
IMAGE_TAG=""
WITH_AGENT=0
PIN_PLATFORM=""

# Resource caps. Safe ceilings, not requirements — sol2docker's real footprint is tiny (server
# ~50 MiB steady / ~165 MiB peak at boot, agent ~5 MiB). Only pinned when the engine host can
# afford them (see the LIMITS_OK decision in render()); otherwise we deploy uncapped.
LIMITS_OK=0
HOST_MEM_MB=0
HOST_NCPU=0
SERVER_CPU_LIMIT="1.0"
SERVER_MEM_LIMIT="512M"
SERVER_MEM_RES="128M"
AGENT_CPU_LIMIT="0.5"
AGENT_MEM_LIMIT="128M"
AGENT_MEM_RES="32M"

gen_key() { openssl rand -base64 32 2>/dev/null | tr -d '\n'; }
gen_token() { openssl rand -hex 24 2>/dev/null | tr -d '\n'; }

existing_value() {
  # Pull a value back out of a previously generated compose file so re-runs are non-destructive.
  _ev_key="$1"
  for _ev_f in "$STATE_DIR/docker-compose.yml" "$STATE_DIR/docker-stack.yml"; do
    [ -f "$_ev_f" ] || continue
    _ev_v=$(grep -E "^[[:space:]]*${_ev_key}:" "$_ev_f" 2>/dev/null | head -n1 |
      sed -E 's/^[^:]*:[[:space:]]*//; s/^"//; s/"$//')
    [ -n "$_ev_v" ] && {
      printf '%s' "$_ev_v"
      return 0
    }
  done
  return 1
}

# Sol2Docker is always pinned to the host the installer runs on. Its database lives on that
# node (a bind mount or a node-local volume), so a bare `node.role == manager` constraint would
# let a reschedule move it to another manager and find an EMPTY data directory — which reads as
# total data loss. Run the installer on the manager that should own the data.
pin_placement() {
  [ "$TOPOLOGY" = "swarm" ] || return 0
  PLACEMENT_NODE="$SELF_NODE"
  if [ -n "$PLACEMENT_NODE" ]; then
    info "Sol2Docker will be pinned to this node ('$PLACEMENT_NODE')."
  else
    warn "Could not determine this node's name — falling back to any manager."
  fi
}

# Optionally attach Sol2Docker to a second Docker network — almost always a reverse proxy's,
# so the proxy can reach it without anything being published on the host. The network is only
# created (with approval) when it doesn't already exist.
gather_network() {
  if ! confirm "Attach Sol2Docker to an additional Docker network (e.g. your reverse proxy's)?" n; then
    return 0
  fi
  ask EXTRA_NET "Network name" "proxy"
  [ -n "$EXTRA_NET" ] || {
    EXTRA_NET=""
    return 0
  }

  if docker network inspect "$EXTRA_NET" >/dev/null 2>&1; then
    EXTRA_NET_EXISTS=1
    _net_driver=$(docker network inspect "$EXTRA_NET" --format '{{.Driver}}' 2>/dev/null || echo "?")
    _net_scope=$(docker network inspect "$EXTRA_NET" --format '{{.Scope}}' 2>/dev/null || echo "?")
    ok "network '$EXTRA_NET' exists (driver=$_net_driver, scope=$_net_scope)"
    # A swarm service can only span nodes on a swarm-scoped network. A local bridge will
    # attach on the manager and quietly fail to work anywhere else.
    if [ "$TOPOLOGY" = "swarm" ] && [ "$_net_scope" != "swarm" ]; then
      warn "'$EXTRA_NET' is $_net_scope-scoped — swarm services need a swarm-scoped (overlay) network."
      confirm "Use it anyway?" n || die "Pick a swarm-scoped network, or let the installer create one."
    fi
    return 0
  fi

  warn "network '$EXTRA_NET' does not exist"
  if ! confirm "Create it?" y; then
    die "'$EXTRA_NET' must exist before the deploy can attach to it."
  fi

  # Swarm needs more than a name: the driver has to be overlay to span nodes, and whether
  # plain (non-service) containers may join is a real decision — a reverse proxy run as an
  # ordinary container can't attach unless the network is attachable.
  if [ "$TOPOLOGY" = "swarm" ]; then
    info "In swarm the network must be an overlay to span nodes."
    choose EXTRA_NET_ATTACHABLE "Allow standalone containers to attach? (needed if your proxy isn't a swarm service)" "yes" yes no
    choose EXTRA_NET_ENCRYPTED "Encrypt traffic between nodes? (IPsec; some overhead)" "no" no yes
  fi
}

gather() {
  head2 "Configuration"

  # --- where the deployment files live. Asked first because everything else keys off it: the
  # existing-install check, the encryption key we may reuse, and the default bind-mount path.
  if [ -z "$STATE_DIR_FLAG" ]; then
    ask STATE_DIR "Where should the deployment files live?" "$STATE_DIR"
  fi
  case "$STATE_DIR" in
    "~"/*) STATE_DIR="$HOME/${STATE_DIR#"~/"}" ;; # a typed ~ isn't expanded by read
  esac
  if [ -e "$STATE_DIR" ] && [ ! -d "$STATE_DIR" ]; then
    die "$STATE_DIR exists and is not a directory."
  fi
  if [ -d "$STATE_DIR" ] && [ ! -w "$STATE_DIR" ]; then
    die "$STATE_DIR is not writable. Re-run with sudo, or choose another directory."
  fi
  if [ ! -d "$STATE_DIR" ]; then
    _parent=$(dirname "$STATE_DIR")
    [ -d "$_parent" ] && [ -w "$_parent" ] || [ "$DRY_RUN" -eq 1 ] ||
      die "cannot create $STATE_DIR — $_parent is missing or not writable."
  fi
  detect_existing

  # --- topology
  _topo_default="standalone"
  [ "$SWARM_STATE" = "manager" ] && _topo_default="swarm"
  choose TOPOLOGY "Deployment topology" "$_topo_default" standalone swarm
  if [ "$TOPOLOGY" = "swarm" ] && [ "$SWARM_STATE" = "worker" ]; then
    die "This node is a swarm worker. Run the installer on a manager — the server's data volume is node-local."
  fi
  if [ "$TOPOLOGY" = "standalone" ] && [ -z "$COMPOSE_CMD" ]; then
    die "The standalone topology needs the compose plugin. Install it, or choose 'swarm'."
  fi

  # --- placement: always this host (swarm only)
  pin_placement

  # --- port. Not publishing is a real deployment shape: a reverse proxy on a shared Docker
  # network reaches the container directly, and nothing needs to be exposed on the host.
  choose PUBLISH_PORT "Publish a port on the host?" "yes" yes no
  if [ "$PUBLISH_PORT" = "yes" ]; then
    ask PORT "Port to publish Sol2Docker on" "8080"
    if port_in_use "$PORT" && [ -z "$EXISTING" ]; then
      warn "port $PORT already has a listener — the deploy will fail unless that's freed"
    fi
  else
    PORT=""
    info "Nothing will be exposed on the host. Sol2Docker will be reachable only from containers"
    info "on a shared Docker network, at http://sol2docker:8080."
  fi

  # --- extra network (typically the reverse proxy's)
  gather_network

  # --- TLS
  choose TLS_MODE "How should HTTPS be handled?" "none" none behind-proxy terminate-here
  case "$TLS_MODE" in
    terminate-here)
      ask TLS_CERT "Path to the certificate (fullchain PEM)" "/etc/sol2docker/certs/fullchain.pem"
      ask TLS_KEY "Path to the private key PEM" "/etc/sol2docker/certs/privkey.pem"
      if [ "$DRY_RUN" -eq 0 ]; then
        [ -r "$TLS_CERT" ] || die "cannot read certificate: $TLS_CERT"
        [ -r "$TLS_KEY" ] || die "cannot read private key: $TLS_KEY"
      fi
      ;;
    behind-proxy)
      info "Sets SECURE_COOKIES + TRUST_PROXY. Only correct if a TLS-terminating proxy is really in front."
      ;;
  esac

  # --- admin
  ask ADMIN_USER "Admin username" "admin"
  ask_secret ADMIN_PASS "Admin password (blank = generated on first boot)"

  # --- encryption key: never regenerate over an existing install
  if ENC_KEY=$(existing_value SOL2DOCKER_ENCRYPTION_KEY); then
    ok "reusing the existing encryption key from $STATE_DIR"
  else
    ENC_KEY=$(gen_key)
    [ -n "$ENC_KEY" ] || die "openssl is required to generate the encryption key."
  fi

  # --- data
  # Bind mount by default: the database, stack files and the first-boot admin password are
  # then plainly visible on the host, which makes them easy to back up and inspect. A named
  # volume hides all of that inside Docker's storage area.
  choose DATA_MODE "Where should /data live?" "bind-mount" bind-mount named-volume
  if [ "$DATA_MODE" = "bind-mount" ]; then
    # /var/lib needs root; anywhere else, keep it beside the generated compose file.
    if [ "$(id -u)" -eq 0 ] && [ "$HOST_OS" = "linux" ]; then
      _data_default="/var/lib/sol2docker"
    else
      _data_default="$STATE_DIR/data"
    fi
    ask DATA_PATH "Host path for /data" "$_data_default"
  fi

  # --- image tag. Check it resolves before deploying: an unpublished tag otherwise surfaces as
  # a pull failure buried in service logs, long after the config has been written.
  ask IMAGE_TAG "Image tag" "beta"
  if docker manifest inspect "${SERVER_IMAGE}:${IMAGE_TAG}" >/dev/null 2>&1; then
    ok "${SERVER_IMAGE}:${IMAGE_TAG} exists"
  else
    warn "couldn't confirm ${SERVER_IMAGE}:${IMAGE_TAG} exists in the registry."
    info "It may not be published yet, or this host can't reach ghcr.io."
    confirm "Continue anyway?" y || die "Nothing was changed."
  fi

  # --- agent
  head2 "Node agent (optional)"
  info "Adds live per-node CPU/RAM/disk, cross-node image inventory, per-node prune results,"
  info "and worker-node events. Sol2Docker works fully without it."
  if confirm "Deploy the node agent too?" y; then
    WITH_AGENT=1
    if ! AGENT_TOKEN=$(existing_value SOL2DOCKER_AGENT_BOOTSTRAP_TOKEN); then
      AGENT_TOKEN=$(gen_token)
    fi
  fi

  # Pin the platform explicitly so Docker never guesses. Only amd64 is published today; once
  # arm64 images ship this picks up the detected value automatically.
  case " $PUBLISHED_PLATFORMS " in
    *" $ENGINE_PLATFORM "*) PIN_PLATFORM="$ENGINE_PLATFORM" ;;
    *) PIN_PLATFORM="linux/amd64" ;;
  esac

  # No published port and no shared network means nothing outside the stack can reach the UI —
  # almost certainly not what was intended.
  if [ "$PUBLISH_PORT" = "no" ] && [ -z "$EXTRA_NET" ]; then
    warn "No host port and no additional network — you won't be able to open the UI from a browser."
    info "Either publish a port, or attach a network your reverse proxy is also on."
    confirm "Continue anyway?" n || die "Nothing was changed."
  fi
}

# ---------------------------------------------------------------- render

COMPOSE_FILE=""
COMPOSE_BODY=""

# Appends one `NAME: "value"` line to $_svc_env. Written with a literal newline inside the
# assignment rather than $(printf ...) — command substitution strips trailing newlines, which
# silently collapses the whole environment block onto one line and produces invalid YAML.
add_env() {
  _svc_env="${_svc_env}      $1: \"$2\"
"
}

render() {
  # Decide whether to pin resource caps. Require real headroom over the caps we'd impose (the
  # sum of memory limits plus room for the OS/daemon) and at least one full CPU; otherwise skip
  # them and deploy uncapped — "run with whatever the host has". A host that doesn't report
  # MemTotal (HOST_MEM_MB=0) also falls through to uncapped, which is the safe default.
  _need_mb=768                                    # 512M server cap + 256M OS/daemon headroom
  [ "$WITH_AGENT" -eq 1 ] && _need_mb=$(( _need_mb + 128 ))   # + 128M agent cap
  if [ "$HOST_MEM_MB" -ge "$_need_mb" ] && [ "$HOST_NCPU" -ge 1 ]; then
    LIMITS_OK=1
  else
    LIMITS_OK=0
  fi

  # The `resources:` sub-block (6-space indent, sits under a service's `deploy:`) for each
  # service — empty when caps are skipped. docker compose v2 honours deploy.resources.limits in
  # standalone too, so the same block works for compose and swarm.
  _res_server=""
  _res_agent=""
  _deploy_server=""
  _deploy_agent=""
  if [ "$LIMITS_OK" -eq 1 ]; then
    _res_server="      resources:
        limits:
          cpus: \"${SERVER_CPU_LIMIT}\"
          memory: ${SERVER_MEM_LIMIT}
        reservations:
          memory: ${SERVER_MEM_RES}
"
    _res_agent="      resources:
        limits:
          cpus: \"${AGENT_CPU_LIMIT}\"
          memory: ${AGENT_MEM_LIMIT}
        reservations:
          memory: ${AGENT_MEM_RES}
"
    # Standalone services have no other `deploy:` keys, so they need the wrapper too.
    _deploy_server="    deploy:
${_res_server}"
    _deploy_agent="    deploy:
${_res_agent}"
    info "resource limits: server ${SERVER_MEM_LIMIT}/${SERVER_CPU_LIMIT}CPU$([ "$WITH_AGENT" -eq 1 ] && printf ', agent %s/%sCPU' "$AGENT_MEM_LIMIT" "$AGENT_CPU_LIMIT")"
  else
    info "resource limits: skipped — host ${HOST_MEM_MB} MiB / ${HOST_NCPU} CPU below the ${_need_mb} MiB needed; deploying uncapped"
  fi

  _svc_env=""
  add_env SOL2DOCKER_ENCRYPTION_KEY "$ENC_KEY"
  add_env SOL2DOCKER_ADMIN_USER "$ADMIN_USER"
  [ -n "$ADMIN_PASS" ] && add_env SOL2DOCKER_ADMIN_PASSWORD "$ADMIN_PASS"
  [ "$WITH_AGENT" -eq 1 ] && add_env SOL2DOCKER_AGENT_BOOTSTRAP_TOKEN "$AGENT_TOKEN"

  case "$TLS_MODE" in
    terminate-here)
      add_env SOL2DOCKER_TLS on
      add_env SOL2DOCKER_TLS_CERT /certs/fullchain.pem
      add_env SOL2DOCKER_TLS_KEY /certs/privkey.pem
      ;;
    behind-proxy)
      add_env SOL2DOCKER_SECURE_COOKIES true
      add_env SOL2DOCKER_TRUST_PROXY true
      ;;
  esac

  # volumes
  _z=""
  [ "$SELINUX" -eq 1 ] && _z=":z"
  _svc_vols="      - ${DOCKER_SOCK}:/var/run/docker.sock
"
  if [ "$DATA_MODE" = "bind-mount" ]; then
    _svc_vols="${_svc_vols}      - ${DATA_PATH}:/data${_z}
"
  else
    _svc_vols="${_svc_vols}      - sol2docker-data:/data
"
  fi
  if [ "$TLS_MODE" = "terminate-here" ]; then
    _svc_vols="${_svc_vols}      - ${TLS_CERT}:/certs/fullchain.pem:ro
      - ${TLS_KEY}:/certs/privkey.pem:ro
"
  fi

  # agent service — SOL2DOCKER_INSECURE_HTTP is REQUIRED here: the agent refuses plain http to a
  # non-loopback host, and 'sol2docker' is a service name, not loopback. Without it the agent
  # crash-loops (the README's own stack has this bug).
  _agent_block=""
  if [ "$WITH_AGENT" -eq 1 ]; then
    if [ "$TOPOLOGY" = "swarm" ]; then
      _agent_block="
  agent:
    image: ${AGENT_IMAGE}:${IMAGE_TAG}
    platform: ${PIN_PLATFORM}
    environment:
      SOL2DOCKER_SERVER_URL: \"http://sol2docker:${PORT}\"
      SOL2DOCKER_AGENT_TOKEN: \"${AGENT_TOKEN}\"
      SOL2DOCKER_INSECURE_HTTP: \"true\"
      SOL2DOCKER_NODE_NAME: \"{{.Node.Hostname}}\"
    volumes:
      - ${DOCKER_SOCK}:/var/run/docker.sock:ro
    networks: [sol2docker]
    deploy:
      mode: global
      restart_policy:
        condition: any
${_res_agent}"
    else
      _agent_block="
  agent:
    image: ${AGENT_IMAGE}:${IMAGE_TAG}
    platform: ${PIN_PLATFORM}
    container_name: sol2docker-agent
    environment:
      SOL2DOCKER_SERVER_URL: \"http://sol2docker:8080\"
      SOL2DOCKER_AGENT_TOKEN: \"${AGENT_TOKEN}\"
      SOL2DOCKER_INSECURE_HTTP: \"true\"
    volumes:
      - ${DOCKER_SOCK}:/var/run/docker.sock:ro
    depends_on: [sol2docker]
    restart: unless-stopped
${_deploy_agent}"
    fi
  fi

  # Omitted entirely when nothing is published — the container is then reachable only over a
  # shared Docker network, which is the point of that option.
  _ports_block=""
  [ "$PUBLISH_PORT" = "yes" ] && _ports_block="    ports: [\"${PORT}:8080\"]
"

  # Health check. The image ships no HEALTHCHECK, so this is what makes `docker ps` report
  # health and — in swarm, where it works just the same — lets the orchestrator replace a task
  # that has stopped serving. /api/v2/ping is the right probe: it also reports DB status.
  #
  # busybox wget can't skip certificate verification (no --no-check-certificate in this build),
  # so once the server terminates TLS a wget probe would fail forever against a self-signed or
  # private cert — and swarm would kill-and-reschedule in a loop. Node is the runtime and is
  # always present, so use it for the TLS case where it can ignore the cert.
  if [ "$TLS_MODE" = "terminate-here" ]; then
    _probe="node -e \"require('https').get({host:'127.0.0.1',port:8080,path:'/api/v2/ping',rejectUnauthorized:false},r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))\""
  else
    _probe="wget -qO- http://127.0.0.1:8080/api/v2/ping | grep -q '\"ok\":true'"
  fi
  # Block sequence, not the [\"CMD-SHELL\", \"…\"] flow form: both probes contain quotes, and
  # inside a flow sequence those terminate the string and produce invalid YAML.
  _health_block="    healthcheck:
      test:
        - CMD-SHELL
        - ${_probe}
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
"

  # Network wiring. In standalone, naming any network on a service suppresses compose's implicit
  # default — so 'default' must be listed explicitly, or the agent can no longer resolve the
  # server by name.
  _extra_net_decl=""
  if [ -n "$EXTRA_NET" ]; then
    _extra_net_decl="  ${EXTRA_NET}:
    external: true
"
  fi
  if [ "$TOPOLOGY" = "swarm" ]; then
    # Built with if/else, not $(... && ...): a command substitution that exits non-zero makes
    # the whole assignment non-zero, which set -e turns into a silent early exit.
    _net_list="sol2docker"
    if [ -n "$EXTRA_NET" ]; then
      _net_list="sol2docker, ${EXTRA_NET}"
    fi
    _svc_nets="    networks: [${_net_list}]
"
  elif [ -n "$EXTRA_NET" ]; then
    _svc_nets="    networks: [default, ${EXTRA_NET}]
"
  else
    _svc_nets=""
  fi

  # Pin to the chosen node so a reschedule can't strand the service on a manager whose /data
  # is empty. 'any-manager' is only correct when storage is shared between managers.
  if [ -n "$PLACEMENT_NODE" ] && [ "$PLACEMENT_NODE" != "any-manager" ]; then
    _placement_constraint="node.hostname == ${PLACEMENT_NODE}"
  else
    _placement_constraint="node.role == manager"
  fi

  _header="# Generated by the Sol2Docker installer v${VERSION} on $(date -u '+%Y-%m-%dT%H:%M:%SZ').
# CONTAINS SECRETS (encryption key, agent token) — keep this file at mode 0600.
# Losing SOL2DOCKER_ENCRYPTION_KEY makes stored registry/git credentials undecryptable."

  if [ "$TOPOLOGY" = "swarm" ]; then
    COMPOSE_FILE="$STATE_DIR/docker-stack.yml"
    COMPOSE_BODY="${_header}
services:
  sol2docker:
    image: ${SERVER_IMAGE}:${IMAGE_TAG}
    platform: ${PIN_PLATFORM}
${_ports_block}    environment:
${_svc_env}    volumes:
${_svc_vols}${_svc_nets}${_health_block}    deploy:
      replicas: 1
      placement:
        constraints: [${_placement_constraint}]
      restart_policy:
        condition: any
${_res_server}${_agent_block}
networks:
  sol2docker:
    driver: overlay
    attachable: true
${_extra_net_decl}"
  else
    COMPOSE_FILE="$STATE_DIR/docker-compose.yml"
    COMPOSE_BODY="${_header}
services:
  sol2docker:
    image: ${SERVER_IMAGE}:${IMAGE_TAG}
    platform: ${PIN_PLATFORM}
    container_name: ${CONTAINER_NAME}
${_ports_block}    environment:
${_svc_env}    volumes:
${_svc_vols}${_svc_nets}${_health_block}    restart: unless-stopped
${_deploy_server}${_agent_block}"
    if [ -n "$EXTRA_NET" ]; then
      COMPOSE_BODY="${COMPOSE_BODY}
networks:
${_extra_net_decl}"
    fi
  fi

  # Only declare the named volume when we actually use one.
  if [ "$DATA_MODE" = "named-volume" ]; then
    COMPOSE_BODY="${COMPOSE_BODY}
volumes:
  sol2docker-data:
"
  fi
}

# ---------------------------------------------------------------- review + deploy

# How the UI is actually reachable, given the port and network choices.
access_url() {
  _scheme=$([ "$TLS_MODE" = terminate-here ] && echo https || echo http)
  if [ "$PUBLISH_PORT" = "yes" ]; then
    printf '%s://localhost:%s' "$_scheme" "$PORT"
  elif [ -n "$EXTRA_NET" ]; then
    printf 'not published — reach it at %s://sol2docker:8080 from the "%s" network' "$_scheme" "$EXTRA_NET"
  else
    printf 'not published — reachable only from inside this stack'
  fi
}

review() {
  head2 "Review"
  printf '  %-22s %s\n' "topology" "$TOPOLOGY"
  printf '  %-22s %s\n' "url" "$(access_url)"
  printf '  %-22s %s\n' "image" "${SERVER_IMAGE}:${IMAGE_TAG} (${PIN_PLATFORM})"
  printf '  %-22s %s\n' "tls" "$TLS_MODE"
  printf '  %-22s %s\n' "admin user" "$ADMIN_USER"
  printf '  %-22s %s\n' "admin password" "$([ -n "$ADMIN_PASS" ] && echo '<set by you>' || echo 'generated on first boot')"
  printf '  %-22s %s\n' "encryption key" "$(mask "$ENC_KEY")"
  printf '  %-22s %s\n' "data" "$([ "$DATA_MODE" = bind-mount ] && echo "$DATA_PATH" || echo 'named volume sol2docker-data')"
  if [ "$TOPOLOGY" = "swarm" ]; then
    printf '  %-22s %s\n' "placement" "$([ -n "$PLACEMENT_NODE" ] && echo "$PLACEMENT_NODE (this host)" || echo 'any manager')"
  fi
  printf '  %-22s %s\n' "extra network" "$([ -n "$EXTRA_NET" ] && echo "$EXTRA_NET$([ "$EXTRA_NET_EXISTS" -eq 1 ] && echo ' (existing)' || echo ' (will be created)')" || echo none)"
  printf '  %-22s %s\n' "node agent" "$([ "$WITH_AGENT" -eq 1 ] && echo "yes (token $(mask "$AGENT_TOKEN"))" || echo no)"
  printf '  %-22s %s\n' "config file" "$COMPOSE_FILE"

  # Mask BOTH secrets in the on-screen preview — the file on disk keeps the real values.
  head2 "Generated ${COMPOSE_FILE##*/}"
  _preview="$COMPOSE_BODY"
  _preview=$(printf '%s\n' "$_preview" | sed "s|${ENC_KEY}|<encryption-key>|g")
  [ -n "$AGENT_TOKEN" ] && _preview=$(printf '%s\n' "$_preview" | sed "s|${AGENT_TOKEN}|<agent-token>|g")
  printf '%s\n' "$_preview" | sed 's/^/  /'
}

create_extra_network() {
  [ -n "$EXTRA_NET" ] || return 0
  [ "$EXTRA_NET_EXISTS" -eq 1 ] && return 0
  if [ "$TOPOLOGY" = "swarm" ]; then
    set -- docker network create --driver overlay
    [ "$EXTRA_NET_ATTACHABLE" = "yes" ] && set -- "$@" --attachable
    [ "$EXTRA_NET_ENCRYPTED" = "yes" ] && set -- "$@" --opt encrypted
    run "$@" "$EXTRA_NET"
  else
    run docker network create "$EXTRA_NET"
  fi
}

deploy() {
  head2 "Deploy"
  # Create the bind target ourselves — left to Docker it appears owned by root, a surprise for
  # a non-root operator later. Only meaningful when the service runs on THIS host; for a remote
  # placement the path is needed over there, so say so instead of making a stray empty dir here.
  if [ "$DATA_MODE" = "bind-mount" ] && [ ! -d "$DATA_PATH" ]; then
    run mkdir -p "$DATA_PATH"
  fi
  create_extra_network
  write_file "$COMPOSE_FILE" "$COMPOSE_BODY"
  if [ "$TOPOLOGY" = "swarm" ]; then
    [ "$SWARM_STATE" = "manager" ] || run docker swarm init
    run docker stack deploy -c "$COMPOSE_FILE" "$STACK_NAME"
  else
    # shellcheck disable=SC2086
    run $COMPOSE_CMD -f "$COMPOSE_FILE" up -d
  fi
}

# The container id we can exec into FROM THIS HOST, or empty if there isn't one. In swarm the
# task is named sol2docker_sol2docker.1.<id>, not CONTAINER_NAME — and when the service is
# placed on another manager it isn't on this machine at all.
server_container() {
  if [ "$TOPOLOGY" = "swarm" ]; then
    docker ps -q --filter "label=com.docker.swarm.service.name=${STACK_NAME}_sol2docker" 2>/dev/null | head -n1
  else
    docker ps -q --filter "name=^/${CONTAINER_NAME}\$" 2>/dev/null | head -n1
  fi
}

wait_ready() {
  head2 "Waiting for Sol2Docker to come up"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %s[dry-run]%s would poll GET /api/v2/ping until it reports ok\n' "$CYAN" "$RESET"
    return 0
  fi

  # Swarm schedules asynchronously — wait for a task to actually be running first.
  if [ "$TOPOLOGY" = "swarm" ]; then
    _i=0
    while [ "$_i" -lt 60 ]; do
      if docker service ps "${STACK_NAME}_sol2docker" --filter desired-state=running \
        --format '{{.CurrentState}}' 2>/dev/null | grep -q '^Running'; then
        ok "service task is running"
        break
      fi
      _i=$((_i + 1))
      sleep 2
    done
  fi

  _i=0
  while [ "$_i" -lt 60 ]; do
    _cid=$(server_container)
    if [ -n "$_cid" ] && docker exec "$_cid" wget -qO- "http://127.0.0.1:8080/api/v2/ping" 2>/dev/null | grep -q '"ok":true'; then
      ok "server is responding"
      return 0
    fi
    _i=$((_i + 1))
    sleep 2
  done
  if [ "$TOPOLOGY" = "swarm" ]; then
    warn "gave up waiting — check: docker service logs ${STACK_NAME}_sol2docker"
  else
    warn "gave up waiting — check: docker logs $CONTAINER_NAME"
  fi
  return 1
}

# The agent has no HTTP surface (it is outbound-only), so "running" is the signal we can check
# here. It reports to the server within one interval, ~30s, after which the node appears in the UI.
wait_agent() {
  [ "$WITH_AGENT" -eq 1 ] || return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %s[dry-run]%s would wait for the agent to start\n' "$CYAN" "$RESET"
    return 0
  fi
  _i=0
  while [ "$_i" -lt 30 ]; do
    if [ "$TOPOLOGY" = "swarm" ]; then
      if docker service ps "${STACK_NAME}_agent" --filter desired-state=running \
        --format '{{.CurrentState}}' 2>/dev/null | grep -q '^Running'; then
        ok "agent is running"
        return 0
      fi
    else
      if docker ps -q --filter "name=^/${CONTAINER_NAME}-agent\$" 2>/dev/null | grep -q .; then
        ok "agent is running"
        return 0
      fi
    fi
    _i=$((_i + 1))
    sleep 2
  done
  if [ "$TOPOLOGY" = "swarm" ]; then
    warn "the agent isn't running yet — check: docker service logs ${STACK_NAME}_agent"
  else
    warn "the agent isn't running yet — check: docker logs ${CONTAINER_NAME}-agent"
  fi
  return 1
}

# What actually ended up running, so the last thing on screen is the real state.
show_status() {
  head2 "Services"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %s[dry-run]%s would list each service and its state here\n' "$CYAN" "$RESET"
    return 0
  fi
  if [ "$TOPOLOGY" = "swarm" ]; then
    docker stack services "$STACK_NAME" --format '{{.Name}}|{{.Mode}}|{{.Replicas}}|{{.Image}}' 2>/dev/null |
      while IFS='|' read -r _n _m _r _img; do
        printf '  %-26s %-10s %-8s %s\n' "$_n" "$_m" "$_r" "${_img%%@*}"
      done
  else
    docker ps -a \
      --filter "name=^/${CONTAINER_NAME}\$" --filter "name=^/${CONTAINER_NAME}-agent\$" \
      --format '{{.Names}}|{{.Status}}' 2>/dev/null |
      while IFS='|' read -r _n _s; do
        printf '  %-26s %s\n' "$_n" "$_s"
      done
  fi
}

summary() {
  _scheme=$([ "$TLS_MODE" = terminate-here ] && echo https || echo http)
  head2 "Done"
  say "  Open:      ${BOLD}$(access_url)${RESET}"
  say "  Username:  ${ADMIN_USER}"

  if [ -n "$ADMIN_PASS" ]; then
    say "  Password:  <the one you entered>"
  elif [ "$DRY_RUN" -eq 1 ]; then
    printf '  %s[dry-run]%s would read the generated password from /data/initial-admin-password\n' "$CYAN" "$RESET"
  else
    # The app writes it to a 0600 file in the data dir — deliberately NOT to the logs. With a
    # bind mount that file is right here on the host, which is more reliable than exec'ing into
    # a container that may still be settling; fall back to the container otherwise.
    _pw=""
    _t=0
    while [ "$_t" -lt 15 ]; do
      if [ "$DATA_MODE" = "bind-mount" ] && [ -r "${DATA_PATH}/initial-admin-password" ]; then
        _pw=$(tr -d '\r\n' <"${DATA_PATH}/initial-admin-password" 2>/dev/null || true)
      fi
      if [ -z "$_pw" ]; then
        _cid=$(server_container)
        if [ -n "$_cid" ]; then
          _pw=$(docker exec "$_cid" cat /data/initial-admin-password 2>/dev/null | tr -d '\r\n' || true)
        fi
      fi
      [ -n "$_pw" ] && break
      _t=$((_t + 1))
      sleep 1
    done
    if [ -n "$_pw" ]; then
      say "  Password:  ${BOLD}${_pw}${RESET}"
      if [ "$DATA_MODE" = "bind-mount" ]; then
        info "Change it after logging in, then: rm ${DATA_PATH}/initial-admin-password"
      else
        info "Change it after logging in, then delete /data/initial-admin-password in the container."
      fi
    else
      warn "couldn't read the generated password automatically."
      if [ "$DATA_MODE" = "bind-mount" ]; then
        say "    try: sudo cat ${DATA_PATH}/initial-admin-password"
      else
        say "    try: docker exec \$(docker ps -q -f name=sol2docker) cat /data/initial-admin-password"
      fi
    fi
  fi

  head2 "Keep this safe"
  say "  Your encryption key lives in ${BOLD}${COMPOSE_FILE}${RESET} (mode 0600)."
  say "  Back it up. Without it, stored registry and git credentials cannot be decrypted."
  if [ "$WITH_AGENT" -eq 1 ]; then
    head2 "Node agent"
    say "  Deployed. It reports every ~30s; the node appears under Nodes once it does."
  fi
}

# ---------------------------------------------------------------- main

usage() {
  cat <<EOF
Sol2Docker installer v${VERSION}

  install.sh [options]

  --dry-run     Walk the entire flow and print what would happen. Changes nothing.
  --dir PATH    Where to keep the generated compose file (skips that prompt).
                Default: /etc/sol2docker as root on Linux, else ~/.sol2docker
  --yes         Accept every default (does NOT auto-install Docker).
  --help        Show this message.
EOF
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --dir)
        shift
        [ $# -gt 0 ] || die "--dir needs a path"
        STATE_DIR_FLAG="$1"
        ;;
      --dir=*) STATE_DIR_FLAG="${1#--dir=}" ;;
      --yes | -y) ASSUME_YES=1 ;;
      --help | -h)
        usage
        exit 0
        ;;
      *) die "unknown option: $1  (try --help)" ;;
    esac
    shift
  done

  # State dir: system-wide when root on Linux, else per-user.
  if [ -n "$STATE_DIR_FLAG" ]; then
    STATE_DIR="$STATE_DIR_FLAG"
  elif [ "$(id -u)" -eq 0 ] && [ "$(uname -s)" = "Linux" ]; then
    STATE_DIR="/etc/sol2docker"
  else
    STATE_DIR="$HOME/.sol2docker"
  fi

  require_tty

  printf '\n%sSol2Docker installer%s %sv%s%s\n' "$BOLD" "$RESET" "$DIM" "$VERSION" "$RESET"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s  DRY RUN — nothing will be installed, written, or started.%s\n' "$YELLOW" "$RESET"
  fi

  preflight
  gather
  render
  review

  printf '\n'
  if ! confirm "Proceed?" y; then
    say "  Aborted. Nothing was changed."
    exit 0
  fi

  deploy
  # Never abort on a readiness timeout — the deploy already happened, so the user still needs
  # the summary (URL, password, key location) even if something is slow to come up.
  wait_ready || true
  wait_agent || true
  show_status
  summary
}

main "$@"
