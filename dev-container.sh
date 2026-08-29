#!/bin/sh
# dev! - Git worktree + Docker dev container launcher

set -e

show_help() {
    cat <<'EOF'
Usage: dev! [branch-name]
       dev! -h | --help

Creates isolated dev environments using git worktrees + Docker containers.
Each branch gets its own worktree and container with a unique port.

Commands:
  (no args)             List all worktrees and their container status
  <branch>              Create or attach to container for branch (auto-slugified)
  <name> --local        Create a container that mounts the current repo directly
                        (no git worktree); multiple names share the same folder
  kill <branch>         Stop container, remove worktree and folder for branch
  init <base-image>     Generate skeleton Dockerfile.dev (or .example if exists)
  completion <shell>    Output shell completion code (bash or zsh)
  -h, --help            Show this help

Environment variables:
  GITCONFIG                 Your ~/.gitconfig content (copied into container)
  GITHUB_TOKEN_DOTFILES     GitHub access token for dotfiles repo (optional)
  GITHUB_USERNAME           GitHub username for dotfiles (optional)
  AGENT_BUS_URL             agent-bus base URL; seeds new containers (optional)
  AGENT_BUS_TOKEN           agent-bus bearer token; seeds new containers (optional)

  On first launch these seed a per-container file at
  ../{repo}.worktrees/{port}/.agent-bus.env (outside the git checkout). The
  container reads its bus identity from that file via --env-file, so give each
  container a DISTINCT AGENT_BUS_TOKEN by editing the file, then recreate it
  (dev! kill <branch> && dev! <branch>).

Assumptions:
  - Dockerfile.dev exists at repo root
  - macOS: Claude credentials read from Keychain ("Claude Code-credentials")
  - Linux: Claude credentials from ~/.claude/.credentials.json (if exists)
  - ~/.claude.json copied in (skips onboarding)
  - ~/.claude copied into container (isolated snapshot of settings, skills, etc.)
  - Main repo mounted (so git commands work in worktree)
  - Worktrees created in ../{repo}.worktrees/{port}/{branch}/ (sibling to repo)
  - Container dev user UID/GID matches host user (volume permission parity)
  - Container ports start at 9000, mapped to container:8000

Examples:
  dev! feature-auth         # Create/attach to feature-auth branch
  dev! "Fix Bug #123"       # Slugified to fix-bug-123
  dev! scratch --local      # Create container 'scratch' on the live repo
  dev! scratch              # Re-attach to it later
  dev! kill feature-auth    # Remove container, worktree, and folder
  dev!                      # List all worktrees
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

# Find git repo root by walking up from current directory
find_repo_root() {
    dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/.git" ] || [ -f "$dir/.git" ]; then
            echo "$dir"
            return 0
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

# Get repo name from root path
get_repo_name() {
    basename "$1"
}

# Get worktrees directory (sibling to repo: ../{repo}.worktrees)
get_worktrees_dir() {
    repo_root="$1"
    repo_name=$(get_repo_name "$repo_root")
    echo "$(dirname "$repo_root")/${repo_name}.worktrees"
}

# Slugify a string: lowercase, replace special chars with hyphens
slugify() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//'
}

# Get Claude credentials from macOS Keychain (returns empty string on non-macOS or if not found)
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

# Path to the per-container agent-bus env file.
# Lives in the PORT dir (sibling to the branch checkout), so it is outside any
# git worktree and never shows up in `git status`.
get_bus_env_file() {
    port_dir="$1"
    echo "${port_dir}/.agent-bus.env"
}

# Ensure the per-container agent-bus env file exists. On first creation it is
# seeded from the host environment (so existing single-agent setups keep working);
# edit AGENT_BUS_TOKEN in the file to give each container a distinct bus identity.
ensure_bus_env_file() {
    bus_env_file="$1"
    if [ ! -f "$bus_env_file" ]; then
        mkdir -p "$(dirname "$bus_env_file")"
        cat > "$bus_env_file" <<EOF
# Per-container agent-bus identity, read by dev! via 'docker run --env-file'.
# AGENT_BUS_URL is shared across agents; AGENT_BUS_TOKEN MUST be distinct per
# container (it identifies the agent on the bus). Seeded from the host env below;
# paste the operator-issued token for this container, then recreate it
# (dev! kill <branch> && dev! <branch>) so the new value is baked into the container.
AGENT_BUS_URL=${AGENT_BUS_URL:-}
AGENT_BUS_TOKEN=${AGENT_BUS_TOKEN:-}
EOF
    fi
}

# Build Docker image
build_image() {
    image_name="$1"
    repo_root="$2"
    worktree_path="$3"

    # Write token to temp file for BuildKit secret
    secret_args=""
    token_file=""
    if [ -n "$GITHUB_TOKEN_DOTFILES" ]; then
        token_file=$(mktemp)
        printf '%s' "$GITHUB_TOKEN_DOTFILES" > "$token_file"
        secret_args="--secret id=github_token,src=$token_file"
    fi

    info "Building Docker image '$image_name'..."
    docker build -f "$repo_root/Dockerfile.dev" \
        $secret_args \
        --build-arg GITCONFIG="${GITCONFIG:-}" \
        --build-arg GITHUB_USERNAME="${GITHUB_USERNAME:-}" \
        --build-arg HOST_PROJECT_PATH="${worktree_path}" \
        --build-arg HOST_UID="$(id -u)" \
        --build-arg HOST_GID="$(id -g)" \
        -t "$image_name" "$repo_root"

    # Clean up temp file if it exists
    [ -n "$token_file" ] && rm -f "$token_file" || true
}

# Start a new container
start_container() {
    container_name="$1"
    port="$2"
    worktree_path="$3"
    image_name="$4"
    repo_root="$5"
    bus_env_file="$6"

    claude_creds=$(get_claude_credentials)
    claude_json=$(get_claude_json)

    # Agent-bus identity comes from the per-container env file (see ensure_bus_env_file),
    # NOT the host env, so each container can carry a distinct AGENT_BUS_TOKEN.
    info "Starting container '$container_name'..."
    docker run --init -d \
        --name "$container_name" \
        -p "${port}:8000" \
        -e "CLAUDE_CODE_CREDENTIALS=${claude_creds}" \
        -e "CLAUDE_JSON=${claude_json}" \
        --env-file "$bus_env_file" \
        -v "${repo_root}:${repo_root}" \
        -v "${worktree_path}:${worktree_path}" \
        -v "${HOME}/.claude/projects:/home/dev/.claude/projects:rw" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -w "${worktree_path}" \
        "$image_name" \
        tail -f /dev/null

    # Copy host ~/.claude config into container (isolated snapshot, not shared)
    # Only copies essential config — skips large ephemeral dirs (projects/, debug/, telemetry/, etc.)
    if [ -d "${HOME}/.claude" ]; then
        info "Copying ~/.claude config into container..."
        docker exec -u root "$container_name" mkdir -p /home/dev/.claude
        # GNU tar has no --include; archive an explicit list of only the
        # entries that exist (tar errors out on a missing path, which would
        # silently abort the whole copy mid-pipeline under `set -e`).
        copy_items=""
        for item in settings.json CLAUDE.md .credentials.json skills plugins; do
            [ -e "${HOME}/.claude/${item}" ] && copy_items="$copy_items $item"
        done
        if [ -n "$copy_items" ]; then
            ( cd "${HOME}/.claude" && tar -cf - $copy_items ) \
                | docker exec -i -u root "$container_name" tar -xf - -C /home/dev/.claude
        fi
        docker exec -u root "$container_name" chown -R dev:dev /home/dev/.claude
    fi
}

# List all worktrees with their status
cmd_list() {
    repo_root=$(find_repo_root) || error "Not in a git repository"
    repo_name=$(get_repo_name "$repo_root")
    worktrees_dir=$(get_worktrees_dir "$repo_root")

    if [ ! -d "$worktrees_dir" ]; then
        info "No worktrees found in $(basename "$worktrees_dir")/"
        return 0
    fi

    printf "%-8s %-30s %-10s\n" "PORT" "BRANCH" "STATUS"
    printf "%-8s %-30s %-10s\n" "--------" "------------------------------" "----------"

    for port_dir in "$worktrees_dir"/*/; do
        [ -d "$port_dir" ] || continue
        port=$(basename "$port_dir")

        for branch_dir in "$port_dir"*/; do
            [ -d "$branch_dir" ] || continue
            branch=$(basename "$branch_dir")
            container_name="${repo_name}-${branch}"
            status=$(get_container_status "$container_name")

            case "$status" in
                running) status_colored="${GREEN}running${NC}" ;;
                stopped) status_colored="${YELLOW}stopped${NC}" ;;
                *)       status_colored="${RED}none${NC}" ;;
            esac

            label="$branch"
            [ -f "${branch_dir}.local" ] && label="$branch (local)"
            printf "%-8s %-30s " "$port" "$label"
            printf "$status_colored\n"
        done
    done
}

# Find existing worktree by branch name
find_worktree() {
    repo_root="$1"
    branch="$2"
    worktrees_dir=$(get_worktrees_dir "$repo_root")

    if [ ! -d "$worktrees_dir" ]; then
        return 1
    fi

    for port_dir in "$worktrees_dir"/*/; do
        [ -d "$port_dir" ] || continue
        if [ -d "${port_dir}${branch}" ]; then
            echo "${port_dir}${branch}"
            return 0
        fi
    done
    return 1
}

# Return 0 if TCP port already bound on host (covers docker-published ports,
# which appear as docker-proxy listeners — the case find_next_port can't see by
# scanning worktree dirs alone).
port_in_use() {
    p="$1"
    if command -v ss >/dev/null 2>&1; then
        # Linux
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":${p}\$" && return 0
    elif command -v lsof >/dev/null 2>&1; then
        # macOS / BSD (no ss)
        lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 && return 0
    fi
    # Belt-and-suspenders everywhere: docker-published host ports.
    docker ps --format '{{.Ports}}' 2>/dev/null | grep -qE "(^|[^0-9])${p}->" && return 0
    return 1
}

# Advance a candidate port past any host-allocated port (max 65535).
next_free_port() {
    candidate="$1"
    while port_in_use "$candidate"; do
        [ "$candidate" -ge 65535 ] && error "No free port available"
        printf "${YELLOW}Port %s in use, trying %s...${NC}\n" "$candidate" "$((candidate + 1))" >&2
        candidate=$((candidate + 1))
    done
    echo "$candidate"
}

# Find next available port
find_next_port() {
    repo_root="$1"
    worktrees_dir=$(get_worktrees_dir "$repo_root")
    max_port=""

    # Check if there are existing port folders
    has_ports=false
    if [ -d "$worktrees_dir" ]; then
        for port_dir in "$worktrees_dir"/*/; do
            [ -d "$port_dir" ] || continue
            has_ports=true
            port=$(basename "$port_dir")
            if [ -z "$max_port" ] || [ "$port" -gt "$max_port" ] 2>/dev/null; then
                max_port="$port"
            fi
        done
    fi

    # If no existing ports, ask user for starting port
    if [ "$has_ports" = false ]; then
        printf "\n" >&2
        printf "${CYAN}No existing port assignments found.${NC}\n" >&2
        printf "Enter starting port number (e.g., 9000, 10000, 15000): " >&2
        read -r start_port

        # Validate input is a number
        if ! echo "$start_port" | grep -qE '^[0-9]+$'; then
            error "Invalid port number. Please enter a numeric value."
        fi

        # Validate port is in valid range (1024-65535)
        if [ "$start_port" -lt 1024 ] || [ "$start_port" -gt 65535 ]; then
            error "Port must be between 1024 and 65535"
        fi

        next_free_port "$start_port"
    else
        next_free_port $((max_port + 1))
    fi
}

# Create new worktree and container (or local-mount container if local_mode=true)
cmd_create() {
    repo_root="$1"
    branch="$2"
    local_mode="${3:-false}"
    repo_name=$(get_repo_name "$repo_root")
    worktrees_dir=$(get_worktrees_dir "$repo_root")
    port=$(find_next_port "$repo_root")
    marker_dir="$worktrees_dir/$port/$branch"
    container_name="${repo_name}-${branch}"
    image_name="${repo_name}-dev"

    if [ "$local_mode" = "true" ]; then
        mount_path="$repo_root"
    else
        mount_path="$marker_dir"
    fi

    printf "\n"
    info "Will create:"
    if [ "$local_mode" = "true" ]; then
        printf "  Name:      ${YELLOW}%s${NC} (local)\n" "$branch"
        printf "  Mount:     ${YELLOW}%s${NC}\n" "$repo_root"
    else
        printf "  Branch:    ${YELLOW}%s${NC}\n" "$branch"
        printf "  Worktree:  ${YELLOW}%s/%s/%s${NC}\n" "$(basename "$worktrees_dir")" "$port" "$branch"
    fi
    printf "  Container: ${YELLOW}%s${NC}\n" "$container_name"
    printf "  Port:      ${YELLOW}%s${NC} → 8000\n" "$port"
    printf "\n"
    printf "Continue? [y/n] "
    read -r answer

    case "$answer" in
        [Yy]|[Yy][Ee][Ss]) ;;
        *)
            info "Aborted."
            exit 0
            ;;
    esac

    printf "\n"

    if [ "$local_mode" = "true" ]; then
        info "Creating local marker at $(basename "$worktrees_dir")/$port/$branch..."
        mkdir -p "$marker_dir"
        touch "$marker_dir/.local"
    else
        # Create branch from current HEAD
        info "Creating branch '$branch'..."
        git -C "$repo_root" branch "$branch" 2>/dev/null || {
            info "Branch '$branch' already exists, using existing branch"
        }

        info "Creating worktree at $(basename "$worktrees_dir")/$port/$branch..."
        mkdir -p "$worktrees_dir/$port"
        # Use relative paths so both the worktree→repo and repo→worktree gitdir
        # links are portable across environments (e.g. Windows drive letters vs WSL)
        rel_worktree="../$(basename "$worktrees_dir")/$port/$branch"
        git -C "$repo_root" worktree add --relative-paths "$rel_worktree" "$branch"

        info "Copying local settings files..."
        find "$repo_root" -maxdepth 5 -name "appsettings.Local.json" | while read -r src_file; do
            rel_path="${src_file#$repo_root/}"
            dest_file="$marker_dir/$rel_path"
            dest_dir=$(dirname "$dest_file")
            if [ -d "$dest_dir" ]; then
                cp "$src_file" "$dest_file"
                info "  Copied $rel_path"
            fi
        done
    fi

    bus_env_file=$(get_bus_env_file "$worktrees_dir/$port")
    ensure_bus_env_file "$bus_env_file"

    build_image "$image_name" "$repo_root" "$mount_path"
    start_container "$container_name" "$port" "$mount_path" "$image_name" "$repo_root" "$bus_env_file"

    printf "\n"
    success "Container ready!"
    printf "Port ${YELLOW}%s${NC} → container:8000\n" "$port"
    printf "Agent-bus env: ${CYAN}%s${NC} (set a ${YELLOW}distinct${NC} AGENT_BUS_TOKEN, then recreate)\n" "$bus_env_file"
    if [ "$local_mode" != "true" ]; then
        printf "If your container's git is older than 2.48, run: ${CYAN}git config --unset extensions.relativeWorktrees${NC}\n"
    fi
    printf "\n"

    # Enter container as dev user
    docker exec -it -e TERM=xterm-256color -e COLORTERM=truecolor -u dev "$container_name" bash
}

# Run existing worktree
cmd_run() {
    worktree_path="$1"
    repo_root="$2"
    repo_name=$(get_repo_name "$repo_root")

    # Extract port and branch from path: {repo}.worktrees/{port}/{branch}
    branch=$(basename "$worktree_path")
    port_dir=$(dirname "$worktree_path")
    port=$(basename "$port_dir")

    if [ -f "$worktree_path/.local" ]; then
        mount_path="$repo_root"
    else
        mount_path="$worktree_path"
    fi

    container_name="${repo_name}-${branch}"
    image_name="${repo_name}-dev"
    status=$(get_container_status "$container_name")

    case "$status" in
        none)
            bus_env_file=$(get_bus_env_file "$port_dir")
            ensure_bus_env_file "$bus_env_file"
            build_image "$image_name" "$repo_root" "$mount_path"
            start_container "$container_name" "$port" "$mount_path" "$image_name" "$repo_root" "$bus_env_file"
            ;;
        stopped)
            info "Starting stopped container '$container_name'..."
            docker start "$container_name"
            ;;
        running)
            info "Container '$container_name' already running"
            ;;
    esac

    printf "\n"
    printf "Port ${YELLOW}%s${NC} → container:8000\n\n" "$port"

    # Enter container as dev user
    docker exec -it -e TERM=xterm-256color -e COLORTERM=truecolor -u dev "$container_name" bash
}

# Kill container, worktree, and folder for a branch
cmd_kill() {
    repo_root="$1"
    branch="$2"
    repo_name=$(get_repo_name "$repo_root")
    container_name="${repo_name}-${branch}"

    worktree_path=$(find_worktree "$repo_root" "$branch") || error "No worktree found for branch '$branch'"
    port_dir=$(dirname "$worktree_path")
    port=$(basename "$port_dir")

    printf "\n"
    printf "${RED}Will kill:${NC}\n"
    printf "  Container: ${YELLOW}%s${NC}\n" "$container_name"
    printf "  Worktree:  ${YELLOW}%s${NC}\n" "$worktree_path"
    printf "  Port:      ${YELLOW}%s${NC}\n" "$port"
    printf "\n"
    printf "Are you sure? [y/n] "
    read -r answer

    case "$answer" in
        [Yy]|[Yy][Ee][Ss]) ;;
        *)
            info "Aborted."
            exit 0
            ;;
    esac

    printf "\n"

    # Stop and remove container
    status=$(get_container_status "$container_name")
    case "$status" in
        running)
            info "Stopping container '$container_name'..."
            docker stop "$container_name" >/dev/null
            info "Removing container '$container_name'..."
            docker rm "$container_name" >/dev/null
            ;;
        stopped)
            info "Removing container '$container_name'..."
            docker rm "$container_name" >/dev/null
            ;;
        none)
            info "No container found for '$container_name'"
            ;;
    esac

    if [ -f "$worktree_path/.local" ]; then
        info "Removing local marker..."
        rm -rf "$worktree_path"
    else
        info "Removing git worktree..."
        git -C "$repo_root" worktree remove --force "$worktree_path"
    fi

    # Remove the per-container agent-bus env file (token is tied to this container)
    bus_env_file=$(get_bus_env_file "$port_dir")
    [ -f "$bus_env_file" ] && rm -f "$bus_env_file"

    # Remove port directory if empty
    if [ -d "$port_dir" ] && [ -z "$(ls -A "$port_dir")" ]; then
        info "Removing empty port directory '$port'..."
        rmdir "$port_dir"
    fi

    printf "\n"
    success "Killed '$branch' (port $port)"
}

# Generate skeleton Dockerfile.dev
cmd_init() {
    base_image="$1"
    repo_root=$(find_repo_root) || error "Not in a git repository"

    output_file="$repo_root/Dockerfile.dev"
    if [ -f "$output_file" ]; then
        output_file="$repo_root/Dockerfile.dev.example"
        info "Dockerfile.dev already exists, creating Dockerfile.dev.example instead"
    fi

    cat > "$output_file" <<EOF
# Dockerfile.dev - Generated by dev!
# Minimum requirement: a 'dev' user with bash

FROM ${base_image}

# === SYSTEM PACKAGES ===
# Add packages your project needs
# RUN apt-get update && apt-get install -y ...

# === BUILD ARGS (passed by dev!) ===
ARG GITCONFIG=""         # Contents of host ~/.gitconfig
ARG GITHUB_USERNAME=""   # For dotfiles repo (optional)
ARG HOST_PROJECT_PATH="" # Worktree path, for path parity with host
ARG HOST_UID=1000        # Host user's UID (for volume permission parity)
ARG HOST_GID=1000        # Host user's GID

# === DEV USER (required by dev!) ===
RUN groupadd -g \$HOST_GID dev && useradd -m -s /bin/bash -u \$HOST_UID -g \$HOST_GID dev

# === YOUR PROJECT TOOLS ===
# Add your language runtimes, build tools, etc.

USER dev

# === OPTIONAL: Claude Code ===
# RUN curl -fsSL https://claude.ai/install.sh | bash

# === OPTIONAL: Dotfiles with chezmoi ===
# RUN --mount=type=secret,id=github_token,mode=0444 \\
#     GITHUB_TOKEN=\$(cat /run/secrets/github_token 2>/dev/null || true) && \\
#     if [ -n "\$GITHUB_TOKEN" ] && [ -n "\$GITHUB_USERNAME" ]; then \\
#         sh -c "\$(curl -fsLS get.chezmoi.io/lb)" -- init --apply \\
#         https://\${GITHUB_TOKEN}@github.com/\${GITHUB_USERNAME}/dotfiles.git; \\
#     fi

# === RUNTIME ENV VARS (available in container) ===
# CLAUDE_CODE_CREDENTIALS - Claude auth JSON (from Keychain on macOS)
# CLAUDE_JSON            - Contents of ~/.claude.json (skips onboarding)
# AGENT_BUS_URL          - agent-bus base URL (if set on host)
# AGENT_BUS_TOKEN        - agent-bus bearer token (if set on host)

WORKDIR /home/dev
EOF

    success "Created $(basename "$output_file")"
    printf "Edit the file to add your project-specific setup, then run:\n"
    printf "  ${CYAN}dev! <branch-name>${NC}\n"
}

# Output shell completion code
cmd_completion() {
    case "$1" in
        bash)
            cat <<'EOF'
_container_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"
    local branches=$(git branch --format='%(refname:short)' 2>/dev/null)
    local repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
    local worktree_branches=""
    if [ -n "$repo_root" ]; then
        local wt_dir="$(dirname "$repo_root")/$(basename "$repo_root").worktrees"
        if [ -d "$wt_dir" ]; then
            worktree_branches=$(find "$wt_dir" -mindepth 2 -maxdepth 2 -type d -exec basename {} \;)
        fi
    fi
    local all=$(printf '%s\n%s' "$branches" "$worktree_branches" | sort -u)
    if [ "$prev" = "kill" ]; then
        COMPREPLY=($(compgen -W "$worktree_branches" -- "$cur"))
    else
        COMPREPLY=($(compgen -W "kill $all" -- "$cur"))
    fi
}
complete -F _container_complete dev-container.sh
EOF
            ;;
        zsh)
            cat <<'EOF'
_container_complete() {
    local repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
    local branches=(${(f)"$(git branch --format='%(refname:short)' 2>/dev/null)"})
    local worktree_branches=()
    if [ -n "$repo_root" ]; then
        local wt_dir="$(dirname "$repo_root")/$(basename "$repo_root").worktrees"
        if [ -d "$wt_dir" ]; then
            worktree_branches=(${(f)"$(find "$wt_dir" -mindepth 2 -maxdepth 2 -type d -exec basename {} \;)"})
        fi
    fi
    local all=(${(u)branches} ${(u)worktree_branches})
    if (( CURRENT == 3 )) && [[ "${words[2]}" == "kill" ]]; then
        compadd -a worktree_branches
    elif (( CURRENT == 2 )); then
        compadd kill
        compadd -a all
    fi
}
compdef _container_complete dev-container.sh
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
        -h|--help)
            show_help
            exit 0
            ;;
        kill)
            repo_root=$(find_repo_root) || error "Not in a git repository"
            [ -n "$2" ] || error "Usage: dev! kill <branch>"
            branch=$(slugify "$2")
            cmd_kill "$repo_root" "$branch"
            exit 0
            ;;
        init)
            # Only treat as init command if base-image arg provided
            if [ -n "$2" ]; then
                cmd_init "$2"
                exit 0
            fi
            ;;
        completion)
            # Only treat as completion command if shell arg provided
            if [ -n "$2" ]; then
                cmd_completion "$2"
                exit 0
            fi
            ;;
        *)
            repo_root=$(find_repo_root) || error "Not in a git repository"

            # Check Dockerfile.dev exists
            if [ ! -f "$repo_root/Dockerfile.dev" ]; then
                error "Dockerfile.dev not found at repository root"
            fi

            # Slugify the argument
            branch=$(slugify "$cmd")
            if [ -z "$branch" ]; then
                error "Invalid branch name"
            fi

            # Detect --local flag (any position after the name)
            local_mode=false
            shift
            for arg in "$@"; do
                case "$arg" in
                    --local) local_mode=true ;;
                    *) error "Unknown option: $arg" ;;
                esac
            done

            # Find or create
            worktree_path=$(find_worktree "$repo_root" "$branch") && {
                if [ "$local_mode" = "true" ]; then
                    error "'$branch' already exists. Use 'dev! kill $branch' first, or pick another name."
                fi
                cmd_run "$worktree_path" "$repo_root"
                exit 0
            }

            # Not found, create new
            cmd_create "$repo_root" "$branch" "$local_mode"
            ;;
    esac
}

main "$@"
