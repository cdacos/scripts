#!/bin/sh
# agent-run.sh - start the one Claude Code agent for this box.
#
# Run by agent-claude.service. It does the three things systemd itself cannot:
#
#   1. One per VM. Refuses to start when another `claude` already owns the box,
#      and says which PID holds it.
#   2. Environment by reference, not by copy, via agent-env.sh -- which is where
#      the reasoning lives. Short version: neither EnvironmentFile nor a bare
#      `bash -lc` actually restores the agent's environment, and both failures are
#      silent.
#   3. Opens with a prompt. A restarted agent that is never given a turn never
#      fires its Stop hook -- and it is the Stop hook (agent-bus-monitor-guard.sh)
#      that arms the bus monitor. A promptless restart comes back alive but deaf
#      to its inbox, which would make supervision a downgrade rather than a fix.
#      The SessionStart hook (agent-bus-cli.sh onboard) is NOT a substitute: it
#      injects context, it does not create a turn, so Stop never fires without a
#      prompt. It does fire on every source including `resume`, so the briefing
#      still lands on a resumed session.
#   4. Resumes the previous conversation instead of starting cold. This is what
#      makes the update gate cheap: the reason agent-update-check.sh needs an
#      idle detector at all is that a restart used to destroy the agent's
#      context. Resuming turns "lost the turn" into "repeat the turn", so an
#      imperfect gate stops being expensive -- and an honest cheap signal beats
#      a clever one that is wrong in both directions.
#
#      `--continue` (most recent conversation in the cwd) rather than
#      `--resume <id>`: no session id to track, and no need to guess which
#      .jsonl is live from mtime -- a guess that `/clear` invalidates anyway,
#      since it rotates the session id mid-life. With nothing to continue it
#      starts a fresh session and exits 0 (verified on marvin 2026-08-27), so
#      the fresh-box case needs no guard.
#
#      The in-flight tool call is still lost -- resume restores the
#      conversation, not the interrupted `make`. Un-acked mail is safe by the
#      bus's own rule (ack means handled, so it is re-delivered). Set
#      AGENT_RESUME=0 to opt out.
#
# Per-box overrides in ~/.config/agent/run.conf (deliberately NOT chezmoi-managed):
#   AGENT_NAME          bus identity + --remote-control name   (default: $USER)
#   AGENT_WORKDIR       cwd for the session                    (default: ~/src)
#   AGENT_CLAUDE_ARGS   flag list, word-split                  (default: below)
#   AGENT_START_PROMPT  the opening turn
#   AGENT_RESUME        1 = --continue the previous conversation (default 1)
set -eu

conf="${XDG_CONFIG_HOME:-$HOME/.config}/agent/run.conf"
[ -r "$conf" ] && . "$conf"

AGENT_NAME="${AGENT_NAME:-$(id -un)}"
AGENT_WORKDIR="${AGENT_WORKDIR:-$HOME/src}"
AGENT_CLAUDE_ARGS="${AGENT_CLAUDE_ARGS:---dangerously-skip-permissions --thinking-display summarized}"
AGENT_RESUME="${AGENT_RESUME:-1}"
# One prompt for both paths. It has to read correctly on a resumed session AND
# on a cold start, because --continue silently does the latter when there is
# nothing to continue and the script cannot tell the two apart without
# reimplementing the harness's transcript-path mangling.
AGENT_START_PROMPT="${AGENT_START_PROMPT:-Supervisor start: systemd launched this session, not a human. If this is a resumed conversation, your previous turn was cut off mid-flight by a harness update -- that interruption is expected, not a fault, and any in-flight tool call is gone. Arm your agent-bus monitor now (agent-bus-cli.sh wake as a background task), handle any un-acked mail, then go idle. Acknowledge in one line.}"

# --- one per VM ------------------------------------------------------------
# A non-templated unit is already single-instance; this catches the other case,
# a human starting a second claude by hand in a stray terminal.
holder=$(pgrep -u "$(id -u)" -x claude 2>/dev/null | head -n 1 || true)
if [ -n "$holder" ]; then
    echo "agent-run: refusing to start -- claude already owns this box (PID $holder)" >&2
    ps -o pid=,lstart=,args= -p "$holder" >&2 || true
    exit 1
fi

cd "$AGENT_WORKDIR" 2>/dev/null || cd "$HOME"

# Word splitting on AGENT_CLAUDE_ARGS is deliberate: it is a flag list.
# shellcheck disable=SC2086
set -- claude $AGENT_CLAUDE_ARGS --remote-control "$AGENT_NAME"
if [ "$AGENT_RESUME" = 1 ]; then
    set -- "$@" --continue
fi
set -- "$@" "$AGENT_START_PROMPT"

if [ "$AGENT_RESUME" = 1 ]; then
    echo "agent-run: starting agent '$AGENT_NAME' in $(pwd) (resuming previous conversation)" >&2
else
    echo "agent-run: starting agent '$AGENT_NAME' in $(pwd) (fresh session, AGENT_RESUME=$AGENT_RESUME)" >&2
fi
exec /bin/bash -lc '. "$1" || exit 1; shift; exec "$@"' \
    agent-run "$HOME/.local/bin/agent-env.sh" "$@"
