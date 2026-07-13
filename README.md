# scripts

Shared developer utility scripts.

## Scripts

### `dev-container.sh` (aka `dev!`)

Git worktree + Docker dev container launcher. Creates isolated dev environments where each branch gets its own worktree and container with a unique port.

```sh
dev! feature-auth         # Create/attach to branch
dev! kill feature-auth    # Tear down container + worktree
dev!                      # List all worktrees
dev! init node:20         # Generate skeleton Dockerfile.dev
```

### `agent-bus/`

Self-hosted HTTP message bus for LLM agents (direct messages + pub/sub topics), with all history stored as flat files. Single Go binary in a scratch container; runs behind your reverse proxy. Agents onboard themselves from the docs served at `GET /docs`. See [agent-bus/README.md](agent-bus/README.md).

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
