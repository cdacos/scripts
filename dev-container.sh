#!/bin/sh
# dev! - Folder-based Docker dev container launcher
#
# Each named container mounts ONE folder (rw) plus its own persistent state under
# ~/.local/dev-container/<name>/ (bus token, claude home, port, folder). Nothing
# else on the host is exposed. No git worktrees, no repo bind-mount, no docker.sock
# (unless --docker is passed).

set -e

# Bump this on user-visible behavior changes (see CLAUDE.md).
VERSION="2.4"

# State home: per-name container state lives here. Override for testing.
STATE_HOME="${DEV_CONTAINER_HOME:-$HOME/.local/dev-container}"

show_help() {
	cat <<'EOF'
Usage: dev! [name] [folder] [--save|--only] [--keep-alive] [--docker]
       dev! kill <name>
       dev! completion bash|zsh
       dev! -h | --help
       dev! --version

Launches a named Docker dev container. A container remembers every folder you
SAVE to it and mounts them all (rw), at their real absolute paths, plus its own
persistent state. By default it suspends itself when you're not using it. Free of
git repos and worktrees.

Commands:
  (no args)                List all containers: NAME, PORT, STATUS, FOLDERS
  <name> [folder]          Create/resume container; ask whether to save the folder
  <name> [folder] --save   Add folder to the set, mount the whole set
  <name> [folder] --only   Mount JUST this folder, don't remember it
  <name> ... --keep-alive  Don't self-suspend; run until stopped (see Idle-suspend)
  <name> ... --docker      Also mount /var/run/docker.sock (see Isolation below)
  kill <name>              Stop+remove container and image, delete its state dir
  completion bash|zsh      Output shell completion code
  -h, --help               Show this help
  --version                Print version and exit

Idle-suspend (default on):
  A container's PID 1 is a supervisor that stops the container once no interactive
  shell has been attached for ~20s (override with DEV_SUSPEND_IDLE). Effectively:
  keep a shell open to keep it alive; exit every shell and it suspends. Resume with
  `dev! <name>` - if nothing changed that's a fast `docker start` that preserves the
  in-container filesystem. Sessions are counted as ptys, so BACKGROUND/detached work
  (a dev server on :8000, a bus agent) does NOT hold it open - use --keep-alive for
  those (it sticks; revert with: rm <STATE_HOME>/<name>/keep-alive).

Mount set (accumulated folders):
  Each container keeps a set of remembered folders as symlinks under
  <STATE_HOME>/<name>/mounts/. --save adds the folder to the set; a bare
  invocation asks (save/only) unless the folder is already saved. --only mounts
  just the given folder for this run and remembers nothing. Every save-mode start
  mounts the WHOLE set; the folder you pass is the working dir. Folders deleted on
  the host are skipped with a warning. Remove one from the set by hand:
      rm <STATE_HOME>/<name>/mounts/<link>
  Docker fixes bind mounts at create time, so changing the set (saving a new
  folder, or --only) takes effect on the next (re)create - a ~1-2s rebuild-free
  docker rm + run; nothing durable is lost.

Start semantics:
  running   -> if the mount set is unchanged, report and quit; otherwise offer to
               recreate to apply the change (attach: docker exec -it -u dev dev-<name> bash)
  stopped   -> if the mount set, image and run-mode are unchanged, fast-resume via
               `docker start` (keeps the in-container fs); else recreate. Then attach.
  none      -> confirm, run the token flow, build, run, attach
  Folder default is the current dir. The working dir is always the folder you pass.

State layout (STATE_HOME = $DEV_CONTAINER_HOME or ~/.local/dev-container):
  <STATE_HOME>/.env          shared KEY=value env (AGENT_BUS_URL, GITHUB_USERNAME,
                             GITHUB_TOKEN_DOTFILES, GITCONFIG, ...) - loaded first
  <STATE_HOME>/<name>/.env   per-name KEY=value (AGENT_BUS_TOKEN + overrides) - wins
  <STATE_HOME>/<name>/Dockerfile  per-name build recipe (default on first create;
                             bind-mounted rw at /home/dev/Dockerfile so the container
                             can edit it - takes effect on the next recreate)
  <STATE_HOME>/<name>/port   host port (plain text; deliberately NOT in .env)
  <STATE_HOME>/<name>/mounts saved folders, one symlink each (name = abs path with
                             '/' as backtick, target = the folder). rm one to forget it.
  <STATE_HOME>/<name>/folder last folder path (working-dir hint / legacy fallback)
  <STATE_HOME>/<name>/keep-alive  marker: present => opt out of idle-suspend (rm to revert)
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
  The container sees ONLY the folders you have saved to it (or, with --only, the
  single folder you passed), each at its real absolute path, plus its own claude
  dir. It does NOT get the rest of the host filesystem - but note the saved set
  grows every time you --save a new folder, so a long-lived container's reach is
  whatever you have accumulated (inspect it with `ls -l <STATE_HOME>/<name>/mounts`).
  Network is NOT isolated. --docker mounts the host Docker socket, which is
  root-equivalent access to the host (on macOS: the whole Docker VM and every
  file-shared path) - use only when the container genuinely needs to spawn containers.

Examples:
  dev! api ~/src/api --save   # remember ~/src/api and mount the set
  dev! api ~/src/lib --save   # now mounts BOTH ~/src/api and ~/src/lib
  dev! api ~/scratch --only   # mount just ~/scratch this run, remember nothing
  dev! scratch                # current dir; asks whether to save it
  dev! ci . --save --docker   # save current dir + mount docker.sock
  dev!                        # list all containers
  dev! kill api               # tear down 'dev-api' and delete its state
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

# --- Mount set (accumulated folders) ------------------------------------------
# A container remembers folders as symlinks under <name>/mounts/. The symlink
# NAME is the absolute path with '/' encoded as backtick (\140), so names are
# unique by construction (no basename collisions) and the mount path is decoded
# straight from the name. The symlink TARGET is the real folder, giving a free
# existence check ([ -e ]) and human-readable `ls -l`. Prune a folder with a
# plain `rm mounts/<link>`.

encode_path() { printf '%s' "$1" | tr '/' '\140'; }
decode_path() { printf '%s' "$1" | tr '\140' '/'; }

# Add a folder to a container's mount set (idempotent).
add_mount() {
	amd="$1"
	afolder="$2"
	mkdir -p "$amd"
	ln -sfn "$afolder" "$amd/$(encode_path "$afolder")"
}

# Count live+dead symlinks in a mount dir.
count_mounts() {
	cm="$1"
	n=0
	[ -d "$cm" ] || {
		echo 0
		return
	}
	for link in "$cm"/*; do
		[ -L "$link" ] && n=$((n + 1))
	done
	echo "$n"
}

# Echo the first mount target (decoded), if any.
first_mount() {
	[ -d "$1" ] || return 0
	for link in "$1"/*; do
		[ -L "$link" ] || continue
		decode_path "$(basename "$link")"
		return 0
	done
}

# Echo the folders to mount this run, one absolute path per line.
#   mode=only -> just this folder (the set is ignored, nothing saved).
#   otherwise -> every live folder in the set. Dead symlinks (folder deleted on
#   the host) are skipped with a warning to stderr. An empty/all-dead set falls
#   back to this invocation's folder so a container never launches with no mount.
build_mount_list() {
	bmode="$1"
	bfolder="$2"
	bmd="$3"
	if [ "$bmode" = only ]; then
		printf '%s\n' "$bfolder"
		return 0
	fi
	found=false
	if [ -d "$bmd" ]; then
		for link in "$bmd"/*; do
			[ -L "$link" ] || continue
			target=$(decode_path "$(basename "$link")")
			if [ -e "$link" ]; then
				printf '%s\n' "$target"
				found=true
			else
				printf "${YELLOW}Warning: saved folder %s no longer exists; skipping (rm %s to forget it).${NC}\n" "$target" "$link" >&2
			fi
		done
	fi
	[ "$found" = false ] && printf '%s\n' "$bfolder"
	return 0
}

# One-time migration: a container from the old single-folder model has a `folder`
# marker but no mounts/ dir. Seed the set from it so it keeps working.
migrate_legacy_folder() {
	mld="$1"
	if [ ! -d "$mld/mounts" ] && [ -f "$mld/folder" ]; then
		old=$(cat "$mld/folder" 2>/dev/null)
		[ -n "$old" ] && [ -d "$old" ] && add_mount "$mld/mounts" "$old"
	fi
}

# Sorted list of a running container's folder-mount sources (excludes the
# container's own claude dir / Dockerfile under name_dir, and docker.sock).
current_folder_mounts() {
	cfm_container="$1"
	cfm_name_dir="$2"
	docker inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$cfm_container" 2>/dev/null |
		while IFS= read -r src; do
			[ -n "$src" ] || continue
			case "$src" in
			"$cfm_name_dir"/*) continue ;;
			/var/run/docker.sock) continue ;;
			*) echo "$src" ;;
			esac
		done | sort -u
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
	if [ ! -f "$di" ]; then
		cat >"$di" <<'EOF'
# Auto-generated by dev!. Keeps the build context small and secret-free.
# The Dockerfile lives in this dir alongside container state; ignore the state.
.env
port
folder
claude
mounts
.build-sig
EOF
		return 0
	fi
	# Upgrade older ignore files (mounts/ can contain symlinks to large host
	# folders; .build-sig is the build cache marker - neither belongs in context).
	for entry in mounts .build-sig; do
		grep -qxF "$entry" "$di" || printf '%s\n' "$entry" >>"$di"
	done
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

# A signature of everything that affects the built image: the Dockerfile plus the
# build args passed to it. Stored after a successful build so unchanged recreates
# can skip `docker build` entirely (recreates are then just docker rm + run).
build_signature() {
	sig_content=$(
		cat "$1"
		printf '\n%s|%s|%s|%s|%s|%s' \
			"${GITCONFIG:-}" "${GITHUB_USERNAME:-}" "$2" "$(id -u)" "$(id -g)" \
			"$([ -n "${GITHUB_TOKEN_DOTFILES:-}" ] && echo 1)"
	)
	token_sha256 "$sig_content"
}

# True when image exists and its stored build signature matches the current one
# (Dockerfile + build args unchanged). Gates both the build-skip and fast resume.
image_up_to_date() {
	docker image inspect "$1" >/dev/null 2>&1 || return 1
	[ -f "$3/.build-sig" ] || return 1
	[ "$(cat "$3/.build-sig")" = "$(build_signature "$2" "$4")" ]
}

# Echo "true" if the container's baked command is the keep-alive daemon (tail),
# "false" if it's the self-suspend supervisor. Used to decide whether a resume can
# reuse the existing container or must recreate to change run-mode.
container_keepalive() {
	docker inspect -f '{{json .Config.Cmd}}' "$1" 2>/dev/null | grep -q '"tail"' &&
		echo true || echo false
}

# Build the image. dockerfile + context differ by resolution; project_path drives path parity.
build_image() {
	image="$1"
	dockerfile="$2"
	context="$3"
	project_path="$4"

	# Skip the build when the image already exists and nothing that feeds it has
	# changed (same Dockerfile + same build args). Keeps folder-add recreates fast.
	if image_up_to_date "$image" "$dockerfile" "$context" "$project_path"; then
		info "Image '$image' is up to date (skipping build)."
		return 0
	fi
	sig=$(build_signature "$dockerfile" "$project_path")
	sig_file="$context/.build-sig"

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
	printf '%s' "$sig" >"$sig_file"
}

# The container's PID 1. By default a self-suspend supervisor: it waits for the
# first interactive session, then exits (stopping the container) once no session
# has been attached for DEV_SUSPEND_IDLE seconds. Sessions are counted as numeric
# slave nodes under /dev/pts (every `docker exec -it` allocates one), so it tracks
# ALL attached shells, not just the one dev! launched. Background/detached work
# holds no pty, so it does NOT keep the container alive - see --keep-alive.
SUPERVISOR_CMD='
idle_limit=${DEV_SUSPEND_IDLE:-20}
startup_limit=${DEV_SUSPEND_STARTUP:-120}
count() { ls /dev/pts 2>/dev/null | grep -c "^[0-9]"; }
waited=0
while [ "$(count)" -eq 0 ] && [ "$waited" -lt "$startup_limit" ]; do
  sleep 2
  waited=$((waited + 2))
done
idle=0
while [ "$idle" -lt "$idle_limit" ]; do
  if [ "$(count)" -gt 0 ]; then idle=0; else idle=$((idle + 2)); fi
  sleep 2
done
'

# Run the container. env files are added only if present (docker errors on a
# missing one). Every folder in mount_list (newline-separated) is bind-mounted at
# the same absolute path; cwd is this invocation's folder. keep_alive=true swaps
# the self-suspend supervisor for a plain never-exit daemon.
run_container() {
	name="$1"
	port="$2"
	cwd="$3"
	image="$4"
	claude_dir="$5"
	docker_sock="$6"
	shared_env="$7"
	name_env="$8"
	dockerfile="$9"
	mount_list="${10}"
	keep_alive="${11}"

	claude_creds=$(get_claude_credentials)
	claude_json=$(get_claude_json)

	set -- --init -d \
		--name "dev-$name" \
		-p "${port}:8000" \
		-e "CLAUDE_CODE_CREDENTIALS=${claude_creds}" \
		-e "CLAUDE_JSON=${claude_json}"

	[ -f "$shared_env" ] && set -- "$@" --env-file "$shared_env"
	[ -f "$name_env" ] && set -- "$@" --env-file "$name_env"

	oldifs=$IFS
	IFS='
'
	for m in $mount_list; do
		[ -n "$m" ] || continue
		set -- "$@" -v "${m}:${m}"
	done
	IFS=$oldifs

	set -- "$@" \
		-v "${claude_dir}:/home/dev/.claude" \
		-v "${dockerfile}:/home/dev/Dockerfile" \
		-w "${cwd}"

	[ "$docker_sock" = "true" ] && set -- "$@" -v /var/run/docker.sock:/var/run/docker.sock

	if [ "$keep_alive" = "true" ]; then
		set -- "$@" "$image" tail -f /dev/null
	else
		set -- "$@" "$image" sh -c "$SUPERVISOR_CMD"
	fi

	info "Starting container 'dev-$name'..."
	docker run "$@"
}

# Attach an interactive shell as the dev user.
attach_container() {
	docker exec -it -e TERM=xterm-256color -e COLORTERM=truecolor -u dev "dev-$1" bash
}

# Prompt for the mount mode (save vs only) when no flag was given. Echoes the
# chosen mode to stdout; prompts/info go to stderr. Exits on cancel.
prompt_mode() {
	pm_folder="$1"
	pm_mounts_dir="$2"
	pm_nset=$(count_mounts "$pm_mounts_dir")
	printf "\n" >&2
	printf "${CYAN}Mount %s:${NC}\n" "$pm_folder" >&2
	if [ "$pm_nset" -gt 0 ]; then
		printf "  (s)ave  remember it and mount the whole set (%s already saved)\n" "$pm_nset" >&2
	else
		printf "  (s)ave  remember it and mount the whole set\n" >&2
	fi
	printf "  (o)nly  just this folder, don't remember it\n" >&2
	printf "  (c)ancel\n" >&2
	printf "Choice [s/o/c]: " >&2
	read -r pm_choice
	case "$pm_choice" in
	s | S) echo save ;;
	o | O) echo only ;;
	*)
		info "Aborted." >&2
		exit 0
		;;
	esac
}

# Create, resume, or start a container. mode is "save"/"only"/"" (prompt if it
# matters); keep_alive is "true" (opt out of idle-suspend) or "".
cmd_up() {
	name=$(slugify "$1")
	folder_arg="${2:-.}"
	docker_sock="$3"
	mode="$4"
	keep_alive="$5"
	[ -n "$name" ] || error "Invalid name"

	container="dev-$name"
	image="dev-$name"
	name_dir="$STATE_HOME/$name"
	name_env="$name_dir/.env"
	shared_env="$STATE_HOME/.env"
	mounts_dir="$name_dir/mounts"
	dockerfile="$name_dir/Dockerfile"
	context="$name_dir"
	keepalive_marker="$name_dir/keep-alive"

	folder=$(resolve_folder "$folder_arg")
	migrate_legacy_folder "$name_dir"

	# Resolve the mode. If no flag: an already-saved folder needs no decision
	# (just start the set); anything else is ambiguous, so ask.
	if [ -z "$mode" ]; then
		if [ -L "$mounts_dir/$(encode_path "$folder")" ]; then
			mode=save
		else
			mode=$(prompt_mode "$folder" "$mounts_dir")
		fi
	fi

	# Resolve keep-alive: the --keep-alive flag wins and sticks (marker file);
	# otherwise inherit the stored marker. Default is idle-suspend. Revert a
	# keep-alive container with: rm <name>/keep-alive.
	if [ "$keep_alive" != "true" ]; then
		[ -f "$keepalive_marker" ] && keep_alive=true || keep_alive=false
	fi

	ensure_shared_env
	load_env_files "$shared_env" "$name_env"
	port=$(allocate_port "$name_dir")

	status=$(get_container_status "$container")
	first_create=false
	[ "$status" = "none" ] && first_create=true

	# Running: compare the running mount set to what this invocation wants. Same ->
	# just report. Different -> the change (a newly saved folder, or --only) needs a
	# recreate to apply, since Docker fixes bind mounts at create time.
	if [ "$status" = "running" ]; then
		[ "$mode" = save ] && add_mount "$mounts_dir" "$folder"
		desired=$(build_mount_list "$mode" "$folder" "$mounts_dir" 2>/dev/null | sort -u)
		current=$(current_folder_mounts "$container" "$name_dir")
		if [ "$desired" = "$current" ]; then
			info "Container '$container' is already running."
			printf "Port ${YELLOW}%s${NC} → container:8000\n" "$(cat "$name_dir/port" 2>/dev/null || echo '?')"
			printf "Attach with: ${CYAN}docker exec -it -u dev %s bash${NC}\n" "$container"
			exit 0
		fi
		printf "\n"
		info "Mount set differs from the running '$container'. It will be:"
		printf '%s\n' "$desired" | while read -r m; do [ -n "$m" ] && printf "  ${YELLOW}%s${NC}\n" "$m"; done
		printf "\nRecreate '%s' now to apply? [y/n] " "$container"
		read -r ans
		case "$ans" in
		[Yy] | [Yy][Ee][Ss]) ;;
		*)
			info "Left running; the change applies on the next recreate."
			exit 0
			;;
		esac
		info "Stopping '$container'..."
		docker stop "$container" >/dev/null
		docker rm "$container" >/dev/null
		status=stopped
	fi

	# Fast resume: a stopped container whose mount set, image, and run-mode are all
	# unchanged just needs `docker start` - no rebuild, no recreate, and the
	# in-container filesystem is preserved. This is the suspend/resume happy path.
	if [ "$status" = "stopped" ]; then
		[ "$mode" = save ] && add_mount "$mounts_dir" "$folder"
		desired=$(build_mount_list "$mode" "$folder" "$mounts_dir" 2>/dev/null | sort -u)
		current=$(current_folder_mounts "$container" "$name_dir")
		if [ "$desired" = "$current" ] &&
			image_up_to_date "$image" "$dockerfile" "$context" "$folder" &&
			[ "$(container_keepalive "$container")" = "$keep_alive" ]; then
			info "Resuming '$container'..."
			docker start "$container" >/dev/null
			printf "\n"
			success "Container resumed!"
			printf "Port ${YELLOW}%s${NC} → container:8000\n\n" "$(cat "$name_dir/port" 2>/dev/null || echo '?')"
			attach_container "$name"
			exit 0
		fi
	fi

	# First create: confirm before writing any state (an abort leaves nothing behind).
	if [ "$first_create" = true ]; then
		printf "\n"
		info "Will create:"
		printf "  Name:       ${YELLOW}%s${NC}\n" "$name"
		if [ "$mode" = only ]; then
			printf "  Folder:     ${YELLOW}%s${NC} (only - not saved)\n" "$folder"
		else
			printf "  Folder:     ${YELLOW}%s${NC} (saved to the set)\n" "$folder"
		fi
		printf "  Container:  ${YELLOW}%s${NC}\n" "$container"
		printf "  Port:       ${YELLOW}%s${NC} → 8000\n" "$port"
		printf "  Dockerfile: ${YELLOW}%s${NC}\n" "$dockerfile"
		if [ "$keep_alive" = "true" ]; then
			printf "  Run mode:   ${YELLOW}keep-alive${NC} (stays up until stopped)\n"
		else
			printf "  Run mode:   ${YELLOW}suspend when idle${NC} (stops ~%ss after the last shell exits)\n" "${DEV_SUSPEND_IDLE:-20}"
		fi
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
		info "Recreating '$container'..."
		docker rm "$container" >/dev/null 2>&1 || true
	fi

	mkdir -p "$name_dir"
	printf '%s' "$port" >"$name_dir/port"
	printf '%s' "$folder" >"$name_dir/folder"
	[ "$mode" = save ] && add_mount "$mounts_dir" "$folder"
	if [ "$keep_alive" = "true" ]; then : >"$keepalive_marker"; else rm -f "$keepalive_marker"; fi

	if [ ! -f "$dockerfile" ]; then
		write_default_dockerfile "$dockerfile"
		info "Wrote default Dockerfile for '$name' to $dockerfile (edit it there, or /home/dev/Dockerfile inside the container)."
	fi
	ensure_dockerignore "$name_dir"

	# Resolve the folders to mount (warnings for any deleted saved folder go to the
	# user here), warn about git for each, then build + run.
	mount_list=$(build_mount_list "$mode" "$folder" "$mounts_dir")
	printf '%s\n' "$mount_list" | while read -r m; do [ -n "$m" ] && warn_git "$m"; done

	[ "$first_create" = true ] && ensure_token "$name" "$name_dir" "$name_env"
	seed_claude "$name_dir/claude"
	[ "$first_create" = true ] && ensure_persona "$name" "$name_dir/claude"
	build_image "$image" "$dockerfile" "$context" "$folder"
	run_container "$name" "$port" "$folder" "$image" "$name_dir/claude" "$docker_sock" "$shared_env" "$name_env" "$dockerfile" "$mount_list" "$keep_alive"

	printf "\n"
	success "Container ready!"
	printf "Port ${YELLOW}%s${NC} → container:8000\n" "$port"
	if [ "$keep_alive" != "true" ]; then
		printf "${CYAN}Idle-suspend on: exit every shell and it stops in ~%ss. Resume with 'dev! %s'.${NC}\n" "${DEV_SUSPEND_IDLE:-20}" "$name"
	fi
	printf "\n"
	attach_container "$name"
}

# List all containers with their status.
cmd_list() {
	if [ ! -d "$STATE_HOME" ]; then
		info "No dev-containers yet. Create one with: dev! <name> [folder]"
		return 0
	fi

	printf "%-16s %-8s %-9s %s\n" "NAME" "PORT" "STATUS" "FOLDERS"
	printf "%-16s %-8s %-9s %s\n" "----------------" "--------" "---------" "-------"

	found=false
	for d in "$STATE_HOME"/*/; do
		[ -d "$d" ] || continue
		found=true
		name=$(basename "$d")
		port=$(cat "$d/port" 2>/dev/null || echo "?")
		n=$(count_mounts "$d/mounts")
		if [ "$n" -eq 0 ]; then
			folder=$(cat "$d/folder" 2>/dev/null || echo "?")
		elif [ "$n" -eq 1 ]; then
			folder=$(first_mount "$d/mounts")
		else
			folder="[$n] $(first_mount "$d/mounts") +$((n - 1))"
		fi
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
		mode=""
		keep_alive=""
		for arg in "$@"; do
			case "$arg" in
			--docker) docker_sock=true ;;
			--keep-alive) keep_alive=true ;;
			--save)
				[ -n "$mode" ] && error "--save and --only are mutually exclusive"
				mode=save
				;;
			--only)
				[ -n "$mode" ] && error "--save and --only are mutually exclusive"
				mode=only
				;;
			-*) error "Unknown option: $arg" ;;
			*) folder_arg="$arg" ;;
			esac
		done
		cmd_up "$name" "$folder_arg" "$docker_sock" "$mode" "$keep_alive"
		;;
	esac
}

main "$@"
