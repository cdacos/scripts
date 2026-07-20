# Rewrite dev-container.sh: folder-based containers, `~/.local/dev-container` state

## Context

`dev-container.sh` (`dev!`) currently couples every container to a git repo + worktree: state lives in `../{repo}.worktrees/{port}/{branch}/`, the port *is* a directory name, the image is per-repo, and the main repo is bind-mounted into every container. Carlos wants to free containers from repos entirely: `dev! <name> [folder=.]` launches a named container that mounts **only the given folder** (rw) plus its own persistent state — nothing else on the machine. Per-container state (bus token, claude home, port) moves to `~/.local/dev-container/<name>/`.

Decisions made with Carlos:
- **docker.sock is dropped by default** (it's root-equivalent on the host; on macOS it grants the Docker VM + everything file-shared, i.e. all of `/Users`). Add an opt-in `--docker` flag for containers that genuinely need to spawn containers, with the risk stated in `--help`.
- **Claude state**: per-name persistent dir `~/.local/dev-container/<name>/claude/` mounted as `/home/dev/.claude`, seeded once from host `~/.claude` (settings, skills, plugins — same filter as today). Replaces both the snapshot-copy and the host `~/.claude/projects` rw mount.
- **Start semantics**: container running → report and quit. Container exists but stopped → `docker rm` and recreate pointing at the current (or given) folder, reusing the stored port/token. No container → create (with confirm prompt). Folder is not sticky — each (re)create binds to the folder from that invocation.
- **`kill <name>`**: stop + rm container, best-effort `docker rmi`, delete `~/.local/dev-container/<name>/` entirely (bus token gone — re-register on next create).
- Git worktree support is removed entirely (clean break). Existing worktree-based containers are unaffected but unmanageable by the new script; note this in the commit message.

## State layout

```
~/.local/dev-container/
  .env              # shared env, any KEY=value lines: AGENT_BUS_URL, GITHUB_USERNAME,
                    # GITHUB_TOKEN_DOTFILES, GITCONFIG, ... (loaded first)
  Dockerfile        # fallback Dockerfile (used when $folder/Dockerfile.dev absent)
  <name>/
    .env            # per-name env, same format: AGENT_BUS_TOKEN, overrides of shared vars
                    # (loaded second — wins over shared)
    port            # host port number (plain text) — NOT in .env, so containers
                    # never see a PORT env var that web frameworks would pick up
    folder          # absolute folder path from the last create/start (for `dev!` listing)
    claude/         # persistent /home/dev/.claude (seeded on first create)
```

**Env hierarchy — both `.env` files are general-purpose.** Everything they define is imported, in order: host environment → shared `.env` → per-name `.env` (later wins).

- **Script-side**: source each file with `set -a; . "$file"; set +a` before doing anything else, so build-time vars defined there (`GITHUB_TOKEN_DOTFILES`, `GITHUB_USERNAME`, `GITCONFIG`) drive the image build exactly as host-env vars do today.
- **Container-side**: pass both to `docker run` as `--env-file shared --env-file per-name` (docker applies later files over earlier ones), so every defined var is present in the container.
- File format must stay plain `KEY=value` (no quotes, no `$expansion`) so sh-sourcing and docker `--env-file` agree — document this in the generated file headers.
- Caveat (by design): anything in these files is visible inside the container at runtime, including GitHub tokens. The BuildKit secret path still keeps the dotfiles token out of image layers.

Missing shared `.env` → create it with commented `AGENT_BUS_URL=` etc. lines (seeded from host env if set, as today).

## Token flow (new)

When `<name>/.env` is missing or `AGENT_BUS_TOKEN` is empty at create time, prompt:

- **(e)nter** — paste an operator-issued token
- **(g)enerate** — `openssl rand -hex 32`
- **(s)kip** — leave empty, container has no bus identity

On enter/generate, write the token to `<name>/.env`, compute `printf '%s' "$token" | shasum -a 256` and print a paste-ready `agents.json` fragment (matches `AgentConfig` in agent-bus/main.go — `token_sha256`, `publish`, `subscribe`):

```json
"<name>": { "token_sha256": "<hash>", "publish": ["*"], "subscribe": ["*"] }
```

with a reminder to add it to the bus's `config/agents.json` before the agent can authenticate.

## New CLI

```
dev!                       # list all names: NAME, PORT, FOLDER, STATUS
dev! <name> [folder] [--docker]   # create/start container for folder (default .)
dev! kill <name>           # stop+rm container, delete ~/.local/dev-container/<name>/
dev! init <base-image>     # skeleton Dockerfile.dev in cwd; --global writes
                           #   ~/.local/dev-container/Dockerfile instead
dev! completion bash|zsh
```

Names are slugified as today. Container and image are both named `dev-<name>` (prefix avoids colliding with unrelated containers; image/container namespaces are separate so sharing the string is fine).

## Implementation (rewrite of dev-container.sh, staying POSIX sh)

Single file, no new dependencies beyond `openssl`/`shasum` (both ship with macOS; guard with command -v and fall back to `openssl dgst -sha256`).

**Remove**: `find_repo_root` usage for the main flow, `get_worktrees_dir`, `find_worktree`, `find_next_port` (worktree scan), all `git branch`/`git worktree` calls, `appsettings.Local.json` copying, `--local` flag and `.local` markers, the repo-root mount, the docker.sock mount (except behind `--docker`), the `~/.claude/projects` mount, the in-container `~/.claude` tar-copy.

**Keep**: colors/error/info/success helpers, `slugify`, `get_claude_credentials` (Keychain), `get_claude_json`, `get_container_status`, BuildKit `github_token` secret, `GITCONFIG`/`GITHUB_USERNAME`/`HOST_UID`/`HOST_GID`/`HOST_PROJECT_PATH` build args, `-p PORT:8000`, `docker exec -it … -u dev bash` attach, confirm prompts before create/kill.

New/changed pieces:

1. **`STATE_HOME="${DEV_CONTAINER_HOME:-$HOME/.local/dev-container}"`**, `mkdir -p` on demand. Early in create/start: `set -a; . "$STATE_HOME/.env"; . "$STATE_HOME/<name>/.env"; set +a` (each if present, shared first) so all user-defined vars are imported hierarchically.
2. **Dockerfile resolution**: `$folder/Dockerfile.dev` → build context `$folder`; else `$STATE_HOME/Dockerfile` → context `$STATE_HOME`; else error pointing at `dev! init`.
3. **Port allocation**: read `<name>/port` if present; else scan all `$STATE_HOME/*/port` files — none → prompt for a starting port (reuse existing validation), else max+1. Write `<name>/port`.
4. **Folder resolution**: `folder=$(cd "${2:-.}" && pwd)` (must exist). Write to `<name>/folder`. **Git caveat check** (warn, don't block): if `$folder/.git` is a plain file → "this is a git worktree; its gitdir lives outside the mount, git will not work inside the container"; else if `git -C "$folder" rev-parse --show-toplevel` resolves to a parent of `$folder` → same style of warning for repo subfolders.
5. **Claude seeding**: if `$STATE_HOME/<name>/claude` doesn't exist, create it and `tar -cf - -C ~/.claude --include=./settings.json --include=./CLAUDE.md --include=./.credentials.json --include='./skills' --include='./skills/*' --include='./plugins' --include='./plugins/*' . | tar -xf - -C "$claude_dir"` (host-side only; no docker exec). Keep passing `CLAUDE_CODE_CREDENTIALS`/`CLAUDE_JSON` env vars for the entrypoint contract.
6. **`docker run`**: `--init -d --name dev-<name> -p PORT:8000 -e CLAUDE_CODE_CREDENTIALS -e CLAUDE_JSON --env-file shared.env --env-file name.env -v "$folder:$folder" -v "$claude_dir:/home/dev/.claude" -w "$folder" dev-<name> tail -f /dev/null`; plus `-v /var/run/docker.sock:/var/run/docker.sock` only under `--docker`.
7. **Start-or-create logic** per decided semantics: running → `info` + exit 0; stopped → `docker rm`, rebuild image, recreate (reuse port/token, current folder); none → confirm prompt (name, folder, container, port, Dockerfile source), then token flow, build, run, attach.
8. **`cmd_list`**: iterate `$STATE_HOME/*/`, print NAME / PORT (`port` file) / FOLDER (`folder` file) / STATUS (`get_container_status dev-<name>`), colorized as today. No git required.
9. **`cmd_kill`**: confirm; stop/rm container, `docker rmi dev-<name> 2>/dev/null || true`, `rm -rf "$STATE_HOME/<name>"`.
10. **`cmd_init`**: unchanged skeleton content, but honor `--global` (write `$STATE_HOME/Dockerfile`, no repo needed); the skeleton's comment header updates (HOST_PROJECT_PATH now "target folder path, for path parity").
11. **`cmd_completion`**: complete `kill` + names from `ls "$STATE_HOME"` (dirs only); drop all git/worktree scanning.
12. **`show_help`**: full rewrite — new syntax, state layout, token flow, and an honest isolation statement: container sees only the target folder + its own claude dir; network is NOT isolated; `--docker` grants root-equivalent host access.

## Docs to update

- `CLAUDE.md` → "Architecture: dev-container.sh" section: replace worktree/port-dir/local-mode description with the new model (state home, per-name env files, token flow, isolation stance).
- `README.md`: update the dev-container usage/description section to the new syntax.

## Verification

1. `shellcheck dev-container.sh && shfmt -d dev-container.sh`
2. Smoke test in a scratch dir (uses this repo's own `Dockerfile.dev` copied to `~/.local/dev-container/Dockerfile` or a trivial `FROM debian` fallback):
   - `dev! test1` in a folder with no Dockerfile.dev → falls back to `~/.local/dev-container/Dockerfile`; token prompt appears; generate → correct sha256 fragment printed (`printf '%s' tok | shasum -a 256` cross-check); container starts; inside: cwd is the folder at the same absolute path, `/home/dev/.claude/settings.json` present, `AGENT_BUS_URL`/`AGENT_BUS_TOKEN` set, `/var/run/docker.sock` absent, `ls /Users/carlos` fails (only the folder is visible).
   - `dev! test1` again while running → reports and quits. `docker stop dev-test1; dev! test1` from a different folder → recreates bound to the new folder, same port/token.
   - `dev!` lists it; `dev! kill test1` removes container and `~/.local/dev-container/test1/`.
   - Launch from a git worktree folder → warning printed, container still starts.
