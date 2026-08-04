#!/bin/sh
# agent! - Folder-based Docker container launcher for AI agents
#
# Each named container mounts its accumulated set of saved folders (rw, zero or more)
# plus its own persistent state under ~/.local/agent-container/<name>/ (bus token,
# claude home, ports, folder, and persisted home subdirs ~/.ssh + ~/src). With no
# folder argument nothing new is mapped and the working dir is the agent's home.
# Nothing else on the host is exposed. No git worktrees, no repo bind-mount, no
# docker.sock (unless --docker is passed).

set -e

# Bump this on user-visible behavior changes (see CLAUDE.md).
VERSION="1.3"

# State home: per-name container state lives here. Override for testing.
STATE_HOME="${AGENT_CONTAINER_HOME:-$HOME/.local/agent-container}"

# Home subdirs persisted across recreate/kill by bind-mounting them from the
# container's state dir (<name>/home/<dir>). These hold pure runtime state the
# Dockerfile never writes (unlike ~/.bashrc, ~/.local/bin, dotfiles), so the mounts
# shadow nothing and never go stale. .ssh keeps agent SSH keys; src keeps clones the
# agent makes itself. Space-separated, relative to the login user's home.
PERSIST_DIRS=".ssh src"

show_help() {
	cat <<'EOF'
Usage: agent! [name] [folder] [--save|--only] [--fork] [--keep-alive] [--port H:C] [--docker]
       agent! kill <name>
       agent! completion bash|zsh
       agent! -h | --help
       agent! --version

Launches a named Docker container for an AI agent. A container remembers every folder you
SAVE to it and mounts them all (rw), at their real absolute paths, plus its own
persistent state. The folder argument is OPTIONAL: omit it to map no folder (the agent
gets just its own home + saved set); pass "." to map the current dir. By default it
suspends itself when you're not using it. Free of git repos and worktrees.

Commands:
  (no args)                List all containers: NAME, PORT, STATUS, FOLDERS
  <name>                   Create/resume with no new folder (working dir = agent home)
  <name> <folder>          Create/resume container; ask whether to save the folder
  <name> <folder> --save   Add folder to the set, mount the whole set (needs a folder)
  <name> <folder> --only   Mount JUST this folder, don't remember it (needs a folder)
  <name> <folder> --fork   Pre-answer yes to the fork+clone prompt (see GitHub fork+clone)
  <name> ... --port H:C     Publish container port C on host port H (repeatable;
                           "--port C" auto-assigns a free host port). Applied on recreate.
  <name> ... --keep-alive  Don't self-suspend; run until stopped (see Idle-suspend)
  <name> ... --docker      Also mount /var/run/docker.sock (see Isolation below)
  kill <name>              Stop+remove container and image, delete its state dir
  completion bash|zsh      Output shell completion code
  -h, --help               Show this help
  --version                Print version and exit

Idle-suspend (default on):
  A container's PID 1 is a supervisor that stops the container once no interactive
  shell has been attached for ~20s (override with AGENT_SUSPEND_IDLE). Effectively:
  keep a shell open to keep it alive; exit every shell and it suspends. Resume with
  `agent! <name>` - if nothing changed that's a fast `docker start` that preserves the
  in-container filesystem. Sessions are counted as ptys, so BACKGROUND/detached work
  (a dev server on :8000, a bus agent) does NOT hold it open - use --keep-alive for
  those (it sticks; revert with: rm <STATE_HOME>/<name>/keep-alive).

Mount set (accumulated folders):
  Each container keeps a set of remembered folders as symlinks under
  <STATE_HOME>/<name>/mounts/. --save adds the folder to the set; passing a folder
  with no flag asks (save/only) unless it is already saved. No folder argument adds
  nothing and just mounts the existing set. --only mounts just the given folder for
  this run and remembers nothing. Every save-mode start mounts the WHOLE set; the
  folder you pass (if any) is the working dir. Folders deleted on
  the host are skipped with a warning. Remove one from the set by hand:
      rm <STATE_HOME>/<name>/mounts/<link>
  Docker fixes bind mounts at create time, so changing the set (saving a new
  folder, or --only) takes effect on the next (re)create - a ~1-2s rebuild-free
  docker rm + run; nothing durable is lost.

GitHub fork+clone (isolated agent working copy, opt-in, first create only):
  If the folder is inside a repo with a github.com origin, agent! ASKS (only on
  first create; --fork pre-answers yes, --only/--save skip it) whether to give
  the agent an isolated fork+clone INSTEAD of mounting your live tree. On yes it
  prompts for the agent's GitHub identity (a bot account you create on github.com
  + a PAT with repo+workflow scope), forks the repo to that account, clones the
  fork to <STATE_HOME>/<name>/repo, adds an 'upstream' remote, and checks out a
  branch named after the container. ONLY that clone is mounted - your live tree is
  untouched and never exposed. Inside, the agent commits and runs:
      git push -u origin <name> && gh pr create --repo <owner>/<repo> --fill
  to open a PR from its fork. Identity (GITHUB_AGENT_USER/TOKEN/EMAIL) lives in
  <name>/.env and drives git/gh at runtime. `kill` deletes the local clone; the
  GitHub fork is left intact. Repos with no GitHub origin fall through to a normal
  mount.

Start semantics:
  running   -> if the mount set is unchanged, report and quit; otherwise offer to
               recreate to apply the change (attach: docker exec -it -u <user> agent-<name> bash)
  stopped   -> if the mount set, image and run-mode are unchanged, fast-resume via
               `docker start` (keeps the in-container fs); else recreate. Then attach.
  none      -> confirm, run the token flow, build, run, attach
  No folder argument maps no folder (the saved set, if any, still mounts) and the
  working dir becomes the agent's home. Pass a folder (e.g. ".") to map it; then
  the working dir is that folder.

State layout (STATE_HOME = $AGENT_CONTAINER_HOME or ~/.local/agent-container):
  <STATE_HOME>/.env          shared KEY=value env (AGENT_BUS_URL, GITHUB_USERNAME,
                             GITHUB_TOKEN_DOTFILES, GITCONFIG, ...) - loaded first
  <STATE_HOME>/<name>/.env   per-name KEY=value (AGENT_BUS_TOKEN, GITHUB_AGENT_*
                             for a fork clone, + overrides) - wins
  <STATE_HOME>/<name>/Dockerfile  per-name build recipe (default on first create;
                             bind-mounted rw at ~/Dockerfile so the container
                             can edit it - takes effect on the next recreate)
  <STATE_HOME>/<name>/ports  host:container port pairs, one per line (the primary is
                             <host>:8000; deliberately NOT in .env)
  <STATE_HOME>/<name>/mounts saved folders, one symlink each (name = abs path with
                             '/' as backtick, target = the folder). rm one to forget it.
  <STATE_HOME>/<name>/repo   isolated fork clone (present only with --fork); the
                             sole mounted working copy, origin=fork upstream=orig
  <STATE_HOME>/<name>/folder last folder path (working-dir hint / legacy fallback)
  <STATE_HOME>/<name>/fullname  the login user's GECOS display name (asked on create)
  <STATE_HOME>/<name>/keep-alive  marker: present => opt out of idle-suspend (rm to revert)
  <STATE_HOME>/<name>/claude persistent ~/.claude (seeded once from host ~/.claude)
  <STATE_HOME>/<name>/home   persisted home subdirs bind-mounted into the agent's
                             home so they survive recreate/kill: home/.ssh -> ~/.ssh
                             (keys; kept 0700), home/src -> ~/src (agent's own clones)

Env files:
  Plain KEY=value only (no quotes, no $expansion) so the same file can be sh-sourced
  at build time AND passed to the container via `docker run --env-file`. Order is:
  host env -> shared .env -> per-name .env (later wins). Everything defined there is
  visible inside the container at runtime (including GitHub tokens); the BuildKit
  secret path still keeps the dotfiles token out of image layers.

Dockerfile:
  Each container has its OWN Dockerfile at <STATE_HOME>/<name>/Dockerfile, written
  from a batteries-included default on first create. It is bind-mounted rw at
  ~/Dockerfile, so the container can edit its own build recipe; changes take
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

Identity:
  The container's login user and home are named after it: container 'speedy' runs
  as user 'speedy' with home /home/speedy. Hyphens in the name become underscores
  in the user, so 'speedy-gonzales' -> user 'speedy_gonzales'. On first create you
  are asked for the user's full name (GECOS, shown by finger/pinky), defaulting to
  the title-cased name - so 'speedy' offers "Speedy" but you can type "Speedy
  Gonzales". It is saved to <name>/fullname and reused on every recreate. The host
  UID/GID still drive the user, so bind-mount permissions are unchanged.

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
  agent! api ~/src/api --save   # remember ~/src/api and mount the set
  agent! api ~/src/lib --save   # now mounts BOTH ~/src/api and ~/src/lib
  agent! api ~/scratch --only   # mount just ~/scratch this run, remember nothing
  agent! api . --port 5173      # also publish container :5173 on an auto-assigned host port
  agent! scratch                # current dir; asks whether to save it
  agent! ci . --save --docker   # save current dir + mount docker.sock
  agent!                        # list all containers
  agent! kill api               # tear down 'agent-api' and delete its state
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

# Derive a valid Unix username from a container name (slug). Hyphens become
# underscores; a leading non-letter or a clash with a common system account is
# prefixed with 'u_'. Keeps `whoami` legible while staying adduser-safe. 'agent'
# is left as-is (it is the default fallback user and a normal, unprivileged account).
container_username() {
	u=$(printf '%s' "$1" | tr '-' '_')
	case "$u" in
	[a-z_]*) ;;
	*) u="u_$u" ;;
	esac
	case "$u" in
	agent) ;;
	root | bin | daemon | sys | sync | games | man | lp | mail | news | uucp | operator | nobody | sshd | postgres)
		u="u_$u"
		;;
	esac
	printf '%s' "$u"
}

# Title-cased display name (GECOS) from a slug: hyphens become spaces, each word is
# capitalized. 'speedy' -> "Speedy", 'speedy-gonzales' -> "Speedy Gonzales".
container_fullname() {
	printf '%s' "$1" | tr '-' ' ' | awk '{for (i = 1; i <= NF; i++) $i = toupper(substr($i, 1, 1)) substr($i, 2)} 1'
}

# The in-container login user for a container. Dockerfiles declare `ARG AGENT_USER`
# and get a per-name user + /home/<user>; if a Dockerfile has had AGENT_USER stripped
# out, fall back to 'agent'. Grepping the actual build recipe keeps the build arg,
# mount paths, and attach user in sync, so containers are never mismatched by a rebuild.
resolve_username() {
	if [ -f "$1" ] && grep -q '^ARG AGENT_USER' "$1"; then
		container_username "$2"
	else
		echo agent
	fi
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

# Sorted list of a running container's folder-mount sources. Excludes the
# container's own internal mounts (claude dir + Dockerfile + persisted home subdirs
# under name_dir) and docker.sock, but KEEPS a fork clone at <name_dir>/repo - it is
# a real folder mount, so it must stay in the diff or resume would recreate on every run.
current_folder_mounts() {
	cfm_container="$1"
	cfm_name_dir="$2"
	docker inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$cfm_container" 2>/dev/null |
		while IFS= read -r src; do
			[ -n "$src" ] || continue
			case "$src" in
			"$cfm_name_dir"/claude | "$cfm_name_dir"/Dockerfile) continue ;;
			"$cfm_name_dir"/home/*) continue ;;
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
# Shared agent-container env. Plain KEY=value only (no quotes, no \$expansion): this
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

# --- Port set (host:container mappings) ----------------------------------------
# A container's published ports live in <name>/ports, one HOST:CONTAINER pair per
# line (docker's own -p order); the primary web port is <host>:8000. Host ports are
# globally unique across all containers, and the next free one is derived by scanning
# every ports file (no stored counter), so hand-edits and kills self-heal.

# Every host port claimed across all containers (left side of each pair), one per line.
used_host_ports() {
	for pf in "$STATE_HOME"/*/ports; do
		[ -f "$pf" ] || continue
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			printf '%s\n' "${line%%:*}"
		done <"$pf"
	done
}

# Prompt (stderr) for the very first host port when no container owns one yet.
# Echoes the validated port to stdout.
prompt_starting_port() {
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
}

# Next free host port: 1 + max(all claimed host ports UNION the reserved list in $1),
# or a prompted starting port when nothing is claimed anywhere yet. $1 is a
# newline/space list of in-flight host ports not yet on disk, so one run can assign
# several without collisions.
next_host_port() {
	max=""
	# shellcheck disable=SC2046,SC2086
	for p in $(used_host_ports) $1; do
		[ -n "$p" ] || continue
		if [ -z "$max" ] || { [ "$p" -gt "$max" ] 2>/dev/null; }; then
			max="$p"
		fi
	done
	if [ -z "$max" ]; then
		prompt_starting_port
	else
		echo $((max + 1))
	fi
}

# Build the desired HOST:CONTAINER set (newline pairs) for a container: its existing
# ports file (or a freshly allocated <host>:8000 primary on first create) plus any
# `--port` specs passed as extra args. A spec is "C" (auto-assign the host port) or
# "H:C" (explicit host port). A spec whose container port is already mapped is
# ignored; an explicit host-port clash is an error. Echoes the set; primary stays first.
build_desired_ports() {
	bp_dir="$1"
	shift
	if [ -s "$bp_dir/ports" ]; then
		desired=$(grep -v '^[[:space:]]*$' "$bp_dir/ports")
	else
		desired="$(next_host_port "")":8000
	fi
	for spec in "$@"; do
		[ -n "$spec" ] || continue
		case "$spec" in
		*:*)
			hport="${spec%%:*}"
			cport="${spec#*:}"
			;;
		*)
			hport=""
			cport="$spec"
			;;
		esac
		echo "$cport" | grep -qE '^[0-9]+$' || error "Invalid --port container port: $spec"
		printf '%s\n' "$desired" | grep -q ":${cport}\$" && continue
		if [ -n "$hport" ]; then
			echo "$hport" | grep -qE '^[0-9]+$' || error "Invalid --port host port: $spec"
			printf '%s\n' "$desired" | grep -q "^${hport}:" &&
				error "Host port $hport is already mapped for this container"
		else
			hport=$(next_host_port "$(printf '%s\n' "$desired" | cut -d: -f1)")
		fi
		desired="$desired
$hport:$cport"
	done
	printf '%s\n' "$desired"
}

# The primary host port (the pair whose container side is 8000, else the first pair)
# from a newline list of HOST:CONTAINER pairs. Empty when the list is empty.
primary_host_port() {
	printf '%s\n' "$1" | awk -F: '
		NF { if (!seen) { first = $1; seen = 1 }
		     if ($2 == 8000) { print $1; found = 1; exit } }
		END { if (!found && seen) print first }'
}

# Format a newline pair list as "H->C, H->C" for display.
format_ports() {
	printf '%s\n' "$1" | awk -F: 'NF { printf "%s%s->%s", sep, $1, $2; sep = ", " } END { print "" }'
}

# A running container's actual published bindings as sorted HOST:CONTAINER pairs
# (tcp), to diff against the desired set when deciding whether to recreate.
current_port_bindings() {
	docker inspect -f '{{range $p, $c := .HostConfig.PortBindings}}{{(index $c 0).HostPort}}:{{$p}}{{"\n"}}{{end}}' "$1" 2>/dev/null |
		sed 's|/tcp||' | grep -v '^$' | sort -u
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

# --- GitHub fork+clone (isolated per-agent working copy) -----------------------
# Instead of mounting a live repo (agent edits your working tree), an agent can
# get a self-contained clone of its OWN GitHub fork under <name>/repo - the only
# thing mounted. It commits there and opens a PR from the fork. See ensure_/setup_.

# Echo the GitHub "owner/repo" for a folder's origin remote, or return 1. Handles
# ssh (git@github.com:owner/repo.git), https, and scp-less URL forms; strips .git.
github_remote() {
	gr_url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
	case "$gr_url" in
	*github.com*) ;;
	*) return 1 ;;
	esac
	# Drop scheme/host/user, keep the "owner/repo" path, strip a trailing .git.
	gr_path=$(printf '%s' "$gr_url" | sed -E 's#^[a-z]+://##; s#^[^/@]*@##; s#^github\.com[:/]##; s#\.git$##')
	case "$gr_path" in
	*/*) printf '%s' "$gr_path" ;;
	*) return 1 ;;
	esac
}

# Prompt for and persist the agent's GitHub identity (username + PAT + email) if
# <name>/.env lacks a non-empty GITHUB_AGENT_TOKEN. Modeled on ensure_token. The
# token is validated against the real account; a mismatch is a warning, not fatal.
ensure_github_identity() {
	name="$1"
	name_dir="$2"
	name_env="$3"

	if [ -f "$name_env" ] && grep -qE '^GITHUB_AGENT_TOKEN=.+' "$name_env"; then
		return 0
	fi

	printf "\n"
	printf "${CYAN}GitHub identity for agent '%s'.${NC}\n" "$name"
	printf "Create a bot account on github.com first, then a Personal Access Token\n"
	printf "with repo + workflow scope (classic) or contents/PR/fork write (fine-grained).\n"
	printf "GitHub username (blank to skip): "
	read -r gh_user
	if [ -z "$gh_user" ]; then
		info "Skipping GitHub identity."
		return 1
	fi
	printf "Personal Access Token: "
	read -r gh_token
	if [ -z "$gh_token" ]; then
		info "Empty token, skipping GitHub identity."
		return 1
	fi
	printf "Commit email [%s@users.noreply.github.com]: " "$gh_user"
	read -r gh_email
	[ -z "$gh_email" ] && gh_email="$gh_user@users.noreply.github.com"

	# Validate the token maps to the given account (best-effort; warn on mismatch).
	if command -v gh >/dev/null 2>&1; then
		actual=$(GH_TOKEN="$gh_token" gh api user --jq .login 2>/dev/null) || actual=""
		if [ -z "$actual" ]; then
			printf "${YELLOW}Warning: could not validate the token with 'gh api user' - continuing anyway.${NC}\n" >&2
		elif [ "$actual" != "$gh_user" ]; then
			printf "${YELLOW}Warning: token belongs to '%s', not '%s'. Using the token's account.${NC}\n" "$actual" "$gh_user" >&2
			gh_user="$actual"
		fi
	fi

	mkdir -p "$name_dir"
	if [ ! -f "$name_env" ]; then
		cat >"$name_env" <<EOF
# Per-name agent-container env. Plain KEY=value only (no quotes, no \$expansion).
# Overrides the shared $STATE_HOME/.env.
EOF
	fi
	{
		printf 'GITHUB_AGENT_USER=%s\n' "$gh_user"
		printf 'GITHUB_AGENT_TOKEN=%s\n' "$gh_token"
		printf 'GITHUB_AGENT_EMAIL=%s\n' "$gh_email"
	} >>"$name_env"
	export GITHUB_AGENT_USER="$gh_user" GITHUB_AGENT_TOKEN="$gh_token" GITHUB_AGENT_EMAIL="$gh_email"
	success "GitHub identity for '$gh_user' written to $name_env"
	return 0
}

# Fork <upstream> to the agent's account, clone the fork into <name>/repo, add an
# 'upstream' remote, and create the working branch (= container name). Uses the
# agent's token (GITHUB_AGENT_TOKEN) for all operations. Idempotent: if the clone
# dir already exists it is left as-is. Echoes the clone path on success; returns 1
# on any failure so the caller can fall back to a normal folder mount.
setup_github_clone() {
	name="$1"
	name_dir="$2"
	upstream="$3"
	clone_dir="$name_dir/repo"

	if [ -d "$clone_dir" ]; then
		printf '%s' "$clone_dir"
		return 0
	fi
	command -v gh >/dev/null 2>&1 || {
		printf "${YELLOW}Warning: 'gh' not found on host; cannot set up the fork. Falling back to a normal mount.${NC}\n" >&2
		return 1
	}
	[ -n "${GITHUB_AGENT_TOKEN:-}" ] || return 1

	repo_name=${upstream#*/}

	info "Forking $upstream to the agent's account..." >&2
	GH_TOKEN="$GITHUB_AGENT_TOKEN" gh repo fork "$upstream" --clone=false --remote=false >&2 2>&1 || {
		printf "${YELLOW}Warning: 'gh repo fork' failed. Falling back to a normal mount.${NC}\n" >&2
		return 1
	}

	fork="$GITHUB_AGENT_USER/$repo_name"
	info "Cloning fork $fork into $clone_dir..." >&2
	# A freshly created fork can take a moment to become clonable - retry briefly.
	i=0
	while [ "$i" -lt 5 ]; do
		if GH_TOKEN="$GITHUB_AGENT_TOKEN" gh repo clone "$fork" "$clone_dir" >&2 2>&1; then
			break
		fi
		i=$((i + 1))
		[ "$i" -lt 5 ] && sleep 3
	done
	if [ ! -d "$clone_dir/.git" ]; then
		printf "${YELLOW}Warning: could not clone the fork after retries. Falling back to a normal mount.${NC}\n" >&2
		rm -rf "$clone_dir"
		return 1
	fi

	git -C "$clone_dir" remote add upstream "https://github.com/$upstream.git" 2>/dev/null || true
	git -C "$clone_dir" checkout -b "$name" >&2 2>&1 || true
	printf '%s' "$clone_dir"
	return 0
}

# Create the persisted home subdirs (PERSIST_DIRS) under <name>/home so they exist to
# bind-mount into the agent's home. Idempotent. .ssh gets 700 or OpenSSH refuses the
# keys inside (the entrypoint re-chmods at runtime too, in case a host copy is looser).
ensure_persist_dirs() {
	epd_root="$1"
	for pd in $PERSIST_DIRS; do
		d="$epd_root/$pd"
		[ -d "$d" ] && continue
		mkdir -p "$d"
		[ "$pd" = ".ssh" ] && chmod 700 "$d"
	done
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
# Auto-generated by agent!. Keeps the build context small and secret-free.
# The Dockerfile lives in this dir alongside container state; ignore the state.
.env
ports
folder
fullname
claude
mounts
repo
home
.build-sig
EOF
		return 0
	fi
	# Upgrade older ignore files (mounts/ can contain symlinks to large host
	# folders; repo/ is a fork clone; home/ holds persisted home subdirs;
	# .build-sig is the build cache marker - none belong in the build context).
	for entry in mounts repo home .build-sig fullname; do
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
# Per-name agent-container env. Plain KEY=value only (no quotes, no \$expansion).
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

# Prompt (first create only) for the login user's GECOS display name, defaulting to
# the title-cased container name. A single word like 'speedy' derives "Speedy", so
# this is the chance to give it a real full name ("Speedy Gonzales"). Persisted to
# <name>/fullname so recreates keep it; blank accepts the default.
ensure_fullname() {
	name="$1"
	name_dir="$2"
	ff="$name_dir/fullname"
	[ -f "$ff" ] && return 0
	default=$(container_fullname "$name")
	printf "\n"
	printf "${CYAN}Full name for the '%s' user (GECOS, shown by finger/pinky)?${NC}\n" "$(container_username "$name")"
	printf "Full name [%s]: " "$default"
	read -r fn
	[ -z "$fn" ] && fn="$default"
	mkdir -p "$name_dir"
	printf '%s' "$fn" >"$ff"
	success "Full name set to '$fn'."
}

# The persisted GECOS full name, or the title-cased container name if none is saved
# (legacy containers, or one whose fullname file was removed).
read_fullname() {
	if [ -s "$1/fullname" ]; then
		cat "$1/fullname"
	else
		container_fullname "$2"
	fi
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
	agent_user="$5"
	agent_fullname="$6"

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
		--build-arg AGENT_USER="${agent_user}" \
		--build-arg AGENT_FULLNAME="${agent_fullname}" \
		-t "$image" "$context"
	docker "$@"

	[ -n "$token_file" ] && rm -f "$token_file" || true
	printf '%s' "$sig" >"$sig_file"
}

# The container's PID 1. By default a self-suspend supervisor: it waits for the
# first interactive session, then exits (stopping the container) once no session
# has been attached for AGENT_SUSPEND_IDLE seconds. Sessions are counted as numeric
# slave nodes under /dev/pts (every `docker exec -it` allocates one), so it tracks
# ALL attached shells, not just the one agent! launched. Background/detached work
# holds no pty, so it does NOT keep the container alive - see --keep-alive.
SUPERVISOR_CMD='
idle_limit=${AGENT_SUSPEND_IDLE:-20}
startup_limit=${AGENT_SUSPEND_STARTUP:-120}
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
# the same absolute path; every pair in port_list (newline HOST:CONTAINER) is
# published; cwd is this invocation's folder. keep_alive=true swaps the self-suspend
# supervisor for a plain never-exit daemon.
run_container() {
	name="$1"
	port_list="$2"
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
	agent_user=$(resolve_username "$dockerfile" "$name")

	set -- --init -d \
		--name "agent-$name" \
		--hostname "$name" \
		-e "CLAUDE_CODE_CREDENTIALS=${claude_creds}" \
		-e "CLAUDE_JSON=${claude_json}"

	oldifs=$IFS
	IFS='
'
	for p in $port_list; do
		[ -n "$p" ] || continue
		set -- "$@" -p "$p"
	done
	IFS=$oldifs

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
		-v "${claude_dir}:/home/${agent_user}/.claude" \
		-v "${dockerfile}:/home/${agent_user}/Dockerfile" \
		-w "${cwd}"

	# Persisted home subdirs (PERSIST_DIRS): bind-mounted from <name>/home so ~/.ssh
	# keys and ~/src clones survive recreate/kill. The Dockerfile never writes these
	# paths, so the mounts shadow nothing.
	name_dir="$STATE_HOME/$name"
	for pd in $PERSIST_DIRS; do
		set -- "$@" -v "${name_dir}/home/${pd}:/home/${agent_user}/${pd}"
	done

	[ "$docker_sock" = "true" ] && set -- "$@" -v /var/run/docker.sock:/var/run/docker.sock

	if [ "$keep_alive" = "true" ]; then
		set -- "$@" "$image" tail -f /dev/null
	else
		set -- "$@" "$image" sh -c "$SUPERVISOR_CMD"
	fi

	info "Starting container 'agent-$name'..."
	docker run "$@"
}

# Attach an interactive shell as the container's login user (self-resolved from
# its Dockerfile so fast-resume and recreate paths all agree on the user).
attach_container() {
	au_user=$(resolve_username "$STATE_HOME/$1/Dockerfile" "$1")
	docker exec -it -e TERM=xterm-256color -e COLORTERM=truecolor -u "$au_user" "agent-$1" bash
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
# matters); keep_alive is "true" (opt out of idle-suspend) or ""; want_fork is
# "true" (pre-answer the fork prompt yes) or "".
cmd_up() {
	name=$(slugify "$1")
	folder_arg="$2"
	docker_sock="$3"
	mode="$4"
	keep_alive="$5"
	port_specs="$6"
	want_fork="$7"
	[ -n "$name" ] || error "Invalid name"

	container="agent-$name"
	image="agent-$name"
	name_dir="$STATE_HOME/$name"
	name_env="$name_dir/.env"
	shared_env="$STATE_HOME/.env"
	mounts_dir="$name_dir/mounts"
	dockerfile="$name_dir/Dockerfile"
	context="$name_dir"
	keepalive_marker="$name_dir/keep-alive"

	# Folder is now OPTIONAL. No folder argument -> mount nothing new (the saved set,
	# if any, still mounts); the working dir becomes the agent's home. Pass "." to map
	# the current dir. The folder-referencing flags need an actual folder.
	if [ -n "$folder_arg" ]; then
		folder=$(resolve_folder "$folder_arg")
		have_folder=true
	else
		folder=""
		have_folder=false
		[ "$mode" = only ] && error "--only needs a folder (nothing to mount)"
		[ "$mode" = save ] && error "--save needs a folder (nothing to save)"
		[ "$want_fork" = true ] && error "--fork needs a folder inside a GitHub repo"
	fi
	# The container's working dir / HOST_PROJECT_PATH. With a folder mapped it is that
	# folder. With no folder it is the agent's home on a fresh create, but an EXISTING
	# container inherits its recorded working dir (the `folder` marker) so that a bare
	# `agent! <name>` resume doesn't change the baked WORKDIR and force a rebuild.
	# Predict the login user the same way the build will (a first create always writes
	# an AGENT_USER Dockerfile) so it stays in sync.
	if [ -f "$dockerfile" ]; then
		workdir_home="/home/$(resolve_username "$dockerfile" "$name")"
	else
		workdir_home="/home/$(container_username "$name")"
	fi
	if [ "$have_folder" = true ]; then
		workdir="$folder"
	elif [ -s "$name_dir/folder" ]; then
		workdir=$(cat "$name_dir/folder")
	else
		workdir="$workdir_home"
	fi
	migrate_legacy_folder "$name_dir"

	status=$(get_container_status "$container")
	first_create=false
	[ "$status" = "none" ] && first_create=true

	# Fork decision (strictly opt-in, first create only): when the folder is inside
	# a GitHub repo, offer an isolated fork+clone instead of mounting the live tree.
	# Offered only when no mode flag was given (the ambiguous case) or --fork was
	# passed; only an explicit yes enables it. Everything else falls through to a
	# normal folder mount. The clone becomes the sole mounted working copy.
	use_fork=false
	gh_upstream=""
	if [ "$have_folder" = true ] && [ "$first_create" = true ] &&
		{ [ "$want_fork" = true ] || [ -z "$mode" ]; } &&
		gh_upstream=$(github_remote "$folder"); then
		if [ "$want_fork" = true ]; then
			use_fork=true
		else
			printf "\n"
			printf "${CYAN}%s is a GitHub repo (%s).${NC}\n" "$folder" "$gh_upstream"
			printf "Create an isolated fork+clone for this agent instead of mounting it directly? [y/n] "
			read -r fork_ans
			case "$fork_ans" in [Yy] | [Yy][Ee][Ss]) use_fork=true ;; esac
		fi
	fi
	[ "$use_fork" = true ] && mode=save

	# Resolve the mode. With no folder there is nothing to save/ask about (mode stays
	# empty -> the whole saved set still mounts). Otherwise, if no flag: an
	# already-saved folder needs no decision (just start the set); anything else is
	# ambiguous, so ask. Skipped when forking (the clone is force-saved above).
	if [ "$have_folder" = true ] && [ "$use_fork" = false ] && [ -z "$mode" ]; then
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
	# shellcheck disable=SC2086
	desired_ports=$(build_desired_ports "$name_dir" $port_specs)

	# Running: compare the running mount set to what this invocation wants. Same ->
	# just report. Different -> the change (a newly saved folder, or --only) needs a
	# recreate to apply, since Docker fixes bind mounts at create time.
	if [ "$status" = "running" ]; then
		[ "$mode" = save ] && add_mount "$mounts_dir" "$folder"
		desired=$(build_mount_list "$mode" "$folder" "$mounts_dir" 2>/dev/null | sort -u)
		current=$(current_folder_mounts "$container" "$name_dir")
		desired_p=$(printf '%s\n' "$desired_ports" | sort -u)
		current_p=$(current_port_bindings "$container")
		if [ "$desired" = "$current" ] && [ "$desired_p" = "$current_p" ]; then
			info "Container '$container' is already running."
			printf "Ports ${YELLOW}%s${NC}\n" "$(format_ports "$desired_ports")"
			printf "Attach with: ${CYAN}docker exec -it -u %s %s bash${NC}\n" "$(resolve_username "$dockerfile" "$name")" "$container"
			exit 0
		fi
		printf "\n"
		info "Config differs from the running '$container'. It will have:"
		printf '%s\n' "$desired" | while read -r m; do [ -n "$m" ] && printf "  mount ${YELLOW}%s${NC}\n" "$m"; done || true
		printf "  ports ${YELLOW}%s${NC}\n" "$(format_ports "$desired_ports")"
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
		desired_p=$(printf '%s\n' "$desired_ports" | sort -u)
		current_p=$(current_port_bindings "$container")
		if [ "$desired" = "$current" ] && [ "$desired_p" = "$current_p" ] &&
			image_up_to_date "$image" "$dockerfile" "$context" "$workdir" &&
			[ "$(container_keepalive "$container")" = "$keep_alive" ]; then
			info "Resuming '$container'..."
			docker start "$container" >/dev/null
			printf "\n"
			success "Container resumed!"
			printf "Ports ${YELLOW}%s${NC}\n\n" "$(format_ports "$desired_ports")"
			attach_container "$name"
			exit 0
		fi
	fi

	# First create: confirm before writing any state (an abort leaves nothing behind).
	if [ "$first_create" = true ]; then
		printf "\n"
		info "Will create:"
		printf "  Name:       ${YELLOW}%s${NC}\n" "$name"
		printf "  User:       ${YELLOW}%s${NC} (home /home/%s; full name asked below)\n" "$(container_username "$name")" "$(container_username "$name")"
		if [ "$use_fork" = true ]; then
			printf "  Repo:       ${YELLOW}%s${NC} (GitHub)\n" "$gh_upstream"
			printf "  Fork clone: ${YELLOW}%s/repo${NC} (fork to the agent, clone here, branch '%s')\n" "$name_dir" "$name"
			printf "              ${CYAN}isolated: only the clone is mounted, not %s${NC}\n" "$folder"
		elif [ "$have_folder" = false ]; then
			printf "  Folder:     ${YELLOW}(none)${NC} - no folder mapped; working dir %s\n" "$workdir"
		elif [ "$mode" = only ]; then
			printf "  Folder:     ${YELLOW}%s${NC} (only - not saved)\n" "$folder"
		else
			printf "  Folder:     ${YELLOW}%s${NC} (saved to the set)\n" "$folder"
		fi
		printf "  Container:  ${YELLOW}%s${NC}\n" "$container"
		printf "  Ports:      ${YELLOW}%s${NC}\n" "$(format_ports "$desired_ports")"
		printf "  Dockerfile: ${YELLOW}%s${NC}\n" "$dockerfile"
		if [ "$keep_alive" = "true" ]; then
			printf "  Run mode:   ${YELLOW}keep-alive${NC} (stays up until stopped)\n"
		else
			printf "  Run mode:   ${YELLOW}suspend when idle${NC} (stops ~%ss after the last shell exits)\n" "${AGENT_SUSPEND_IDLE:-20}"
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

	# Set up the isolated fork clone now (past the confirm gate). On success the
	# clone replaces the host folder as the mounted working copy (mode is already
	# 'save', so it joins the set); on any failure fall back to mounting the folder
	# directly - still with mode=save, so the container is never left with no mount.
	if [ "$use_fork" = true ]; then
		if ensure_github_identity "$name" "$name_dir" "$name_env" &&
			clone=$(setup_github_clone "$name" "$name_dir" "$gh_upstream"); then
			load_env_files "$shared_env" "$name_env"
			folder="$clone"
			workdir="$clone"
			success "Fork clone ready: $clone"
		else
			use_fork=false
			printf "${YELLOW}Fork setup skipped; mounting %s directly instead.${NC}\n" "$folder" >&2
		fi
	fi

	printf '%s\n' "$desired_ports" >"$name_dir/ports"
	[ "$have_folder" = true ] && printf '%s' "$folder" >"$name_dir/folder"
	[ "$mode" = save ] && [ "$have_folder" = true ] && add_mount "$mounts_dir" "$folder"
	if [ "$keep_alive" = "true" ]; then : >"$keepalive_marker"; else rm -f "$keepalive_marker"; fi

	if [ ! -f "$dockerfile" ]; then
		write_default_dockerfile "$dockerfile"
		info "Wrote default Dockerfile for '$name' to $dockerfile (edit it there, or ~/Dockerfile inside the container)."
	fi
	ensure_dockerignore "$name_dir"

	# Resolve the folders to mount (warnings for any deleted saved folder go to the
	# user here), warn about git for each, then build + run.
	mount_list=$(build_mount_list "$mode" "$folder" "$mounts_dir")
	# `|| true`: an empty mount set makes the loop body's last test false, which would
	# otherwise trip `set -e` on this pipeline.
	printf '%s\n' "$mount_list" | while read -r m; do [ -n "$m" ] && warn_git "$m"; done || true

	[ "$first_create" = true ] && ensure_token "$name" "$name_dir" "$name_env"
	seed_claude "$name_dir/claude"
	ensure_persist_dirs "$name_dir/home"
	[ "$first_create" = true ] && ensure_persona "$name" "$name_dir/claude"
	[ "$first_create" = true ] && ensure_fullname "$name" "$name_dir"
	# The Dockerfile now exists, so this reflects the real (new-style vs legacy) user.
	agent_user=$(resolve_username "$dockerfile" "$name")
	agent_fullname=$(read_fullname "$name_dir" "$name")
	# No folder, fresh container (no recorded working dir): use the now-authoritative
	# agent home. An existing container keeps its inherited workdir (set above).
	[ "$have_folder" = false ] && [ ! -s "$name_dir/folder" ] && workdir="/home/$agent_user"
	build_image "$image" "$dockerfile" "$context" "$workdir" "$agent_user" "$agent_fullname"
	run_container "$name" "$desired_ports" "$workdir" "$image" "$name_dir/claude" "$docker_sock" "$shared_env" "$name_env" "$dockerfile" "$mount_list" "$keep_alive"

	printf "\n"
	success "Container ready!"
	printf "Ports ${YELLOW}%s${NC}\n" "$(format_ports "$desired_ports")"
	if [ "$use_fork" = true ]; then
		printf "${CYAN}Isolated fork clone at %s (origin=your fork, upstream=%s, branch '%s').${NC}\n" "$folder" "$gh_upstream" "$name"
		printf "${CYAN}Inside: commit, 'git push -u origin %s', then 'gh pr create --repo %s --fill'.${NC}\n" "$name" "$gh_upstream"
	fi
	if [ "$keep_alive" != "true" ]; then
		printf "${CYAN}Idle-suspend on: exit every shell and it stops in ~%ss. Resume with 'agent! %s'.${NC}\n" "${AGENT_SUSPEND_IDLE:-20}" "$name"
	fi
	printf "\n"
	attach_container "$name"
}

# List all containers with their status.
cmd_list() {
	if [ ! -d "$STATE_HOME" ]; then
		info "No agent containers yet. Create one with: agent! <name> [folder]"
		return 0
	fi

	printf "%-16s %-8s %-9s %s\n" "NAME" "PORT" "STATUS" "FOLDERS"
	printf "%-16s %-8s %-9s %s\n" "----------------" "--------" "---------" "-------"

	found=false
	for d in "$STATE_HOME"/*/; do
		[ -d "$d" ] || continue
		found=true
		name=$(basename "$d")
		pcontent=$(cat "$d/ports" 2>/dev/null || true)
		if [ -n "$pcontent" ]; then
			port=$(primary_host_port "$pcontent")
			np=$(printf '%s\n' "$pcontent" | grep -c '.')
			[ "$np" -gt 1 ] && port="$port+$((np - 1))"
		else
			port="?"
		fi
		n=$(count_mounts "$d/mounts")
		if [ "$n" -eq 0 ]; then
			folder=$(cat "$d/folder" 2>/dev/null || echo "(none)")
			[ -n "$folder" ] || folder="(none)"
		elif [ "$n" -eq 1 ]; then
			folder=$(first_mount "$d/mounts")
		else
			folder="[$n] $(first_mount "$d/mounts") +$((n - 1))"
		fi
		status=$(get_container_status "agent-$name")
		case "$status" in
		running) printf "%-16s %-8s ${GREEN}%-9s${NC} %s\n" "$name" "$port" "running" "$folder" ;;
		stopped) printf "%-16s %-8s ${YELLOW}%-9s${NC} %s\n" "$name" "$port" "stopped" "$folder" ;;
		*) printf "%-16s %-8s ${RED}%-9s${NC} %s\n" "$name" "$port" "none" "$folder" ;;
		esac
	done

	[ "$found" = false ] && info "No agent containers yet. Create one with: agent! <name> [folder]"
	return 0
}

# Stop+remove container and image, delete the state dir.
cmd_kill() {
	name=$(slugify "$1")
	[ -n "$name" ] || error "Usage: agent! kill <name>"
	container="agent-$name"
	name_dir="$STATE_HOME/$name"
	port=$(primary_host_port "$(cat "$name_dir/ports" 2>/dev/null || true)")
	[ -n "$port" ] || port="?"

	printf "\n${RED}Will kill:${NC}\n"
	printf "  Container: ${YELLOW}%s${NC}\n" "$container"
	printf "  Image:     ${YELLOW}%s${NC}\n" "agent-$name"
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

	docker rmi "agent-$name" >/dev/null 2>&1 || true
	had_fork=false
	[ -d "$name_dir/repo" ] && had_fork=true
	[ -d "$name_dir" ] && rm -rf "$name_dir"

	printf "\n"
	success "Killed '$name' (port $port)"
	[ "$had_fork" = true ] && info "The GitHub fork on the agent's account was left intact."
}

# Write the batteries-included default Dockerfile to $1. Alpine-based: bash/git/curl,
# Claude Code, chezmoi dotfiles, tmux, and an entrypoint that materializes Claude
# creds from env. Written once per container to <STATE_HOME>/<name>/Dockerfile on
# first create, then owned/editable by that container via the ~/Dockerfile mount.
# Quoted heredoc: everything below is literal (Dockerfile ARGs, not shell vars).
write_default_dockerfile() {
	cat >"$1" <<'DOCKERFILE'
# Dockerfile - default container generated by agent! (edit to taste).
# Minimum requirement: a login user with bash (named by AGENT_USER).

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
    github-cli \
    tmux \
    vim \
    openssh-client

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# === BUILD ARGS (passed by agent!) ===
ARG GITCONFIG=""         # Contents of host ~/.gitconfig
ARG GITHUB_USERNAME=""   # For dotfiles repo (optional)
ARG HOST_PROJECT_PATH="/home/agent/src"  # Target folder path, for path parity with host
ARG HOST_UID=1000        # Host user's UID (for volume permission parity)
ARG HOST_GID=1000        # Host user's GID
ARG AGENT_USER=agent       # In-container login user + home (defaults to the container name)
ARG AGENT_FULLNAME=Agent   # GECOS display name (what finger/pinky show)

# Create the login user (password 'agent') matching host UID/GID where possible.
# Name and home come from AGENT_USER; AGENT_FULLNAME is the GECOS. Falls back cleanly
# when the host GID/UID collides with an existing one. A NOPASSWD sudoers.d drop-in
# gives the user passwordless sudo (no security loss — the password is the fixed
# literal 'agent' anyway); visudo -cf validates the drop-in at build time.
RUN (addgroup -g "${HOST_GID}" "${AGENT_USER}" 2>/dev/null || addgroup "${AGENT_USER}") \
    && (adduser -D -u "${HOST_UID}" -G "${AGENT_USER}" -g "${AGENT_FULLNAME}" -s /bin/bash "${AGENT_USER}" 2>/dev/null \
        || adduser -D -G "${AGENT_USER}" -g "${AGENT_FULLNAME}" -s /bin/bash "${AGENT_USER}") \
    && echo "${AGENT_USER}:agent" | chpasswd \
    && addgroup "${AGENT_USER}" wheel \
    && addgroup "${AGENT_USER}" root \
    && echo "${AGENT_USER} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/"${AGENT_USER}" \
    && chmod 0440 /etc/sudoers.d/"${AGENT_USER}" \
    && visudo -cf /etc/sudoers.d/"${AGENT_USER}"

# Copy host user's git config (passed as build arg)
RUN if [ -n "$GITCONFIG" ]; then echo "$GITCONFIG" > /home/${AGENT_USER}/.gitconfig && chown ${AGENT_USER}:${AGENT_USER} /home/${AGENT_USER}/.gitconfig; fi

# Create host path directory structure (as root for arbitrary paths like /Users/...)
RUN mkdir -p "${HOST_PROJECT_PATH}" && chown -R ${AGENT_USER}:${AGENT_USER} "$(echo ${HOST_PROJECT_PATH} | cut -d'/' -f1-2)"

# Entrypoint to inject Claude config from env vars. Written as root to a fixed path
# so the ENTRYPOINT is independent of the user/home; ~ resolves to the login user's
# home at runtime, since the container's main process runs as ${AGENT_USER}.
RUN <<'SCRIPT' cat > /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh
#!/bin/bash
if [ -n "$CLAUDE_CODE_CREDENTIALS" ]; then
  mkdir -p ~/.claude
  echo "$CLAUDE_CODE_CREDENTIALS" > ~/.claude/.credentials.json
fi
if [ -n "$CLAUDE_JSON" ]; then
  echo "$CLAUDE_JSON" > ~/.claude.json
fi
# ~/.ssh is a persisted bind mount (agent! PERSIST_DIRS); OpenSSH refuses keys unless
# the dir is 0700. Tighten it here in case the host copy carries looser perms.
if [ -d ~/.ssh ]; then chmod 700 ~/.ssh 2>/dev/null || true; fi
exec "$@"
SCRIPT

# Switch to the login user for remaining setup
USER ${AGENT_USER}
WORKDIR /home/${AGENT_USER}

RUN mkdir -p /home/${AGENT_USER}/.local/bin

# Configure shell: PATH, aliases ($HOME keeps this home-independent)
RUN echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc \
    && echo "alias claude!='claude --dangerously-skip-permissions --thinking-display summarized'" >> ~/.bashrc \
    && echo "alias ll='ls -la'" >> ~/.bashrc

# Agent GitHub identity: when a per-agent PAT is injected at runtime (env vars
# GITHUB_AGENT_USER/TOKEN/EMAIL, set by agent!'s fork+clone flow via --env-file),
# wire up gh + git so 'git push' and 'gh pr create' act as the agent. The
# credential helper is stored single-quoted, so $GITHUB_AGENT_TOKEN is expanded by
# git at push time (from the env), never written to disk. A no-op without a token.
RUN <<'BASHRC' cat >> ~/.bashrc
if [ -n "$GITHUB_AGENT_TOKEN" ]; then
  export GH_TOKEN="$GITHUB_AGENT_TOKEN"
  git config --global credential.helper '!f() { echo username=x-access-token; echo "password=$GITHUB_AGENT_TOKEN"; }; f'
  [ -n "$GITHUB_AGENT_USER" ] && git config --global user.name "$GITHUB_AGENT_USER"
  [ -n "$GITHUB_AGENT_EMAIL" ] && git config --global user.email "$GITHUB_AGENT_EMAIL"
fi
BASHRC

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
RUN echo '#!/bin/sh' > /home/${AGENT_USER}/.local/bin/afplay \
    && echo 'exit 0' >> /home/${AGENT_USER}/.local/bin/afplay \
    && chmod +x /home/${AGENT_USER}/.local/bin/afplay

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Re-declare ARG after USER switch (ARGs don't persist)
ARG HOST_PROJECT_PATH="/home/agent/src"
WORKDIR ${HOST_PROJECT_PATH}
DOCKERFILE
}

# Output shell completion code
cmd_completion() {
	case "$1" in
	bash)
		cat <<'EOF'
_agent_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"
    local state="${AGENT_CONTAINER_HOME:-$HOME/.local/agent-container}"
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
complete -F _agent_complete agent-container.sh
EOF
		;;
	zsh)
		cat <<'EOF'
_agent_complete() {
    local state="${AGENT_CONTAINER_HOME:-$HOME/.local/agent-container}"
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
compdef _agent_complete agent-container.sh
EOF
		;;
	*)
		echo "Usage: agent-container.sh completion [bash|zsh]" >&2
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
		[ -n "$2" ] || error "Usage: agent! kill <name>"
		cmd_kill "$2"
		exit 0
		;;
	completion)
		[ -n "$2" ] || error "Usage: agent! completion bash|zsh"
		cmd_completion "$2"
		exit 0
		;;
	*)
		name="$1"
		shift
		folder_arg=""
		docker_sock=false
		mode=""
		keep_alive=""
		port_specs=""
		want_fork=""
		while [ $# -gt 0 ]; do
			case "$1" in
			--docker) docker_sock=true ;;
			--keep-alive) keep_alive=true ;;
			--fork) want_fork=true ;;
			--save)
				[ -n "$mode" ] && error "--save and --only are mutually exclusive"
				mode=save
				;;
			--only)
				[ -n "$mode" ] && error "--save and --only are mutually exclusive"
				mode=only
				;;
			--port)
				shift
				[ -n "$1" ] || error "--port needs a value (C or H:C)"
				port_specs="$port_specs $1"
				;;
			--port=*) port_specs="$port_specs ${1#--port=}" ;;
			-*) error "Unknown option: $1" ;;
			*) folder_arg="$1" ;;
			esac
			shift
		done
		cmd_up "$name" "$folder_arg" "$docker_sock" "$mode" "$keep_alive" "$port_specs" "$want_fork"
		;;
	esac
}

main "$@"
