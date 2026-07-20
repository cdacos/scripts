#!/bin/sh
# dev! - Folder-based Docker dev container launcher
#
# Each named container mounts ONE folder (rw) plus its own persistent state under
# ~/.local/dev-container/<name>/ (bus token, claude home, port, folder). Nothing
# else on the host is exposed. No git worktrees, no repo bind-mount, no docker.sock
# (unless --docker is passed).

set -e

# Bump this on user-visible behavior changes (see CLAUDE.md).
VERSION="2.2"

# State home: per-name container state lives here. Override for testing.
STATE_HOME="${DEV_CONTAINER_HOME:-$HOME/.local/dev-container}"

show_help() {
	cat <<'EOF'
Usage: dev! [name] [folder] [--docker]
       dev! kill <name>
       dev! completion bash|zsh
       dev! -h | --help
       dev! --version

Launches a named Docker dev container that mounts ONLY the given folder (rw) plus
its own persistent state. Free of git repos and worktrees.

Commands:
  (no args)                List all containers: NAME, PORT, STATUS, FOLDER
  <name> [folder]          Create/start container for folder (default: current dir)
  <name> ... --docker      Also mount /var/run/docker.sock (see Isolation below)
  kill <name>              Stop+remove container and image, delete its state dir
  completion bash|zsh      Output shell completion code
  -h, --help               Show this help
  --version                Print version and exit

Start semantics:
  running   -> report and quit (attach with: docker exec -it -u dev dev-<name> bash)
  stopped   -> remove + recreate bound to the folder from THIS invocation (reuses
               the stored port and bus token), then attach
  none      -> confirm, run the token flow, build, run, attach
  Folder is not sticky: each (re)create binds to the folder you pass that time.

State layout (STATE_HOME = $DEV_CONTAINER_HOME or ~/.local/dev-container):
  <STATE_HOME>/.env          shared KEY=value env (AGENT_BUS_URL, GITHUB_USERNAME,
                             GITHUB_TOKEN_DOTFILES, GITCONFIG, ...) - loaded first
  <STATE_HOME>/<name>/.env   per-name KEY=value (AGENT_BUS_TOKEN + overrides) - wins
  <STATE_HOME>/<name>/Dockerfile  per-name build recipe (default on first create;
                             bind-mounted rw at /home/dev/Dockerfile so the container
                             can edit it - takes effect on the next recreate)
  <STATE_HOME>/<name>/port   host port (plain text; deliberately NOT in .env)
  <STATE_HOME>/<name>/folder last folder path (for listing)
  <STATE_HOME>/<name>/claude persistent /home/dev/.claude (seeded once from ~/.claude)

Env files:
  Plain KEY=value only (no quotes, no $expansion) so the same file can be sh-sourced
  at build time AND passed to the container via `docker run --env-file`. Order is:
  host env -> shared .env -> per-name .env (later wins). Everything defined there is
  visible inside the container at runtime (including GitHub tokens); the BuildKit
  secret path still keeps the dotfiles token out of image layers.

Dockerfile:
  Each container has its OWN Dockerfile at <STATE_HOME>/<name>/Dockerfile, written
  from a batteries-included default on first create. It is bind-mounted rw at
  /home/dev/Dockerfile, so the container can edit its own build recipe; changes take
  effect on the next recreate. The target folder's own Dockerfile(s) are ignored -
  crib from them by hand if you like. Build context is <STATE_HOME>/<name>/ (a
  .dockerignore keeps its state and secrets out of the context).

Agent-bus token flow (on first create, if <name>/.env has no AGENT_BUS_TOKEN):
  (e)nter    paste an operator-issued token
  (g)enerate openssl rand -hex 32
  (s)kip     no bus identity
  On enter/generate the token is written to <name>/.env and a paste-ready
  config/agents.json fragment (with its sha256) is printed for the bus operator.

Persona flow (on first create, optional):
  After seeding the claude dir you can give the agent a persona. Enter a name,
  then (g)enerate a bio with `claude -p` (sonnet), (w)rite your own in $EDITOR,
  or (s)kip. The bio is saved to <name>/claude/persona.md and imported from the
  container's CLAUDE.md via an '@persona.md' line (the seeded CLAUDE.md is left
  otherwise untouched). Skipped or empty personas write nothing.

Isolation (be honest):
  The container sees ONLY the target folder (at the same absolute path) and its own
  claude dir. It does NOT get the rest of the host filesystem. Network is NOT
  isolated. --docker mounts the host Docker socket, which is root-equivalent access
  to the host (on macOS: the whole Docker VM and every file-shared path) - use only
  when the container genuinely needs to spawn containers.

Examples:
  dev! api ~/src/api        # container 'dev-api' mounting ~/src/api
  dev! scratch              # container 'dev-scratch' mounting the current dir
  dev! ci . --docker        # mount current dir + docker.sock
  dev!                      # list all containers
  dev! kill api             # tear down 'dev-api' and delete its state
EOF
}

# ANSI colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

error() {
	printf "${RED}Error: %s${NC}\n" "$1" >&2
	exit 1
}

info() {
	printf "${CYAN}%s${NC}\n" "$1"
}

success() {
	printf "${GREEN}%s${NC}\n" "$1"
}

# Slugify a string: lowercase, replace special chars with hyphens
slugify() {
	echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//'
}

# Get Claude credentials from macOS Keychain (empty on non-macOS or if not found)
get_claude_credentials() {
	if [ "$(uname)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
		security find-generic-password -s "Claude Code-credentials" -a "$USER" -w 2>/dev/null || true
	fi
}

# Get Claude config (~/.claude.json) if it exists
get_claude_json() {
	if [ -f "${HOME}/.claude.json" ]; then
		cat "${HOME}/.claude.json"
	fi
}

# Get container status: running, stopped, or none
get_container_status() {
	container_name="$1"
	status=$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null) || {
		echo "none"
		return
	}
	if [ "$status" = "true" ]; then
		echo "running"
	else
		echo "stopped"
	fi
}

# sha256 of a string (for the agents.json fragment). Prefer shasum, fall back to openssl.
token_sha256() {
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
	else
		printf '%s' "$1" | openssl dgst -sha256 | awk '{print $NF}'
	fi
}

# Source each env file that exists (auto-export), shared first so per-name wins.
load_env_files() {
	for f in "$@"; do
		if [ -f "$f" ]; then
			set -a
			# shellcheck disable=SC1090
			. "$f"
			set +a
		fi
	done
}

# Create the shared .env with commented placeholders if it does not exist.
ensure_shared_env() {
	if [ ! -f "$STATE_HOME/.env" ]; then
		mkdir -p "$STATE_HOME"
		cat >"$STATE_HOME/.env" <<EOF
# Shared dev-container env. Plain KEY=value only (no quotes, no \$expansion): this
# file is both sh-sourced at build time and passed to containers via --env-file.
# Per-name <name>/.env overrides anything here.
AGENT_BUS_URL=${AGENT_BUS_URL:-}
GITHUB_USERNAME=${GITHUB_USERNAME:-}
#GITHUB_TOKEN_DOTFILES=
#GITCONFIG=
EOF
		info "Created $STATE_HOME/.env"
	fi
}

# Echo the port for a name: stored port if present, else max existing +1, else prompt.
# Prompt/info go to stderr so the caller can capture the port from stdout.
allocate_port() {
	name_dir="$1"
	if [ -f "$name_dir/port" ]; then
		cat "$name_dir/port"
		return 0
	fi

	max_port=""
	has_ports=false
	for pf in "$STATE_HOME"/*/port; do
		[ -f "$pf" ] || continue
		has_ports=true
		p=$(cat "$pf")
		if [ -z "$max_port" ] || { [ "$p" -gt "$max_port" ] 2>/dev/null; }; then
			max_port="$p"
		fi
	done

	if [ "$has_ports" = false ]; then
		printf "\n" >&2
		printf "${CYAN}No existing port assignments found.${NC}\n" >&2
		printf "Enter starting port number (e.g., 9000, 10000, 15000): " >&2
		read -r start_port
		if ! echo "$start_port" | grep -qE '^[0-9]+$'; then
			error "Invalid port number. Please enter a numeric value."
		fi
		if [ "$start_port" -lt 1024 ] || [ "$start_port" -gt 65535 ]; then
			error "Port must be between 1024 and 65535"
		fi
		echo "$start_port"
	else
		echo $((max_port + 1))
	fi
}

# Resolve a folder argument to an absolute path (must exist). stdout = path only.
resolve_folder() {
	folder=$(cd "$1" 2>/dev/null && pwd) || error "Folder not found: $1"
	echo "$folder"
}

# Warn (do not block) when the folder's git will not work inside the container.
warn_git() {
	folder="$1"
	if [ -f "$folder/.git" ]; then
		printf "${YELLOW}Warning: %s is a git worktree; its gitdir lives outside the mount - git will not work inside the container.${NC}\n" "$folder" >&2
	elif top=$(git -C "$folder" rev-parse --show-toplevel 2>/dev/null); then
		if [ "$top" != "$folder" ]; then
			printf "${YELLOW}Warning: %s is a subfolder of git repo %s; the repo root is not mounted - git will not work inside the container.${NC}\n" "$folder" "$top" >&2
		fi
	fi
}

# Seed a fresh per-name claude dir from host ~/.claude (settings/skills/plugins only).
seed_claude() {
	claude_dir="$1"
	[ -d "$claude_dir" ] && return 0
	mkdir -p "$claude_dir"
	if [ -d "${HOME}/.claude" ]; then
		info "Seeding Claude config into $claude_dir..."
		tar -cf - -C "${HOME}/.claude" \
			--include='./settings.json' \
			--include='./CLAUDE.md' \
			--include='./.credentials.json' \
			--include='./skills' --include='./skills/*' \
			--include='./plugins' --include='./plugins/*' \
			. 2>/dev/null | tar -xf - -C "$claude_dir" 2>/dev/null || true
	fi
}

# Keep the per-name build context small and secret-free. The context dir doubles as
# container state: bus token (.env), claude creds, port and folder markers. Ignore
# them so only the Dockerfile (plus anything the user deliberately drops in) is sent
# to the daemon. Written once; delete it to un-ignore.
ensure_dockerignore() {
	di="$1/.dockerignore"
	[ -f "$di" ] && return 0
	cat >"$di" <<'EOF'
# Auto-generated by dev!. Keeps the build context small and secret-free.
# The Dockerfile lives in this dir alongside container state; ignore the state.
.env
port
folder
claude
EOF
}

# Prompt for and persist a bus token if <name>/.env lacks a non-empty one.
ensure_token() {
	name="$1"
	name_dir="$2"
	name_env="$3"

	if [ -f "$name_env" ] && grep -qE '^AGENT_BUS_TOKEN=.+' "$name_env"; then
		return 0
	fi

	printf "\n"
	printf "${CYAN}No agent-bus token for '%s'.${NC}\n" "$name"
	printf "  (e)nter an operator-issued token\n"
	printf "  (g)enerate a random token (openssl rand -hex 32)\n"
	printf "  (s)kip - no bus identity\n"
	printf "Choice [e/g/s]: "
	read -r choice

	token=""
	case "$choice" in
	e | E)
		printf "Paste token: "
		read -r token
		;;
	g | G)
		token=$(openssl rand -hex 32)
		;;
	*)
		info "Skipping bus identity."
		return 0
		;;
	esac

	if [ -z "$token" ]; then
		info "Empty token, skipping bus identity."
		return 0
	fi

	mkdir -p "$name_dir"
	if [ ! -f "$name_env" ]; then
		cat >"$name_env" <<EOF
# Per-name dev-container env. Plain KEY=value only (no quotes, no \$expansion).
# Overrides the shared $STATE_HOME/.env. AGENT_BUS_TOKEN identifies this agent
# on the bus and MUST be distinct per container.
EOF
	fi
	printf 'AGENT_BUS_TOKEN=%s\n' "$token" >>"$name_env"
	export AGENT_BUS_TOKEN="$token"

	hash=$(token_sha256 "$token")
	printf "\n"
	success "Token written to $name_env"
	printf "Add this to the bus's ${CYAN}config/agents.json${NC} (then reload) before '%s' can authenticate:\n\n" "$name"
	printf '  "%s": { "token_sha256": "%s", "publish": ["*"], "subscribe": ["*"] }\n\n' "$name" "$hash"
}

# Draft a persona bio for a name with `claude -p` (sonnet). Prints only the bio to
# stdout; the status line goes to stderr so it is not captured by $(...).
generate_persona() {
	pname="$1"
	info "Drafting a bio for '$pname' with claude (sonnet)..." >&2
	claude --model sonnet -p "Write a short second-person persona (2-3 sentences) for an AI software-engineering agent named \"$pname\". Establish that it is a careful, methodical coding agent, but give it a small playful character quirk that fits the name. Begin with 'Your name is $pname.' Output only the persona text - no preamble, no surrounding quotes." 2>/dev/null || true
}

# Open $EDITOR on the given seed text (via the tty, since we run inside $(...)) and
# echo the edited result to stdout.
edit_text() {
	tmpf=$(mktemp)
	printf '%s\n' "$1" >"$tmpf"
	"${EDITOR:-vi}" "$tmpf" </dev/tty >/dev/tty 2>&1 || true
	cat "$tmpf"
	rm -f "$tmpf"
}

# Prompt (first create only) for an optional persona, written to <claude>/persona.md
# and imported from the seeded CLAUDE.md via an '@persona.md' line. The bio can be
# drafted with claude, hand-written in $EDITOR, or skipped. Never overwrites an
# existing persona and never rewrites the rest of CLAUDE.md.
ensure_persona() {
	name="$1"
	claude_dir="$2"
	persona_file="$claude_dir/persona.md"

	[ -f "$persona_file" ] && return 0

	printf "\n"
	printf "${CYAN}Give '%s' a persona? It is written to the container's CLAUDE.md so the agent knows who it is.${NC}\n" "$name"
	printf "Persona name (blank to skip): "
	read -r persona_name
	[ -z "$persona_name" ] && {
		info "No persona."
		return 0
	}

	have_claude=false
	command -v claude >/dev/null 2>&1 && have_claude=true

	if [ "$have_claude" = true ]; then
		printf "  (g)enerate a bio with claude   (w)rite my own   (s)kip\n"
		printf "Choice [g/w/s]: "
	else
		printf "  (w)rite my own   (s)kip   (claude not found, generate unavailable)\n"
		printf "Choice [w/s]: "
	fi
	read -r choice

	bio=""
	case "$choice" in
	g | G)
		[ "$have_claude" = true ] || {
			info "claude not found; skipping."
			return 0
		}
		bio=$(generate_persona "$persona_name")
		while :; do
			printf "\n${GREEN}%s${NC}\n\n" "$bio"
			printf "(a)ccept / (r)egenerate / (e)dit / (s)kip: "
			read -r act
			case "$act" in
			a | A | "") break ;;
			r | R) bio=$(generate_persona "$persona_name") ;;
			e | E) bio=$(edit_text "$bio") ;;
			s | S)
				info "Skipping persona."
				return 0
				;;
			esac
		done
		;;
	w | W)
		bio=$(edit_text "Your name is $persona_name. ")
		;;
	*)
		info "Skipping persona."
		return 0
		;;
	esac

	# Trim to check for emptiness (a lone seed/whitespace counts as skip).
	if [ -z "$(printf '%s' "$bio" | tr -d '[:space:]')" ]; then
		info "Empty persona, skipping."
		return 0
	fi

	printf '%s\n' "$bio" >"$persona_file"

	# Import the persona from CLAUDE.md (append the line once; never rewrite the file).
	claude_md="$claude_dir/CLAUDE.md"
	if ! { [ -f "$claude_md" ] && grep -qxF '@persona.md' "$claude_md"; }; then
		printf '\n@persona.md\n' >>"$claude_md"
	fi
	success "Persona written to $persona_file"
}

# Build the image. dockerfile + context differ by resolution; project_path drives path parity.
build_image() {
	image="$1"
	dockerfile="$2"
	context="$3"
	project_path="$4"

	token_file=""
	if [ -n "${GITHUB_TOKEN_DOTFILES:-}" ]; then
		token_file=$(mktemp)
		printf '%s' "$GITHUB_TOKEN_DOTFILES" >"$token_file"
	fi

	info "Building image '$image' from $dockerfile..."
	set -- build -f "$dockerfile"
	[ -n "$token_file" ] && set -- "$@" --secret "id=github_token,src=$token_file"
	set -- "$@" \
		--build-arg GITCONFIG="${GITCONFIG:-}" \
		--build-arg GITHUB_USERNAME="${GITHUB_USERNAME:-}" \
		--build-arg HOST_PROJECT_PATH="${project_path}" \
		--build-arg HOST_UID="$(id -u)" \
		--build-arg HOST_GID="$(id -g)" \
		-t "$image" "$context"
	docker "$@"

	[ -n "$token_file" ] && rm -f "$token_file" || true
}

# Run the container. env files are added only if present (docker errors on a missing one).
run_container() {
	name="$1"
	port="$2"
	folder="$3"
	image="$4"
	claude_dir="$5"
	docker_sock="$6"
	shared_env="$7"
	name_env="$8"
	dockerfile="$9"

	claude_creds=$(get_claude_credentials)
	claude_json=$(get_claude_json)

	set -- --init -d \
		--name "dev-$name" \
		-p "${port}:8000" \
		-e "CLAUDE_CODE_CREDENTIALS=${claude_creds}" \
		-e "CLAUDE_JSON=${claude_json}"

	[ -f "$shared_env" ] && set -- "$@" --env-file "$shared_env"
	[ -f "$name_env" ] && set -- "$@" --env-file "$name_env"

	set -- "$@" \
		-v "${folder}:${folder}" \
		-v "${claude_dir}:/home/dev/.claude" \
		-v "${dockerfile}:/home/dev/Dockerfile" \
		-w "${folder}"

	[ "$docker_sock" = "true" ] && set -- "$@" -v /var/run/docker.sock:/var/run/docker.sock

	set -- "$@" "$image" tail -f /dev/null

	info "Starting container 'dev-$name'..."
	docker run "$@"
}

# Attach an interactive shell as the dev user.
attach_container() {
	docker exec -it -e TERM=xterm-256color -e COLORTERM=truecolor -u dev "dev-$1" bash
}

# Create or start a container for a folder.
cmd_up() {
	name=$(slugify "$1")
	folder_arg="${2:-.}"
	docker_sock="$3"
	[ -n "$name" ] || error "Invalid name"

	container="dev-$name"
	image="dev-$name"
	name_dir="$STATE_HOME/$name"
	name_env="$name_dir/.env"
	shared_env="$STATE_HOME/.env"

	status=$(get_container_status "$container")
	if [ "$status" = "running" ]; then
		info "Container '$container' is already running."
		printf "Port ${YELLOW}%s${NC} → container:8000\n" "$(cat "$name_dir/port" 2>/dev/null || echo '?')"
		printf "Attach with: ${CYAN}docker exec -it -u dev %s bash${NC}\n" "$container"
		exit 0
	fi

	folder=$(resolve_folder "$folder_arg")

	ensure_shared_env
	load_env_files "$shared_env" "$name_env"

	# Each container owns its Dockerfile under its state dir (context = that dir); it
	# is written on first create and thereafter editable by the container via the
	# /home/dev/Dockerfile bind mount. The target folder's own Dockerfiles are ignored.
	# Only paths here - the actual write happens past the confirm gate below.
	dockerfile="$name_dir/Dockerfile"
	context="$name_dir"

	port=$(allocate_port "$name_dir")

	if [ "$status" = "none" ]; then
		printf "\n"
		info "Will create:"
		printf "  Name:       ${YELLOW}%s${NC}\n" "$name"
		printf "  Folder:     ${YELLOW}%s${NC}\n" "$folder"
		printf "  Container:  ${YELLOW}%s${NC}\n" "$container"
		printf "  Port:       ${YELLOW}%s${NC} → 8000\n" "$port"
		printf "  Dockerfile: ${YELLOW}%s${NC}\n" "$dockerfile"
		[ "$docker_sock" = "true" ] && printf "  ${RED}docker.sock: mounted (root-equivalent host access)${NC}\n"
		printf "\nContinue? [y/n] "
		read -r answer
		case "$answer" in
		[Yy] | [Yy][Ee][Ss]) ;;
		*)
			info "Aborted."
			exit 0
			;;
		esac
		printf "\n"
	else
		info "Recreating stopped container '$container' bound to $folder..."
		docker rm "$container" >/dev/null
	fi

	mkdir -p "$name_dir"
	printf '%s' "$port" >"$name_dir/port"
	printf '%s' "$folder" >"$name_dir/folder"

	if [ ! -f "$dockerfile" ]; then
		write_default_dockerfile "$dockerfile"
		info "Wrote default Dockerfile for '$name' to $dockerfile (edit it there, or /home/dev/Dockerfile inside the container)."
	fi
	ensure_dockerignore "$name_dir"

	warn_git "$folder"
	[ "$status" = "none" ] && ensure_token "$name" "$name_dir" "$name_env"
	seed_claude "$name_dir/claude"
	[ "$status" = "none" ] && ensure_persona "$name" "$name_dir/claude"
	build_image "$image" "$dockerfile" "$context" "$folder"
	run_container "$name" "$port" "$folder" "$image" "$name_dir/claude" "$docker_sock" "$shared_env" "$name_env" "$dockerfile"

	printf "\n"
	success "Container ready!"
	printf "Port ${YELLOW}%s${NC} → container:8000\n\n" "$port"
	attach_container "$name"
}

# List all containers with their status.
cmd_list() {
	if [ ! -d "$STATE_HOME" ]; then
		info "No dev-containers yet. Create one with: dev! <name> [folder]"
		return 0
	fi

	printf "%-16s %-8s %-9s %s\n" "NAME" "PORT" "STATUS" "FOLDER"
	printf "%-16s %-8s %-9s %s\n" "----------------" "--------" "---------" "------"

	found=false
	for d in "$STATE_HOME"/*/; do
		[ -d "$d" ] || continue
		found=true
		name=$(basename "$d")
		port=$(cat "$d/port" 2>/dev/null || echo "?")
		folder=$(cat "$d/folder" 2>/dev/null || echo "?")
		status=$(get_container_status "dev-$name")
		case "$status" in
		running) printf "%-16s %-8s ${GREEN}%-9s${NC} %s\n" "$name" "$port" "running" "$folder" ;;
		stopped) printf "%-16s %-8s ${YELLOW}%-9s${NC} %s\n" "$name" "$port" "stopped" "$folder" ;;
		*) printf "%-16s %-8s ${RED}%-9s${NC} %s\n" "$name" "$port" "none" "$folder" ;;
		esac
	done

	[ "$found" = false ] && info "No dev-containers yet. Create one with: dev! <name> [folder]"
	return 0
}

# Stop+remove container and image, delete the state dir.
cmd_kill() {
	name=$(slugify "$1")
	[ -n "$name" ] || error "Usage: dev! kill <name>"
	container="dev-$name"
	name_dir="$STATE_HOME/$name"
	port=$(cat "$name_dir/port" 2>/dev/null || echo "?")

	printf "\n${RED}Will kill:${NC}\n"
	printf "  Container: ${YELLOW}%s${NC}\n" "$container"
	printf "  Image:     ${YELLOW}%s${NC}\n" "dev-$name"
	printf "  State dir: ${YELLOW}%s${NC}\n" "$name_dir"
	printf "  Port:      ${YELLOW}%s${NC}\n" "$port"
	printf "\nAre you sure? [y/n] "
	read -r answer
	case "$answer" in
	[Yy] | [Yy][Ee][Ss]) ;;
	*)
		info "Aborted."
		exit 0
		;;
	esac
	printf "\n"

	status=$(get_container_status "$container")
	case "$status" in
	running)
		info "Stopping container '$container'..."
		docker stop "$container" >/dev/null
		info "Removing container '$container'..."
		docker rm "$container" >/dev/null
		;;
	stopped)
		info "Removing container '$container'..."
		docker rm "$container" >/dev/null
		;;
	none)
		info "No container found for '$container'"
		;;
	esac

	docker rmi "dev-$name" >/dev/null 2>&1 || true
	[ -d "$name_dir" ] && rm -rf "$name_dir"

	printf "\n"
	success "Killed '$name' (port $port)"
}

# Write the batteries-included default Dockerfile to $1. Alpine-based: bash/git/curl,
# Claude Code, chezmoi dotfiles, tmux, and an entrypoint that materializes Claude
# creds from env. Written once per container to <STATE_HOME>/<name>/Dockerfile on
# first create, then owned/editable by that container via the /home/dev/Dockerfile mount.
# Quoted heredoc: everything below is literal (Dockerfile ARGs, not shell vars).
write_default_dockerfile() {
	cat >"$1" <<'DOCKERFILE'
# Dockerfile - default dev container generated by dev! (edit to taste).
# Minimum requirement: a 'dev' user with bash.

FROM alpine:latest

RUN apk add --no-cache \
    bash \
    curl \
    git \
    ca-certificates \
    sudo \
    shadow \
    ripgrep \
    jq \
    docker-cli \
    tmux \
    vim

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# === BUILD ARGS (passed by dev!) ===
ARG GITCONFIG=""         # Contents of host ~/.gitconfig
ARG GITHUB_USERNAME=""   # For dotfiles repo (optional)
ARG HOST_PROJECT_PATH="/home/dev/src"  # Target folder path, for path parity with host
ARG HOST_UID=1000        # Host user's UID (for volume permission parity)
ARG HOST_GID=1000        # Host user's GID

# Create dev user (password 'dev') matching host UID/GID where possible.
# Falls back cleanly when the host GID/UID collides with an existing one.
RUN (addgroup -g "${HOST_GID}" dev 2>/dev/null || addgroup dev) \
    && (adduser -D -u "${HOST_UID}" -G dev -s /bin/bash dev 2>/dev/null \
        || adduser -D -G dev -s /bin/bash dev) \
    && echo 'dev:dev' | chpasswd \
    && addgroup dev wheel \
    && addgroup dev root \
    && sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Copy host user's git config (passed as build arg)
RUN if [ -n "$GITCONFIG" ]; then echo "$GITCONFIG" > /home/dev/.gitconfig && chown dev:dev /home/dev/.gitconfig; fi

# Create host path directory structure (as root for arbitrary paths like /Users/...)
RUN mkdir -p "${HOST_PROJECT_PATH}" && chown -R dev:dev "$(echo ${HOST_PROJECT_PATH} | cut -d'/' -f1-2)"

# Switch to dev user for remaining setup
USER dev
WORKDIR /home/dev

RUN mkdir -p /home/dev/.local/bin

# Configure shell: PATH, aliases
RUN echo 'export PATH="/home/dev/.local/bin:$PATH"' >> ~/.bashrc \
    && echo "alias claude!='claude --dangerously-skip-permissions --thinking-display summarized'" >> ~/.bashrc \
    && echo "alias ll='ls -la'" >> ~/.bashrc

# Claude Code (native installer, installs to ~/.local/bin)
RUN curl -fsSL https://claude.ai/install.sh | bash

# Chezmoi dotfiles (token passed via BuildKit secret, not stored in image)
RUN --mount=type=secret,id=github_token,mode=0444 \
    GITHUB_TOKEN_DOTFILES=$(cat /run/secrets/github_token 2>/dev/null || true) && \
    if [ -n "$GITHUB_TOKEN_DOTFILES" ] && [ -n "$GITHUB_USERNAME" ]; then \
        sh -c "$(curl -fsLS get.chezmoi.io/lb)" -- init --apply https://${GITHUB_TOKEN_DOTFILES}@github.com/${GITHUB_USERNAME}/dotfiles.git; \
    fi

# Configure tmux
RUN echo 'set -g mouse on' > ~/.tmux.conf \
    && echo 'bind m set -g mouse \\; display "Mouse: #{?mouse,ON,OFF}"' >> ~/.tmux.conf

# No-op afplay stub (macOS command not available in Linux)
RUN echo '#!/bin/sh' > /home/dev/.local/bin/afplay \
    && echo 'exit 0' >> /home/dev/.local/bin/afplay \
    && chmod +x /home/dev/.local/bin/afplay

# Entrypoint script to inject Claude config from env vars
RUN <<'SCRIPT' cat > /home/dev/.local/bin/entrypoint.sh && chmod +x /home/dev/.local/bin/entrypoint.sh
#!/bin/bash
if [ -n "$CLAUDE_CODE_CREDENTIALS" ]; then
  mkdir -p ~/.claude
  echo "$CLAUDE_CODE_CREDENTIALS" > ~/.claude/.credentials.json
fi
if [ -n "$CLAUDE_JSON" ]; then
  echo "$CLAUDE_JSON" > ~/.claude.json
fi
exec "$@"
SCRIPT

ENTRYPOINT ["/home/dev/.local/bin/entrypoint.sh"]

# Re-declare ARG after USER switch (ARGs don't persist)
ARG HOST_PROJECT_PATH="/home/dev/src"
WORKDIR ${HOST_PROJECT_PATH}
DOCKERFILE
}

# Output shell completion code
cmd_completion() {
	case "$1" in
	bash)
		cat <<'EOF'
_dev_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"
    local state="${DEV_CONTAINER_HOME:-$HOME/.local/dev-container}"
    local names=""
    if [ -d "$state" ]; then
        names=$(find "$state" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
    fi
    if [ "$prev" = "kill" ]; then
        COMPREPLY=($(compgen -W "$names" -- "$cur"))
    else
        COMPREPLY=($(compgen -W "kill completion $names" -- "$cur"))
    fi
}
complete -F _dev_complete dev-container.sh
EOF
		;;
	zsh)
		cat <<'EOF'
_dev_complete() {
    local state="${DEV_CONTAINER_HOME:-$HOME/.local/dev-container}"
    local names=()
    if [ -d "$state" ]; then
        names=(${(f)"$(find "$state" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)"})
    fi
    if (( CURRENT == 3 )) && [[ "${words[2]}" == "kill" ]]; then
        compadd -a names
    elif (( CURRENT == 2 )); then
        compadd kill completion
        compadd -a names
    fi
}
compdef _dev_complete dev-container.sh
EOF
		;;
	*)
		echo "Usage: dev-container.sh completion [bash|zsh]" >&2
		exit 1
		;;
	esac
}

# Main entry point
main() {
	if [ $# -eq 0 ]; then
		cmd_list
		exit 0
	fi

	cmd="$1"

	case "$cmd" in
	-h | --help)
		show_help
		exit 0
		;;
	--version)
		echo "$VERSION"
		exit 0
		;;
	kill)
		[ -n "$2" ] || error "Usage: dev! kill <name>"
		cmd_kill "$2"
		exit 0
		;;
	completion)
		[ -n "$2" ] || error "Usage: dev! completion bash|zsh"
		cmd_completion "$2"
		exit 0
		;;
	*)
		name="$1"
		shift
		folder_arg="."
		docker_sock=false
		for arg in "$@"; do
			case "$arg" in
			--docker) docker_sock=true ;;
			-*) error "Unknown option: $arg" ;;
			*) folder_arg="$arg" ;;
			esac
		done
		cmd_up "$name" "$folder_arg" "$docker_sock"
		;;
	esac
}

main "$@"
