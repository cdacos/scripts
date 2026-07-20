# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

Standalone developer utility shell scripts, distributed as single files via raw GitHub URLs (users install them with chezmoi externals or curl — see README.md). Each script must therefore remain **self-contained in one file** with no dependencies on other files in this repo. The exception is `agent-bus/`, a deployable Go service (single source file, stdlib only — keep it dependency-free).

## Commands

There is no test framework. Lint and format shell scripts with:

```sh
shellcheck dev-container.sh dev-container-per-repo.sh check-tools.sh bus.sh
shfmt -d .          # diff formatting issues (shfmt -w to fix)
```

Build (and implicitly vet/compile-check) the agent-bus service with:

```sh
docker build -t agent-bus ./agent-bus   # runs go vet + go build inside the image
```

Both tools are preinstalled in the dev container (`dev-container.sh`'s embedded default image). To manually test `dev-container.sh`, run it against a scratch folder (`DEV_CONTAINER_HOME=/tmp/dc dev! test /some/folder`) — it requires Docker, auto-writes the per-container Dockerfile on first create, and prompts interactively before creating/killing anything.

## Conventions

- `dev-container.sh` and `check-tools.sh` are POSIX sh (`#!/bin/sh`) — avoid bashisms (arrays, `[[ ]]`, `local` is used sparingly). Scripts in `jellyfin-media-player/` are bash.
- Commit messages are suffixed with `[scripts]` (e.g. `Fix dev-container mounts [scripts]`).

## Architecture: dev-container.sh (`dev!`)

The main script. `dev! <name> [folder] [--docker]` launches a named Docker container that mounts **only** the given folder (default cwd) plus its own persistent state — nothing else on the host. No git worktrees, no repo bind-mount. (Rewritten from the old worktree/port-dir model; pre-existing worktree containers keep running but are unmanageable by this script.)

- **Versioning**: the `VERSION` constant near the top of the script (`dev! --version` prints it, currently `2.0`). Bump it whenever you make a user-visible behavior change.

- **State home** `~/.local/dev-container/` (override with `DEV_CONTAINER_HOME`, used by tests) is the only state store: a shared `.env` and one `<name>/` dir per container holding `.env` (per-name), `Dockerfile` (+ `.dockerignore`) — the per-container build recipe, `port` (plain text), `folder` (last mounted path), and `claude/` (persistent `/home/dev/.claude`).
- **Naming**: container and image are both `dev-<name>` (namespaces are separate); names are slugified. Host `port` maps to container port 8000.
- **Env hierarchy** (`load_env_files`): host env → shared `.env` → per-name `.env`, later wins. Both files are plain `KEY=value` (no quotes/`$expansion`) so they are both **sh-sourced at build time** (driving `GITHUB_TOKEN_DOTFILES`/`GITHUB_USERNAME`/`GITCONFIG`) and passed to the container via `docker run --env-file` (added only if the file exists — docker errors on a missing one). `port` is deliberately kept out of `.env` so no `PORT` var leaks to web frameworks. Everything in these files is visible in the container at runtime; only the dotfiles token stays out of image layers via the BuildKit secret.
- **Start semantics** (`cmd_up`): running → report and quit; stopped → `docker rm` + recreate bound to **this invocation's** folder (reusing stored port/token); none → confirm, run the token flow, build, run, attach. Folder is not sticky.
- **Token flow** (`ensure_token`, on first create only): (e)nter / (g)enerate (`openssl rand -hex 32`) / (s)kip. On enter/generate the token is written to `<name>/.env` and a paste-ready `config/agents.json` fragment (name + `token_sha256` via `shasum`/`openssl`) is printed for the bus operator.
- **Path parity**: the folder is mounted at the *same absolute path* inside the container (`HOST_PROJECT_PATH` build arg + matching `-v "$folder:$folder"` + `-w`), so host paths resolve identically inside. `warn_git` warns (does not block) when the folder is a git worktree (`.git` is a file) or a repo subfolder, since git will not work with the repo root unmounted.
- **Claude state**: per-name `<name>/claude/` is mounted as `/home/dev/.claude`, seeded **host-side once** from `~/.claude` (settings/CLAUDE.md/credentials/skills/plugins — same `tar` filter as before, no `docker exec`). Credentials still also flow via the `CLAUDE_CODE_CREDENTIALS`/`CLAUDE_JSON` env vars that the entrypoint writes at startup.
- **Isolation stance** (stated honestly in `--help`): the container sees only the target folder + its claude dir. Network is **not** isolated. `docker.sock` is **not** mounted unless `--docker` is passed — it grants root-equivalent host access (on macOS the whole Docker VM), so it is opt-in.
- **Dockerfile ownership**: each container owns exactly one Dockerfile at `$STATE_HOME/<name>/Dockerfile`, built with context `$STATE_HOME/<name>/` (a generated `.dockerignore` keeps that dir's `.env`/`port`/`folder`/`claude` state and secrets out of the build context). `write_default_dockerfile` writes a batteries-included default (Alpine + bash/git/curl, Claude Code, chezmoi dotfiles, tmux, and the creds-injecting entrypoint) there on first create (past the confirm gate, so an aborted create leaves no state) — the script is distributed standalone, so this default is **embedded as a heredoc** rather than read from disk, and it is the single source for this repo's own dev container too (edit the heredoc to change it). The Dockerfile is **bind-mounted rw at `/home/dev/Dockerfile`** so the container can edit its own build recipe; edits take effect on the next recreate. The target folder's own Dockerfiles are **ignored** — crib from them by hand. There is no `dev! init` and no per-folder `Dockerfile.dev`. Its only hard requirement is a `dev` user with bash, created with `HOST_UID`/`HOST_GID` build args for volume permission parity.

## Architecture: agent-bus/

Self-hosted HTTP message bus so LLM agents (in dev containers, on other machines, in the cloud) can message each other. Small Go package (`main.go` + `ui.go`, stdlib only) in a scratch container, designed to sit behind an existing reverse proxy that handles TLS. The core principle: **the bus stays frozen; new integrations are clients** — the web UI is an embedded page using a normal agent token, and the Slack bridge (`agent-bus/slack-bridge/`, separate binary) is just another registered agent.

- **Files are the storage layer, the service is the only writer.** Everything lives under `/data` (bind mount): `config/agents.json` (token sha256 hashes + topic ACLs, hot-reloaded on mtime change), per-agent `inbox/` (one JSON file per undelivered DM, removed on ack), per-agent `messages.jsonl`/`sent.jsonl` (permanent history), and `topics/<topic>/<date>.jsonl` logs. No database; backup = rsync of `/data`.
- **Contention model:** per-file-path mutexes serialize appends; inbox writes are temp-file + atomic rename. The in-memory pubsub only *notifies* long-pollers (`GET /inbox?wait=`) and SSE watchers (`/topics/{t}/watch`) — durable delivery never depends on it, messages hit disk before notification.
- **Auth:** bearer token per agent; only sha256 hashes are stored server-side. ACLs (`publish`/`subscribe` arrays, `*` and `prefix-*` wildcards) apply to topics; any registered agent may DM any other. `"admin": true` grants read-only oversight (any agent's history via `/agents/{name}/history`, any topic) but never changes write behavior.
- **History is permanent:** acking removes only the inbox copy; `GET /history` serves the merged sent+received archive. Nothing in the server deletes history files.
- **Slack bridge:** Events API inbound (HMAC-verified; verification disabled with a loud warning if `SLACK_SIGNING_SECRET` is empty), `chat.postMessage` outbound. Slack threads round-trip via `meta.thread` (`"<channel>:<ts>"`); topic mirroring skips the bridge's own messages to prevent loops. Deliberately stdlib-only — no websockets/Socket Mode.
- **Self-documenting:** `GET /docs` serves agent-oriented usage docs (the `docsMarkdown` constant in main.go) — new agents are onboarded by pointing them at that URL plus a token. Keep those docs in sync with any API change.
- **Clients:** `bus.sh` at the repo root is a POSIX-sh curl/jq wrapper over the API; keep its commands in sync too. `dev-container.sh` passes host `AGENT_BUS_URL`/`AGENT_BUS_TOKEN` env vars into containers.

## Other contents

- `dev-container-per-repo.sh`: the previous git-worktree-based `dev!` (each branch gets a worktree + container under `../{repo}.worktrees/{port}/{branch}/`), kept as a separate tool for repo/worktree-centric workflows. POSIX sh; superseded by `dev-container.sh` for the folder-based model but not deprecated.
- `check-tools.sh`: checks a pipe-delimited tool table (`cmd|description|apt|brew|url|alt-cmd`) for missing CLI tools and reports chezmoi drift. Add new tools by appending to the `TOOLS` heredoc.
- `jellyfin-media-player/`: bash scripts, a systemd unit, and udev rules for a Jellyfin HTPC setup (cage/Wayland kiosk, PipeWire HDMI audio watchdog). Machine-specific, not distributed.
