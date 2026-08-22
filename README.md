# scripts

Shared developer utility scripts.

## Scripts

### `agent-container.sh` (aka `agent`)

Folder-based Docker agent container launcher. `agent! <name> [folder]` starts a named container that mounts its accumulated set of saved folders (rw) plus its own persistent state under `~/.local/agent-container/<name>/` (bus token, Claude home, port) — nothing else on the host. The folder argument is **optional**: omit it to map no folder (the agent gets just its own home + any saved set — good for an agent that clones/pulls its own repos); pass `.` to map the current dir. `docker.sock` is not mounted unless you pass `--docker`.

```sh
agent! api ~/src/api        # Create/start container 'agent-api' mounting ~/src/api
agent! scratch              # Container 'agent-scratch' with NO folder mapped (working dir = agent home)
agent! scratch .            # Same container, now mapping the current dir
agent! ci . --docker        # Also mount the host Docker socket (root-equivalent — opt-in)
agent!                      # List all containers (NAME, PORT, STATUS, FOLDER)
agent! kill api             # Tear down 'agent-api' and delete its state
```

Each container owns its own Dockerfile at `~/.local/agent-container/<name>/Dockerfile`, written from a batteries-included default (Alpine + bash/git/curl, Claude Code, chezmoi dotfiles, tmux) on first create. It's bind-mounted read-write at `~/Dockerfile`, so the container can edit its own build recipe — the change takes effect on the next `agent! <name>` recreate. The target folder's own Dockerfiles are ignored; copy from them by hand if you want.

### `dev-container.sh`

The git-worktree-based `dev!`. Pairs each branch with a worktree + container under `../{repo}.worktrees/{port}/{branch}/`, mounting the whole repo. Kept for repo/worktree-centric workflows; use `agent-container.sh` (above) for the newer folder-based model.

```sh
dev! feature-auth         # Create/attach a worktree + container for a branch
dev! kill feature-auth    # Tear down container + worktree
```

### `agent-bus-cli.sh`

CLI companion for **agent-bus**, the self-hosted HTTP message bus for LLM agents. The bus service itself now lives in its own repo (`../agent-bus`); `agent-bus-cli.sh` is the shell client that stays here. Reads `AGENT_BUS_URL` and `AGENT_BUS_TOKEN` from the environment (`agent!` passes both into containers automatically when set).

```sh
agent-bus-cli.sh send mars "Can you review PR #42?"
agent-bus-cli.sh inbox 120          # long-poll up to 120s
agent-bus-cli.sh ack <message-id>
agent-bus-cli.sh pub build-status "green"
agent-bus-cli.sh watch build-status
```

### `agent-bus-fsd.sh`

Serves this box's `~/src` to the **agent-bus** web UI's Files tab. The bus runs
elsewhere and cannot see your disk, so each agent serves its own: the daemon
watches the `fs-req` topic over SSE, answers only requests addressed to its own
agent name, and publishes replies to `fs-rsp`. Outbound connections only — no
port to open, so it works from a NATed VM or a laptop container. Any holder of a
valid bus token can browse; anonymous visitors to `/ui` cannot.

Gitignored files and `.git` directories are withheld by default
(`AGENT_BUS_FS_GITIGNORE=0` to serve everything). That is the layer worth
guarding: anything committed is already on the remote, whereas gitignored files
are where secrets live by convention — and a `.git` pack still holds secrets
that were committed and later deleted. `.gitignore` itself stays readable.
Tracked contents are otherwise served raw, so point `AGENT_BUS_FS_ROOT` only at
a tree you would hand to every agent on the bus.

`agent-bus-fsd.sh check` reports how many ignored files each repo is withholding,
so you can see what you are exposing before you serve it.

```sh
agent-bus-fsd.sh check              # verify env, root and bus reachability
agent-bus-fsd.sh serve &            # answer requests until killed
AGENT_BUS_FS_ROOT=$HOME/work agent-bus-fsd.sh serve
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
[".local/bin/agent-container.sh"]
    type = "file"
    url = "https://raw.githubusercontent.com/cdacos/scripts/main/agent-container.sh"
    executable = true
    refreshPeriod = "0"

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

[".local/bin/agent-bus-cli.sh"]
    type = "file"
    url = "https://raw.githubusercontent.com/cdacos/scripts/main/agent-bus-cli.sh"
    executable = true
    refreshPeriod = "0"

[".local/bin/agent-bus-fsd.sh"]
    type = "file"
    url = "https://raw.githubusercontent.com/cdacos/scripts/main/agent-bus-fsd.sh"
    executable = true
    refreshPeriod = "0"
```

Then run `chezmoi apply`.

### Standalone

```sh
curl -fsSL https://raw.githubusercontent.com/cdacos/scripts/main/agent-container.sh -o ~/.local/bin/agent-container.sh
curl -fsSL https://raw.githubusercontent.com/cdacos/scripts/main/dev-container.sh -o ~/.local/bin/dev-container.sh
curl -fsSL https://raw.githubusercontent.com/cdacos/scripts/main/check-tools.sh -o ~/.local/bin/check-tools.sh
curl -fsSL https://raw.githubusercontent.com/cdacos/scripts/main/agent-bus-cli.sh -o ~/.local/bin/agent-bus-cli.sh
curl -fsSL https://raw.githubusercontent.com/cdacos/scripts/main/agent-bus-fsd.sh -o ~/.local/bin/agent-bus-fsd.sh
chmod +x ~/.local/bin/agent-container.sh ~/.local/bin/dev-container.sh ~/.local/bin/check-tools.sh ~/.local/bin/agent-bus-cli.sh ~/.local/bin/agent-bus-fsd.sh
```
