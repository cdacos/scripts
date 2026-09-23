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
#   AGENT_UNIT          the systemd --user unit running this   (default: agent-claude.service)
#
# The opening turn also carries a few launch facts -- Claude Code version (and
# the one the previous start ran), a start counter, systemd's auto-restart
# count, and the working directory as a link into the bus Files tab. They are
# computed here, not by the agent, so the operator reading the prompt over
# Remote Control sees them without spending a turn. The counter and previous
# version live in $XDG_STATE_HOME/agent/run-starts.
set -eu

# Load the agent's environment FIRST (agent-env.sh; see 2. above), by re-running
# this script once under it: the launch facts need AGENT_BUS_URL and
# AGENT_BUS_FS_ROOT, which only that environment has. Only exported variables
# survive, which is all claude ever received anyway.
if [ -z "${AGENT_RUN_ENV_LOADED:-}" ]; then
    AGENT_RUN_ENV_LOADED=1
    export AGENT_RUN_ENV_LOADED
    exec /bin/bash -lc '. "$1" || exit 1; shift; exec "$@"' \
        agent-run "$HOME/.local/bin/agent-env.sh" /bin/sh "$0" "$@"
fi
unset AGENT_RUN_ENV_LOADED

conf="${XDG_CONFIG_HOME:-$HOME/.config}/agent/run.conf"
[ -r "$conf" ] && . "$conf"

AGENT_NAME="${AGENT_NAME:-$(id -un)}"
AGENT_WORKDIR="${AGENT_WORKDIR:-$HOME/src}"
AGENT_CLAUDE_ARGS="${AGENT_CLAUDE_ARGS:---dangerously-skip-permissions --thinking-display summarized}"
AGENT_RESUME="${AGENT_RESUME:-1}"
AGENT_UNIT="${AGENT_UNIT:-agent-claude.service}"
# One prompt for both paths. It has to read correctly on a resumed session AND
# on a cold start, because --continue silently does the latter when there is
# nothing to continue and the script cannot tell the two apart without
# reimplementing the harness's transcript-path mangling.
AGENT_START_PROMPT="${AGENT_START_PROMPT:-Supervisor start: systemd launched this session, not a human. If this is a resumed conversation, your previous turn was cut off mid-flight by a harness update -- that interruption is expected, not a fault, and any in-flight tool call is gone. Arm your agent-bus monitor now (agent-bus-cli.sh wake with Bash run_in_background, not the Monitor tool), handle any un-acked mail, then go idle. Acknowledge in one line.}"

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

# --- launch facts ------------------------------------------------------------
# Every probe is best-effort: a missing fact is left out, never fatal. A start
# must not fail because of a status line.
launch_facts() {
    _version=$(claude --version 2>/dev/null | awk 'NR == 1 { print $1 }') || _version=
    _state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/agent"
    _state="$_state_dir/run-starts"
    # One line: <count> <version at that start> <date tracking began>
    _count=0 _prev= _since=
    [ -r "$_state" ] && read -r _count _prev _since <"$_state" 2>/dev/null || true
    case "$_count" in '' | *[!0-9]*) _count=0 ;; esac
    _count=$((_count + 1))
    [ -n "$_since" ] || _since=$(date -u +%Y-%m-%d)
    if mkdir -p "$_state_dir" 2>/dev/null &&
        printf '%s %s %s\n' "$_count" "${_version:-${_prev:--}}" "$_since" >"$_state.tmp" 2>/dev/null; then
        mv -f "$_state.tmp" "$_state" 2>/dev/null || true
    fi
    [ "$_prev" = - ] && _prev=

    printf 'Launch facts (computed by agent-run.sh, not the agent):\n'
    if [ -n "$_version" ]; then
        if [ -z "$_prev" ]; then
            printf -- '- Claude Code %s (previous start: unknown)\n' "$_version"
        elif [ "$_prev" = "$_version" ]; then
            printf -- '- Claude Code %s (unchanged since the previous start)\n' "$_version"
        else
            printf -- '- Claude Code %s (previous start ran %s)\n' "$_version" "$_prev"
        fi
    fi
    _nr=$(systemctl --user show "$AGENT_UNIT" -p NRestarts --value 2>/dev/null) || _nr=
    case "$_nr" in
        '' | *[!0-9]*) printf -- '- Start #%s since %s\n' "$_count" "$_since" ;;
        *) printf -- '- Start #%s since %s; systemd auto-restarts since the last deliberate start: %s\n' "$_count" "$_since" "$_nr" ;;
    esac

    # The Files tab serves AGENT_BUS_FS_ROOT (default ~/src), addressed as
    # #files/<agent>/<path relative to it>/ -- same default as agent-bus-fsd.sh.
    _cwd=$(pwd -P)
    _root=$(cd "${AGENT_BUS_FS_ROOT:-$HOME/src}" 2>/dev/null && pwd -P) || _root=
    _rel=
    case "$_cwd/" in
        "$_root"/*) _rel=${_cwd#"$_root"} _rel=${_rel#/} ;;
        *) _root= ;;
    esac
    if [ -n "$_root" ] && [ -n "${AGENT_BUS_URL:-}" ]; then
        _link="${AGENT_BUS_URL%/}/ui#files/$AGENT_NAME/${_rel:+$_rel/}"
        _link=$(printf '%s' "$_link" | sed 's/ /%20/g')
        printf -- '- Working directory: [%s](%s)\n' "$_cwd" "$_link"
    else
        printf -- '- Working directory: %s\n' "$_cwd"
    fi
}
facts=$(launch_facts 2>/dev/null) || facts=

# Word splitting on AGENT_CLAUDE_ARGS is deliberate: it is a flag list.
# shellcheck disable=SC2086
set -- claude $AGENT_CLAUDE_ARGS --remote-control "$AGENT_NAME"
if [ "$AGENT_RESUME" = 1 ]; then
    set -- "$@" --continue
fi
# Appended rather than templated into the default, so a run.conf that replaces
# AGENT_START_PROMPT still gets the facts.
if [ -n "$facts" ]; then
    set -- "$@" "$AGENT_START_PROMPT

$facts"
else
    set -- "$@" "$AGENT_START_PROMPT"
fi

if [ "$AGENT_RESUME" = 1 ]; then
    echo "agent-run: starting agent '$AGENT_NAME' in $(pwd) (resuming previous conversation)" >&2
else
    echo "agent-run: starting agent '$AGENT_NAME' in $(pwd) (fresh session, AGENT_RESUME=$AGENT_RESUME)" >&2
fi
exec "$@"
