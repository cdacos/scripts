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
#
# Per-box overrides in ~/.config/agent/run.conf (deliberately NOT chezmoi-managed):
#   AGENT_NAME          bus identity + --remote-control name   (default: $USER)
#   AGENT_WORKDIR       cwd for the session                    (default: ~/src)
#   AGENT_CLAUDE_ARGS   flag list, word-split                  (default: below)
#   AGENT_START_PROMPT  the opening turn
set -eu

conf="${XDG_CONFIG_HOME:-$HOME/.config}/agent/run.conf"
[ -r "$conf" ] && . "$conf"

AGENT_NAME="${AGENT_NAME:-$(id -un)}"
AGENT_WORKDIR="${AGENT_WORKDIR:-$HOME/src}"
AGENT_CLAUDE_ARGS="${AGENT_CLAUDE_ARGS:---dangerously-skip-permissions --thinking-display summarized}"
AGENT_START_PROMPT="${AGENT_START_PROMPT:-Supervisor start: systemd launched this session, not a human. Arm your agent-bus monitor now (agent-bus-cli.sh wake as a background task), handle any un-acked mail, then go idle. Acknowledge in one line.}"

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
set -- claude $AGENT_CLAUDE_ARGS --remote-control "$AGENT_NAME" "$AGENT_START_PROMPT"

echo "agent-run: starting agent '$AGENT_NAME' in $(pwd)" >&2
exec /bin/bash -lc '. "$1" || exit 1; shift; exec "$@"' \
    agent-run "$HOME/.local/bin/agent-env.sh" "$@"
