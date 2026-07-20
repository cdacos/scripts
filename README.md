# scripts

Shared developer utility scripts.

## Scripts

### `dev-container.sh` (aka `dev!`)

Folder-based Docker dev container launcher. `dev! <name> [folder]` starts a named container that mounts **only** the given folder (default: current dir) plus its own persistent state under `~/.local/dev-container/<name>/` (bus token, Claude home, port) — nothing else on the host. `docker.sock` is not mounted unless you pass `--docker`.

```sh
dev! api ~/src/api        # Create/start container 'dev-api' mounting ~/src/api
dev! scratch              # Container 'dev-scratch' on the current dir
dev! ci . --docker        # Also mount the host Docker socket (root-equivalent — opt-in)
dev!                      # List all containers (NAME, PORT, STATUS, FOLDER)
dev! kill api             # Tear down 'dev-api' and delete its state
```

Each container owns its own Dockerfile at `~/.local/dev-container/<name>/Dockerfile`, written from a batteries-included default (Alpine + bash/git/curl, Claude Code, chezmoi dotfiles, tmux) on first create. It's bind-mounted read-write at `/home/dev/Dockerfile`, so the container can edit its own build recipe — the change takes effect on the next `dev! <name>` recreate. The target folder's own Dockerfiles are ignored; copy from them by hand if you want.

### `dev-container-per-repo.sh`

The previous, git-worktree-based `dev!`. Pairs each branch with a worktree + container under `../{repo}.worktrees/{port}/{branch}/`, mounting the whole repo. Kept for repo/worktree-centric workflows; use `dev-container.sh` (above) for the newer folder-based model.

```sh
dev! feature-auth         # Create/attach a worktree + container for a branch
dev! kill feature-auth    # Tear down container + worktree
```

### `agent-bus/`

Self-hosted HTTP message bus for LLM agents (direct messages + pub/sub topics), with all history stored as flat files. Single Go binary in a scratch container; runs behind your reverse proxy. Agents onboard themselves from the docs served at `GET /docs`; humans get a built-in web UI at `GET /ui`. Includes admin (read-everything) agents, permanent message history, and a Slack bridge (`agent-bus/slack-bridge/`). See [agent-bus/README.md](agent-bus/README.md).

```sh
docker build -t agent-bus ./agent-bus
docker run -d -v /srv/agent-bus:/data -p 127.0.0.1:8000:8000 agent-bus
```

### `bus.sh`

CLI companion for agent-bus. Reads `AGENT_BUS_URL` and `AGENT_BUS_TOKEN` from the environment (`dev!` passes both into containers automatically when set).

```sh
bus.sh send mars "Can you review PR #42?"
bus.sh inbox 120          # long-poll up to 120s
bus.sh ack <message-id>
bus.sh pub build-status "green"
bus.sh watch build-status
```

### `check-tools.sh`

Checks for missing CLI tools and chezmoi configuration drift. Shows installation commands for your platform (brew/apt).

```sh
check-tools.sh
```

## Install

### With chezmoi

Add to your `.chezmoiexternal.toml`:

```toml
[".local/bin/dev-container.sh"]
    type = "file"
    url = "https://raw.githubusercontent.com/cdacos/scripts/main/dev-container.sh"
    executable = true
    refreshPeriod = "0"

[".local/bin/check-tools.sh"]
    type = "file"
    url = "https://raw.githubusercontent.com/cdacos/scripts/main/check-tools.sh"
    executable = true
    refreshPeriod = "0"

[".local/bin/bus.sh"]
    type = "file"
    url = "https://raw.githubusercontent.com/cdacos/scripts/main/bus.sh"
    executable = true
    refreshPeriod = "0"
```

Then run `chezmoi apply`.

### Standalone

```sh
curl -fsSL https://raw.githubusercontent.com/cdacos/scripts/main/dev-container.sh -o ~/.local/bin/dev-container.sh
curl -fsSL https://raw.githubusercontent.com/cdacos/scripts/main/check-tools.sh -o ~/.local/bin/check-tools.sh
curl -fsSL https://raw.githubusercontent.com/cdacos/scripts/main/bus.sh -o ~/.local/bin/bus.sh
chmod +x ~/.local/bin/dev-container.sh ~/.local/bin/check-tools.sh ~/.local/bin/bus.sh
```
