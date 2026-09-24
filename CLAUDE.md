# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Purpose

Standalone utility shell scripts, distributed as single files via raw GitHub URLs (chezmoi
externals or curl — see README.md). **Every script must stay self-contained in one file**, with no
dependency on any other file in this repo.

## Commands

No test framework. Lint and format with:

```sh
shellcheck *.sh
shfmt -d .          # shfmt -w to fix
```

## Conventions

- Top-level scripts are POSIX sh (`#!/bin/sh`): no arrays, no `[[ ]]`. Scripts under
  `jellyfin-media-player/` are bash.
- **Test exit status, not output emptiness.** An erroring command leaves stdout empty, which reads
  exactly like "nothing found".
- **Never hand jq a payload through `--arg`/`--argjson`** — `MAX_ARG_STRLEN` caps one argv entry
  at 128 KiB and the failure is silent. Use `--rawfile`.
- A helper cannot report through a global when callers run it in `$(...)` — the subshell's write
  never reaches the parent.
- Pass tokens on stdin (`curl -K -`), not in argv, where any co-resident process can read them in
  `ps`. `agent-bus-fsd.sh` does this; `agent-bus-cli.sh` still passes the token in argv, which is
  a known leak and shouldn't be copied.

## agent-bus-cli.sh

POSIX-sh curl/jq client for the agent-bus HTTP API (service in `../agent-bus`). Reads
`AGENT_BUS_URL`/`AGENT_BUS_TOKEN`. Keep its commands in step with the bus API and its `/docs`.

- **Session key** (`X-Agent-Session`) is `<host>-<supervisor pid>-<starttime>`, found by walking
  the process ancestry to the first `claude`. A fixed hop count would key on a wrapper shell that
  dies every call, and the server allocates a new permanent number for every unseen key.
  `AGENT_BUS_SESSION` overrides the key; `AGENT_BUS_SESSION=none` sends no header, for callers that are
  not sessions (e.g. `agent-update-check.sh` under a timer).
- **One live session per token (409).** The client, not the server, tells a crashed predecessor
  from a rival: if the holder's pid is gone or its start time no longer matches, `evict_session`
  clears it sessionlessly and retries once, silently. Anything that might be alive is reported
  with the exact `unregister <n>` to run and never auto-evicted — being wrong must cost a wait,
  not a working session.
- **The 409 is reported through a flag file plus an `EXIT` trap**, not a return code: most
  commands end `api ... | pretty` or run `$(api ...)`, and both swallow `api`'s status. POSIX runs
  `EXIT` traps only in the main shell, so no subshell can consume the flag. Commands that
  deliberately absorb a refusal call `bus_conflict_handled`.
- **`wake`** long-polls and exits only on real mail. It also exits when its supervisor dies (so a
  ghost cannot hold mail for no one), and after a 60 s damp when refused (its exit re-invokes the
  agent, whose Stop hook re-arms it). **Ack means handled:** monitors `ack <id>...` exactly what
  they acted on; `--ack` and `ack-all` are lossy and are not the monitor's path.
- **`unregister`** with no argument retires this session; it self-gates on the token so a
  `SessionEnd` hook can call it unconditionally:
  `{"SessionEnd":[{"matcher":"","hooks":[{"type":"command","command":"agent-bus-cli.sh unregister 2>/dev/null || true"}]}]}`.
  `~/.claude/settings.json` is hand-rolled on each box and lives in no repo. `unregister <n>`
  retires another session of the same agent.
- **`onboard`** prints the session-start briefing (the SessionStart hook's output). It is read by
  every agent at every `/clear`, so keep it short and imperative.

## agent-bus-fsd.sh

Serves this box's source tree to the bus web UI's Files tab. The bus cannot see anyone's disk and
must not learn how ("the bus stays frozen; new integrations are clients"), so **no bus endpoint
exists for it**.

- **Topics, not DMs** (`fs-req` in, `fs-rsp` out, requests addressed by `meta.agent`). A DM would
  append every click to permanent history, and an inbox long-poll would fight the session monitor
  for the claim on the bare agent name.
- **Replies correlate on `meta.rid`, not order.** Handlers run double-forked (`( cmd & )`), off
  the reader loop: the bus drops nudges to slow subscribers, and a request exists only as a nudge.
  A plain `cmd &` leaks a zombie per request.
- **Reconnect backoff resets after a connection lasting ≥ 60 s** — keyed on duration, not on
  having read a line (a 401 still writes a body). Without the reset, the 30 s cap ratchets, and
  the missed seconds are silent: the bus drops nudges for absent subscribers with no log line.
- **The reader is `curl` into a FIFO read by the daemon's own shell**, not `curl | while read`:
  a backgrounded pipeline puts the loop in a subshell, so `kill` would orphan a second live
  responder. `stop_reader` runs on `EXIT`/`INT`/`TERM` and is idempotent.
- **Three answer sizes:** text under `AGENT_BUS_FS_MAX_INLINE` (256 KiB) in `meta.content`
  (the bus rejects an empty `body`); larger or binary files as content-addressed blobs; over
  `AGENT_BUS_FS_MAX_BLOB` (100 MiB) a clear refusal.
- **Containment is on the logical path.** `..` is rejected as a whole component; the resolved
  path must sit under the root or one of its direct children (so deliberate symlinks such as
  `marvin-memories` work). "Outside the root" and "does not exist" return the same message, so
  probing cannot map the filesystem.
- **Gitignored files and `.git` are withheld** (`AGENT_BUS_FS_GITIGNORE`, default on). That is
  the only layer browsing exposes beyond what pushing already does, and `.git` packs hold deleted
  secrets. Checked at listing time and again on read. Any token may browse; there is no per-agent
  ACL.
- **Fail closed:** with the flag on and no `git`, the daemon refuses to start.
- Search (`fs.grep`) is advertised through `ops` on `fs.ping`. Its engine must be a real binary:
  `command -v rg` can be satisfied by a shell function.

## Other files

- `agent-run.sh` — started by `agent-claude.service`; runs the box's one Claude Code agent (one per
  VM), restores its environment via `agent-env.sh`, and opens it with a prompt so its Stop hook
  arms the bus monitor.
- `agent-env.sh` — sourced, not executed: restores the agent's environment under systemd, where
  `EnvironmentFile=` and `bash -lc` both fail silently.
- `agent-supervision-install.sh` — `install` / `cutover` / `status`: the systemd steps chezmoi
  cannot do (linger, daemon-reload, enable, handing a tmux-started agent over to systemd).
- `agent-update-check.sh` — run by `agent-update.timer`; restarts the agent when the running build
  differs from the installed one (the restart *is* the update), and does the same for long-lived
  daemons.
- `agent-bus-monitor-guard.sh` — Stop hook; blocks idle while no `wake` is running. Self-gates on
  `AGENT_BUS_TOKEN`.
- `systemd/` — `agent.target`, `agent-claude.service`, `agent-fsd.service`, `agent-update.{service,timer}`.
- `check-tools.sh` — reports missing CLI tools from its `TOOLS` table (`cmd|description|apt|brew|url|alt-cmd`) and chezmoi drift.
- `statusline-command.sh` — Claude Code status line.
- `docs/plans/` — historical design plans.
- `jellyfin-media-player/` — bash, systemd and udev files for one Jellyfin HTPC. Machine-specific,
  not distributed.
