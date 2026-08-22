#!/bin/sh
# agent-update-check.sh - keep the *running* agent on the *installed* harness.
#
# `claude update` fetches a new build into ~/.local/share/claude/versions/ and
# moves the ~/.local/bin/claude symlink. The running process keeps its original
# inode, so the restart IS the update -- without one the box runs whatever
# version it booted with, indefinitely. Measured on marvin 2026-08-22: PID 1525
# still on 2.1.234 while the symlink had pointed at 2.1.238 since 21 Aug.
#
# Run by agent-update.timer. Restarts agent-claude.service only when the box is
# genuinely idle; see is_idle() for what that means and why it may be imperfect.
#
# Per-box overrides in ~/.config/agent/run.conf:
#   AGENT_UPDATE_MODE       auto | notify   (notify = report drift, never act)
#   AGENT_IDLE_QUIET_SECS   transcript silence required   (default 600)
#   AGENT_IDLE_CPU_TICKS    max CPU ticks over a 5s sample (default 20)
#   AGENT_KEEP_VERSIONS     harness builds to retain       (default 3)
#   AGENT_DEFER_WARN_HOURS  warn if drift persists this long (default 72)
set -eu

conf="${XDG_CONFIG_HOME:-$HOME/.config}/agent/run.conf"
[ -r "$conf" ] && . "$conf"

AGENT_UPDATE_MODE="${AGENT_UPDATE_MODE:-auto}"
AGENT_IDLE_QUIET_SECS="${AGENT_IDLE_QUIET_SECS:-600}"
AGENT_IDLE_CPU_TICKS="${AGENT_IDLE_CPU_TICKS:-20}"
AGENT_KEEP_VERSIONS="${AGENT_KEEP_VERSIONS:-3}"
AGENT_DEFER_WARN_HOURS="${AGENT_DEFER_WARN_HOURS:-72}"

VERSIONS_DIR="$HOME/.local/share/claude/versions"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent"
DEFER_MARKER="$STATE_DIR/update-deferred-since"
LOCK="$STATE_DIR/update-check.lock"

mkdir -p "$STATE_DIR"

log() { echo "agent-update: $*" >&2; }

# The timer's environment is systemd's, which has neither AGENT_BUS_TOKEN nor
# ~/.local/bin on PATH. agent-env.sh restores both; see it for why the obvious
# alternatives do not. Env-load chatter goes to /dev/null here because callers
# parse stdout.
#
# AGENT_BUS_SESSION is pinned because agent-bus-cli.sh derives a session identity
# by walking the ancestry to the owning `claude`. Under the timer there is none,
# so it falls back to a parent PID that differs every tick -- three ticks
# registered Marvin-10, -11 and -12 before this was caught. That matters beyond
# tidiness: "two sessions on one identity" is the very signal this design uses to
# detect a one-per-VM violation, and a timer minting a fresh session each day
# would forge it. Pinned, the timer holds exactly one obviously-named slot and
# never claims (the claim is taken by monitoring, which the timer does not do).
AGENT_BUS_SESSION="${AGENT_BUS_SESSION:-$(hostname 2>/dev/null || echo host)-update-timer}"
export AGENT_BUS_SESSION

in_agent_env() {
    /bin/bash -lc '. "$1" >/dev/null 2>&1 || exit 127; shift; exec "$@"' \
        agent-env "$HOME/.local/bin/agent-env.sh" "$@"
}
bus() { in_agent_env agent-bus-cli.sh "$@"; }

# --- idle gate -------------------------------------------------------------
# There is no reliable way to ask from outside whether the agent is mid-thought,
# so this is a cheap conjunction of three observable proxies. It is allowed to be
# imperfect because the bus makes a badly-timed restart survivable: `ack` means
# *handled*, not *delivered*, so mail in flight is re-delivered within one wait
# window. The worst case is a repeated turn, not a dropped request.
#
# NOTE: an armed `agent-bus-cli.sh wake` is NOT an idle signal, despite being the
# obvious candidate. Verified on marvin: four wake processes were live while the
# agent was actively mid-turn. The monitor is armed the whole time, not just when
# waiting, so it distinguishes nothing.

inbox_clear() {
    _json=$(bus inbox 2>/dev/null) || return 1   # bus unreachable -> assume busy
    printf '%s' "$_json" | jq -e '(.messages // []) | length == 0' >/dev/null 2>&1
}

transcripts_quiet() {
    _newest=$(find "$HOME/.claude/projects" -name '*.jsonl' -printf '%T@\n' 2>/dev/null |
        sort -rn | head -n 1)
    [ -n "$_newest" ] || return 0
    _age=$(( $(date +%s) - ${_newest%%.*} ))
    [ "$_age" -ge "$AGENT_IDLE_QUIET_SECS" ]
}

cpu_quiet() {
    _pid=$1
    _a=$(awk '{print $14+$15}' "/proc/$_pid/stat" 2>/dev/null) || return 1
    sleep 5
    _b=$(awk '{print $14+$15}' "/proc/$_pid/stat" 2>/dev/null) || return 1
    [ "$(( _b - _a ))" -le "$AGENT_IDLE_CPU_TICKS" ]
}

is_idle() {
    inbox_clear     || { log "  busy: un-acked mail in the inbox"; return 1; }
    transcripts_quiet || { log "  busy: transcript written in the last ${AGENT_IDLE_QUIET_SECS}s"; return 1; }
    cpu_quiet "$1"  || { log "  busy: claude burning CPU"; return 1; }
    return 0
}

# --- pruning ---------------------------------------------------------------
# Keep the newest AGENT_KEEP_VERSIONS builds, and never drop the one in use or
# the one the symlink points at, whatever their age.
prune_versions() {
    _running=$1
    _installed=$2
    [ -d "$VERSIONS_DIR" ] || return 0
    ls -1t "$VERSIONS_DIR" 2>/dev/null | tail -n +$(( AGENT_KEEP_VERSIONS + 1 )) |
    while IFS= read -r v; do
        case "$v" in '' | . | .. | */*) continue ;; esac
        [ "$v" = "$_running" ] && continue
        [ "$v" = "$_installed" ] && continue
        log "pruning retired harness $v"
        rm -rf -- "${VERSIONS_DIR:?}/$v"
    done
}

# --- main ------------------------------------------------------------------
main() {
    # Units may have been refreshed on disk by chezmoi since the last run;
    # nothing else reloads them.
    systemctl --user daemon-reload 2>/dev/null || true

    if [ "$AGENT_UPDATE_MODE" = auto ]; then
        in_agent_env claude update 2>&1 | sed 's/^/agent-update:   /' >&2 ||
            log "claude update failed; continuing with what is on disk"
    fi

    pid=$(pgrep -u "$(id -u)" -x claude 2>/dev/null | head -n 1 || true)
    if [ -z "$pid" ]; then
        log "no running claude -- nothing to compare or restart"
        return 0
    fi

    # Compare fully resolved paths, not basenames. A native install resolves both
    # sides to versions/<v>, but not every box is native: tweety's claude is
    # /usr/bin/claude with no versions/ dir at all. Basenames there would read
    # "claude" vs "claude" or "claude" vs "unknown" -- either a missed update or,
    # worse, permanent phantom drift restarting the agent every day forever.
    running_path=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
    installed_path=$(in_agent_env sh -c 'command -v claude' 2>/dev/null || true)
    [ -n "$installed_path" ] && installed_path=$(readlink -f "$installed_path" 2>/dev/null || true)

    if [ -z "$running_path" ] || [ -z "$installed_path" ]; then
        log "cannot resolve both harness paths (running='$running_path' installed='$installed_path') -- refusing to guess; no restart"
        return 0
    fi

    running=$(basename "$running_path")
    installed=$(basename "$installed_path")

    # Only meaningful on a native install; a no-op where there is no versions/ dir.
    prune_versions "$running" "$installed"

    if [ "$running_path" = "$installed_path" ]; then
        log "up to date ($running); no restart"
        rm -f "$DEFER_MARKER"
        return 0
    fi

    log "harness drift: PID $pid runs $running_path, installed is $installed_path"
    [ -f "$DEFER_MARKER" ] || date +%s > "$DEFER_MARKER"

    if [ "$AGENT_UPDATE_MODE" != auto ]; then
        log "AGENT_UPDATE_MODE=$AGENT_UPDATE_MODE -- reporting only, leaving the agent alone"
        return 0
    fi

    if is_idle "$pid"; then
        log "idle -- restarting agent-claude.service onto $installed"
        rm -f "$DEFER_MARKER"
        systemctl --user restart agent-claude.service
        return 0
    fi

    since=$(cat "$DEFER_MARKER" 2>/dev/null || echo 0)
    hours=$(( ( $(date +%s) - since ) / 3600 ))
    if [ "$hours" -ge "$AGENT_DEFER_WARN_HOURS" ]; then
        log "WARNING: drift deferred for ${hours}h -- the box has not been idle since. Restart by hand: systemctl --user restart agent-claude.service"
    else
        log "busy -- deferring to the next tick (drift ${hours}h old)"
    fi
}

# One check at a time; a 5s CPU sample plus a network update can overlap ticks.
exec 9>"$LOCK"
flock -n 9 || { log "another check is already running"; exit 0; }
main
