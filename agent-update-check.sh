#!/bin/sh
# agent-update-check.sh - keep the *running* agent on the *installed* harness.
#
# `claude update` fetches a new build into ~/.local/share/claude/versions/ and
# moves the ~/.local/bin/claude symlink. The running process keeps its original
# inode, so the restart IS the update -- without one the box runs whatever
# version it booted with, indefinitely. Measured on marvin 2026-08-22: PID 1525
# still on 2.1.234 while the symlink had pointed at 2.1.238 since 21 Aug.
#
# Run by agent-update.timer. Restarts agent-claude.service when the box looks
# idle -- see is_idle() for what that means and why it is imperfect -- and, past
# AGENT_DEFER_MAX_HOURS, whether it looks idle or not. The ceiling exists because
# the gate's proxies can be wrong in the direction of "busy" indefinitely.
#
# Per-box overrides in ~/.config/agent/run.conf:
#   AGENT_UPDATE_MODE       auto | notify   (notify = report drift, never act)
#   AGENT_IDLE_SETTLE_SECS  quiet needed since the last transcript write (120)
#   AGENT_IDLE_SAMPLE_SECS  length of the live activity sample  (default 30)
#   AGENT_IDLE_CPU_TICKS    max CPU ticks over that sample      (default 20)
#   AGENT_KEEP_VERSIONS     harness builds to retain            (default 3)
#   AGENT_DEFER_WARN_HOURS  warn if drift persists this long    (default 24)
#   AGENT_DEFER_MAX_HOURS   restart anyway past this            (default 48)
#   AGENT_IDLE_QUIET_SECS   deprecated alias for _SETTLE_SECS
set -eu

conf="${XDG_CONFIG_HOME:-$HOME/.config}/agent/run.conf"
[ -r "$conf" ] && . "$conf"

AGENT_UPDATE_MODE="${AGENT_UPDATE_MODE:-auto}"
# _QUIET_SECS was this knob's name when it meant "mtime silence"; boxes may still
# set it in run.conf, so it is honoured as the settle value rather than ignored.
AGENT_IDLE_SETTLE_SECS="${AGENT_IDLE_SETTLE_SECS:-${AGENT_IDLE_QUIET_SECS:-120}}"
AGENT_IDLE_SAMPLE_SECS="${AGENT_IDLE_SAMPLE_SECS:-30}"
AGENT_IDLE_CPU_TICKS="${AGENT_IDLE_CPU_TICKS:-20}"
AGENT_KEEP_VERSIONS="${AGENT_KEEP_VERSIONS:-3}"
AGENT_DEFER_WARN_HOURS="${AGENT_DEFER_WARN_HOURS:-24}"
AGENT_DEFER_MAX_HOURS="${AGENT_DEFER_MAX_HOURS:-48}"

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

# The newest transcript under ~/.claude/projects, as "<epoch> <size> <path>".
newest_transcript() {
    find "$HOME/.claude/projects" -name '*.jsonl' -printf '%T@ %s %p\n' 2>/dev/null |
        sort -rn | head -n 1
}

newest_size() {
    _r=$(newest_transcript)
    [ -n "$_r" ] || { echo 0; return 0; }
    _r=${_r#* }; _r=${_r%% *}
    case "$_r" in '' | *[!0-9]*) echo 0 ;; *) echo "$_r" ;; esac
}

# Has the newest transcript been left alone long enough? 0 quiet, 1 recent, 2
# could not measure -- the third case matters, see is_idle().
#
# Touched, not written: mtime is a far weaker signal than it looks. Measured on
# marvin 2026-08-26, 90 samples across 30 idle minutes: the live session's
# transcript moved mtime 09:58:01 -> 10:00:50 with size AND line count byte
# identical, 169s after the turn ended, with the agent doing nothing at all. The
# harness rewrites bookkeeping records on a session that is merely open --
# bridge-session, atis-latch, ai-title, last-prompt, queue-operation; 33 of 109
# lines in that file carry no timestamp whatsoever. A 600s window against that
# stamp is what kept this box on a stale harness: of the five ticks in the week
# to 26 Aug, three deferred, one with the drift already 38h old.
#
# So the settle window is short and deliberately not load-bearing -- the live
# sample below is what decides. The residual failure is bounded: a bookkeeping
# touch landing inside the window costs one tick, and AGENT_DEFER_MAX_HOURS caps
# how many such ticks can pass before the restart happens anyway.
transcripts_settled() {
    TRANSCRIPT_WITNESS=''
    _rec=$(newest_transcript) || return 2
    [ -n "$_rec" ] || return 0          # no transcripts at all -> nothing to wait on
    _mt=${_rec%% *}; _mt=${_mt%%.*}
    _rest=${_rec#* }
    _size=${_rest%% *}
    _path=${_rest#* }
    _now=$(date +%s)
    case "$_mt" in '' | *[!0-9]*) return 2 ;; esac
    case "$_now" in '' | *[!0-9]*) return 2 ;; esac
    _age=$(( _now - _mt ))
    TRANSCRIPT_WITNESS="$(basename "$_path") touched ${_age}s ago, ${_size}B"
    [ "$_age" -ge "$AGENT_IDLE_SETTLE_SECS" ]
}

# One window, two signals: is the agent burning CPU, and is its transcript
# actually growing? Growth is the honest form of the mtime test -- a real turn
# appends bytes, bookkeeping does not. 0 idle, 1 active, 2 could not measure.
activity_quiet() {
    _pid=$1
    ACTIVITY_WITNESS=''
    _cpu_a=$(awk '{print $14+$15}' "/proc/$_pid/stat" 2>/dev/null) || return 2
    _size_a=$(newest_size)
    sleep "$AGENT_IDLE_SAMPLE_SECS"
    _cpu_b=$(awk '{print $14+$15}' "/proc/$_pid/stat" 2>/dev/null) || return 2
    _size_b=$(newest_size)
    _ticks=$(( _cpu_b - _cpu_a ))
    _grew=$(( _size_b - _size_a ))
    if [ "$_grew" -gt 0 ]; then
        ACTIVITY_WITNESS="transcript grew ${_grew}B over a ${AGENT_IDLE_SAMPLE_SECS}s sample"
        return 1
    fi
    if [ "$_ticks" -gt "$AGENT_IDLE_CPU_TICKS" ]; then
        ACTIVITY_WITNESS="claude burned ${_ticks} CPU ticks (limit ${AGENT_IDLE_CPU_TICKS}) over ${AGENT_IDLE_SAMPLE_SECS}s"
        return 1
    fi
    ACTIVITY_WITNESS="no transcript growth, ${_ticks} CPU ticks over ${AGENT_IDLE_SAMPLE_SECS}s"
    return 0
}

# Every branch below names what was actually observed. The old gate could not:
# it called each proxy on the left of `||`, which suppresses `set -e` inside the
# function, so a find error, an empty read or a broken $(( )) all surfaced as one
# confident sentence -- "transcript written in the last 600s" -- naming a cause
# nothing had established. Three deferrals in a week were indistinguishable
# afterwards, which is why this took a 90-sample experiment to diagnose rather
# than a journal read. A measurement that fails must say so in its own words.
is_idle() {
    _pid_arg=$1
    inbox_clear || { log "  busy: un-acked mail in the inbox"; return 1; }

    _rc=0; transcripts_settled || _rc=$?
    case "$_rc" in
        0) ;;
        2) log "  busy: could not measure transcript age -- refusing to guess"; return 1 ;;
        *) log "  busy: $TRANSCRIPT_WITNESS (settle window ${AGENT_IDLE_SETTLE_SECS}s)"; return 1 ;;
    esac

    _rc=0; activity_quiet "$_pid_arg" || _rc=$?
    case "$_rc" in
        0) log "  idle: $ACTIVITY_WITNESS"; return 0 ;;
        2) log "  busy: could not sample /proc/$_pid_arg/stat -- refusing to guess"; return 1 ;;
        *) log "  busy: $ACTIVITY_WITNESS"; return 1 ;;
    esac
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
    case "$since" in '' | *[!0-9]*) since=0 ;; esac
    hours=$(( ( $(date +%s) - since ) / 3600 ))

    # A ceiling, because deferral with no upper bound is exactly how a box stays
    # stale forever. The gate samples one instant per day against proxies that
    # are allowed to be wrong; before this, a box that lost the coin toss simply
    # waited another 24h, and AGENT_DEFER_WARN_HOURS only ever printed advice to
    # a journal nobody reads. Past the ceiling the restart wins the argument: the
    # bus re-delivers un-acked mail, so the cost is a repeated turn, against an
    # agent that otherwise never updates at all.
    if [ "$since" -gt 0 ] && [ "$hours" -ge "$AGENT_DEFER_MAX_HOURS" ]; then
        log "drift deferred ${hours}h, at or past the ${AGENT_DEFER_MAX_HOURS}h ceiling -- restarting onto $installed regardless"
        rm -f "$DEFER_MARKER"
        systemctl --user restart agent-claude.service
        return 0
    fi

    if [ "$hours" -ge "$AGENT_DEFER_WARN_HOURS" ]; then
        log "WARNING: drift deferred for ${hours}h -- the box has not been idle since. Restart by hand: systemctl --user restart agent-claude.service"
    else
        log "busy -- deferring to the next tick (drift ${hours}h old)"
    fi
}

# One check at a time; an AGENT_IDLE_SAMPLE_SECS window plus a network update
# can easily overlap the next tick.
exec 9>"$LOCK"
flock -n 9 || { log "another check is already running"; exit 0; }
main
