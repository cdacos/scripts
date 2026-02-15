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
  (no args)           List all worktrees and their container status
  <branch>            Create or attach to container for branch (auto-slugified)
  kill <branch>       Stop container, remove worktree and folder for branch
  init <base-image>   Generate skeleton Dockerfile.dev (or .example if exists)
  completion <shell>  Output shell completion code (bash or zsh)
  -h, --help          Show this help

Environment variables:
  GITCONFIG                 Your ~/.gitconfig content (copied into container)
  GITHUB_TOKEN_DOTFILES     GitHub access token for dotfiles repo (optional)
  GITHUB_USERNAME           GitHub username for dotfiles (optional)

Assumptions:
  - Dockerfile.dev exists at repo root
  - macOS: Claude credentials read from Keychain ("Claude Code-credentials")
  - Linux: Claude credentials from ~/.claude/.credentials.json (if exists)
  - ~/.claude.json copied in (skips onboarding)
  - ~/.claude/projects and ~/.claude/history.jsonl mounted (conversation history)
  - Main repo mounted (so git commands work in worktree)
  - Worktrees created in ../{repo}.worktrees/{port}/{branch}/ (sibling to repo)
  - Container dev user UID/GID matches host user (volume permission parity)
  - Container ports start at 9000, mapped to container:8000

Examples:
  dev! feature-auth         # Create/attach to feature-auth branch
  dev! "Fix Bug #123"       # Slugified to fix-bug-123
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

# Check if Dockerfile.dev uses a Debian base image
# Debian ships git 2.47 which lacks --relative-paths (added in 2.48)
is_debian_base() {
    repo_root="$1"
    base_image=$(sed -n 's/^FROM[[:space:]]\+\([^[:space:]]\+\).*/\1/p' "$repo_root/Dockerfile.dev" | head -1)
    case "$base_image" in
        debian:*|debian|*/debian:*|*/debian) return 0 ;;
        *) return 1 ;;
    esac
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

    # Clean up temp file
    [ -n "$token_file" ] && rm -f "$token_file"
}

# Start a new container
start_container() {
    container_name="$1"
    port="$2"
    worktree_path="$3"
    image_name="$4"
    repo_root="$5"

    claude_creds=$(get_claude_credentials)
    claude_json=$(get_claude_json)

    info "Starting container '$container_name'..."
    docker run --init -d \
        --name "$container_name" \
        -p "${port}:8000" \
        -e "CLAUDE_CODE_CREDENTIALS=${claude_creds}" \
        -e "CLAUDE_JSON=${claude_json}" \
        -v "${repo_root}:${repo_root}" \
        -v "${worktree_path}:${worktree_path}" \
        -v "${HOME}/.claude/projects:/home/dev/.claude/projects:rw" \
        -v "${HOME}/.claude/history.jsonl:/home/dev/.claude/history.jsonl:rw" \
        -w "${worktree_path}" \
        "$image_name" \
        tail -f /dev/null
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

            printf "%-8s %-30s " "$port" "$branch"
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
        printf "\n"
        printf "${CYAN}No existing port assignments found.${NC}\n"
        printf "Enter starting port number (e.g., 9000, 10000, 15000): "
        read -r start_port

        # Validate input is a number
        if ! echo "$start_port" | grep -qE '^[0-9]+$'; then
            error "Invalid port number. Please enter a numeric value."
        fi

        # Validate port is in valid range (1024-65535)
        if [ "$start_port" -lt 1024 ] || [ "$start_port" -gt 65535 ]; then
            error "Port must be between 1024 and 65535"
        fi

        echo "$start_port"
    else
        echo $((max_port + 1))
    fi
}

# Create new worktree and container
cmd_create() {
    repo_root="$1"
    branch="$2"
    repo_name=$(get_repo_name "$repo_root")
    worktrees_dir=$(get_worktrees_dir "$repo_root")
    port=$(find_next_port "$repo_root")
    worktree_path="$worktrees_dir/$port/$branch"
    container_name="${repo_name}-${branch}"
    image_name="${repo_name}-dev"

    printf "\n"
    info "Will create:"
    printf "  Branch:    ${YELLOW}%s${NC}\n" "$branch"
    printf "  Worktree:  ${YELLOW}%s/%s/%s${NC}\n" "$(basename "$worktrees_dir")" "$port" "$branch"
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

    # Create branch from current HEAD
    info "Creating branch '$branch'..."
    git -C "$repo_root" branch "$branch" 2>/dev/null || {
        # Branch might already exist, that's ok
        info "Branch '$branch' already exists, using existing branch"
    }

    # Create worktree directory
    info "Creating worktree at $(basename "$worktrees_dir")/$port/$branch..."
    mkdir -p "$worktrees_dir/$port"
    # Use relative paths so both the worktree→repo and repo→worktree gitdir
    # links are portable across environments (e.g. Windows drive letters vs WSL)
    # --relative-paths requires git 2.48+; Debian ships 2.47, so skip it there
    rel_worktree="../$(basename "$worktrees_dir")/$port/$branch"
    worktree_flags=""
    if ! is_debian_base "$repo_root"; then
        worktree_flags="--relative-paths"
    fi
    git -C "$repo_root" worktree add $worktree_flags "$rel_worktree" "$branch"

    # Copy appsettings.Local.json files from repo root to worktree
    info "Copying local settings files..."
    find "$repo_root" -maxdepth 5 -name "appsettings.Local.json" | while read -r src_file; do
        rel_path="${src_file#$repo_root/}"
        dest_file="$worktree_path/$rel_path"
        dest_dir=$(dirname "$dest_file")
        if [ -d "$dest_dir" ]; then
            cp "$src_file" "$dest_file"
            info "  Copied $rel_path"
        fi
    done

    build_image "$image_name" "$repo_root" "$worktree_path"
    start_container "$container_name" "$port" "$worktree_path" "$image_name" "$repo_root"

    printf "\n"
    success "Container ready!"
    printf "Port ${YELLOW}%s${NC} → container:8000\n\n" "$port"

    # Enter container as dev user
    docker exec -it -u dev "$container_name" bash
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

    container_name="${repo_name}-${branch}"
    image_name="${repo_name}-dev"
    status=$(get_container_status "$container_name")

    case "$status" in
        none)
            build_image "$image_name" "$repo_root" "$worktree_path"
            start_container "$container_name" "$port" "$worktree_path" "$image_name" "$repo_root"
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
    docker exec -it -u dev "$container_name" bash
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

    # Remove git worktree
    info "Removing git worktree..."
    git -C "$repo_root" worktree remove --force "$worktree_path"

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
    local branches=$(git branch --format='%(refname:short)' 2>/dev/null)
    COMPREPLY=($(compgen -W "$branches" -- "$cur"))
}
complete -F _container_complete dev-container.sh
EOF
            ;;
        zsh)
            cat <<'EOF'
_container_complete() {
    local branches=(${(f)"$(git branch --format='%(refname:short)' 2>/dev/null)"})
    compadd -a branches
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

            # Find or create
            worktree_path=$(find_worktree "$repo_root" "$branch") && {
                cmd_run "$worktree_path" "$repo_root"
                exit 0
            }

            # Not found, create new
            cmd_create "$repo_root" "$branch"
            ;;
    esac
}

main "$@"
