#!/bin/sh
# agent-update-check.sh - keep the *running* code on a box equal to the *installed* code.
#
# `claude update` fetches a new build into ~/.local/share/claude/versions/ and
# moves the ~/.local/bin/claude symlink. The running process keeps its original
# inode, so the restart IS the update -- without one the box runs whatever
# version it booted with, indefinitely. Measured on marvin 2026-08-22: PID 1525
# still on 2.1.234 while the symlink had pointed at 2.1.238 since 21 Aug.
#
# The same inode argument applies to every long-lived process that runs from a
# file, not just the harness -- see daemon_drift() for the fleet-wide capability
# outage that proved it.
#
# Guidance (the chezmoi-delivered CLAUDE.md rules) has the same gap one level
# up: merged is not installed. guidance_drift() fast-forwards and applies it
# when the source clone is provably untouched, and only reports otherwise.
#
# Run by agent-update.timer, once a day at 04:00 UK time. Restarts
# agent-claude.service when the box looks idle -- see is_idle() for what that
# means and why it is imperfect -- re-checking for up to AGENT_IDLE_WAIT_SECS,
# and after that whether it looks idle or not. The bound exists because the
# gate's proxies can be wrong in the direction of "busy" indefinitely.
# Managed daemons (AGENT_MANAGED_UNITS) are restarted with no idle gate at all,
# for reasons given at daemon_drift().
#
# The gate is deliberately cheap rather than clever, because agent-run.sh now
# resumes the previous conversation (`--continue`). A badly-timed restart costs
# a repeated turn and one dead in-flight tool call, not the agent's context.
# Once interrupting is cheap, accuracy stops being worth paying for -- so this
# uses one honest signal (does the transcript actually grow?) and retries often,
# instead of stacking proxies that are each wrong in a different direction.
#
# The timer ticks DAILY, at an hour chosen so a restart does not land on the
# operator's working day (the hourly tick it replaced could). One tick a day
# must not mean one idle coin toss a day: losing it used to cost 24 hours, which
# is how a single false "busy" stranded this box on a stale harness for days. So
# the retries happen inside the run instead (restart_when_idle). The network
# fetch keeps its own stamp (AGENT_FETCH_MIN_SECS), so a manual run does not
# re-fetch.
#
# Per-box overrides in ~/.config/agent/run.conf:
#   AGENT_UPDATE_MODE       auto | notify   (notify = report drift, never act)
#   AGENT_IDLE_SETTLE_SECS  quiet needed since the last transcript write (120)
#   AGENT_IDLE_SAMPLE_SECS  length of the live activity sample  (default 30)
#   AGENT_IDLE_WAIT_SECS    keep re-checking for idle this long, then restart
#                           anyway (default 3600; the unit allows 90 min)
#   AGENT_IDLE_RETRY_SECS   pause between those checks          (default 300)
#   AGENT_KEEP_VERSIONS     harness builds to retain            (default 3)
#   AGENT_FETCH_MIN_SECS    min gap between `claude update` runs (default 20h)
#   AGENT_GUIDANCE_SOURCE   chezmoi source to check   (default ~/.local/share/chezmoi)
#   AGENT_GUIDANCE_FETCH    1 = fetch before comparing, 0 = local refs only (default 1)
#   AGENT_GUIDANCE_TIMEOUT  seconds allowed for that fetch      (default 20)
#   AGENT_GUIDANCE_APPLY_TIMEOUT  seconds allowed for each chezmoi call when
#                           guidance is brought current        (default 120)
#   AGENT_IDLE_QUIET_SECS   deprecated alias for _SETTLE_SECS
#   AGENT_DEFER_WARN_HOURS, AGENT_DEFER_MAX_HOURS: retired with the hourly tick,
#                           and ignored if still set
#   AGENT_MANAGED_UNITS     space-separated unit:script pairs whose daemon must
#                           be restarted when its script changes underneath it
#                           (default agent-fsd.service:~/.local/bin/agent-bus-fsd.sh)
set -eu

conf="${XDG_CONFIG_HOME:-$HOME/.config}/agent/run.conf"
[ -r "$conf" ] && . "$conf"

AGENT_UPDATE_MODE="${AGENT_UPDATE_MODE:-auto}"
# _QUIET_SECS was this knob's name when it meant "mtime silence"; boxes may still
# set it in run.conf, so it is honoured as the settle value rather than ignored.
AGENT_IDLE_SETTLE_SECS="${AGENT_IDLE_SETTLE_SECS:-${AGENT_IDLE_QUIET_SECS:-120}}"
AGENT_IDLE_SAMPLE_SECS="${AGENT_IDLE_SAMPLE_SECS:-30}"
AGENT_IDLE_WAIT_SECS="${AGENT_IDLE_WAIT_SECS:-3600}"
AGENT_IDLE_RETRY_SECS="${AGENT_IDLE_RETRY_SECS:-300}"
AGENT_KEEP_VERSIONS="${AGENT_KEEP_VERSIONS:-3}"
AGENT_FETCH_MIN_SECS="${AGENT_FETCH_MIN_SECS:-72000}"
AGENT_GUIDANCE_SOURCE="${AGENT_GUIDANCE_SOURCE:-$HOME/.local/share/chezmoi}"
AGENT_GUIDANCE_FETCH="${AGENT_GUIDANCE_FETCH:-1}"
AGENT_GUIDANCE_TIMEOUT="${AGENT_GUIDANCE_TIMEOUT:-20}"
AGENT_GUIDANCE_APPLY_TIMEOUT="${AGENT_GUIDANCE_APPLY_TIMEOUT:-120}"
AGENT_MANAGED_UNITS="${AGENT_MANAGED_UNITS:-agent-fsd.service:$HOME/.local/bin/agent-bus-fsd.sh}"

VERSIONS_DIR="$HOME/.local/share/claude/versions"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent"
FETCH_STAMP="$STATE_DIR/last-fetch"
GUIDANCE_UNAPPLIED="$STATE_DIR/guidance-unapplied"
LOCK="$STATE_DIR/update-check.lock"

mkdir -p "$STATE_DIR"

log() { echo "agent-update: $*" >&2; }

# The timer's environment is systemd's, which has neither AGENT_BUS_TOKEN nor
# ~/.local/bin on PATH. agent-env.sh restores both; see it for why the obvious
# alternatives do not. Env-load chatter goes to /dev/null here because callers
# parse stdout.
#
# The timer takes NO session identity at all. agent-bus-cli.sh derives one by
# walking the ancestry to the owning `claude`; under the timer there is none, so
# it fell back to a parent PID that differs every tick -- three ticks registered
# Marvin-10, -11 and -12 before this was caught. Pinning a fixed name fixed the
# churn but not the premise, and the premise is now wrong twice over. A token
# carries ONE live session, so a pinned second name is refused outright and
# would leave the timer unable to speak. And it needs no identity to begin with:
# its only bus calls are a plain `inbox` listing, which the server treats as a
# cursor-neutral read that takes no claim, and a heartbeat topic publish, which
# carries its own host in the body. Sessionless is the legacy client path the
# bus has always supported -- exactly what a cron job should be.
#
# It also un-breaks the idle gate. GET /inbox with a session key returns the
# UNION of the agent inbox and that session's own only for the session holding
# the claim; every other session sees its own queue and nothing else. The timer
# never monitors, so it never held the claim, so it was reading an always-empty
# private queue -- and inbox_clear, whose whole job is "is there un-acked mail",
# answered yes every time. Sessionless reads the agent inbox, which is where the
# mail actually is.
AGENT_BUS_SESSION=none
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
# touch landing inside the window costs one retry, and AGENT_IDLE_WAIT_SECS caps
# how many such retries can pass before the restart happens anyway.
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

# One window, one signal: is the transcript actually growing? A real turn
# appends bytes; the harness's bookkeeping rewrites do not. That is what makes
# growth the honest form of the old mtime test. 0 idle, 1 active, 2 could not
# measure.
#
# There was a second arm here that sampled the agent's own CPU. It is gone, and
# both reasons were measured on marvin 2026-08-27:
#
#   - Its floor sat above its own threshold. Five consecutive 30s samples of a
#     provably idle agent (zero transcript growth, no terminal output for 7h)
#     read 76, 88, 98, 78, 76 ticks against a limit of 20. It could not return
#     "idle" on this box at any time, ever. It is what kept marvin on 2.1.243
#     for three days after the mtime bug above was already fixed.
#   - The case it was meant to cover, it never covered. Its stated job was the
#     long tool call that appends nothing for minutes -- but during a build the
#     cycles go to the compiler while `claude` blocks on a pipe, so the harness
#     looks *more* idle mid-build, not less. The arm was load-bearing for
#     nothing and wrong for everything.
#
# Raising the threshold was the obvious fix and is not the right one: busy
# samples measured 270-378 ticks against an idle floor of 76-98, barely 3x
# apart, so any constant is a guess that has to hold across three VMs and every
# future harness build. A signal that needs per-box calibration to be correct is
# not a signal. Resume is what makes deleting it affordable.
activity_quiet() {
    ACTIVITY_WITNESS=''
    _size_a=$(newest_size)
    sleep "$AGENT_IDLE_SAMPLE_SECS"
    _size_b=$(newest_size)
    _grew=$(( _size_b - _size_a ))
    if [ "$_grew" -gt 0 ]; then
        ACTIVITY_WITNESS="transcript grew ${_grew}B over a ${AGENT_IDLE_SAMPLE_SECS}s sample"
        return 1
    fi
    ACTIVITY_WITNESS="no transcript growth over ${AGENT_IDLE_SAMPLE_SECS}s"
    return 0
}

# Every branch below names what was actually observed. The old gate could not:
# it called each proxy on the left of `||`, which suppresses `set -e` inside the
# function, so a find error, an empty read or a broken $(( )) all surfaced as one
# confident sentence -- "transcript written in the last 600s" -- naming a cause
# nothing had established. Three deferrals in a week were indistinguishable
# afterwards, which is why this took a 90-sample experiment to diagnose rather
# than a journal read. A measurement that fails must say so in its own words.
# The pid argument is retained for the caller's readability and for the log
# line above; nothing in the gate reads /proc any more.
is_idle() {
    _pid_arg=$1
    [ -n "$_pid_arg" ] || return 1
    inbox_clear || { log "  busy: un-acked mail in the inbox"; return 1; }

    _rc=0; transcripts_settled || _rc=$?
    case "$_rc" in
        0) ;;
        2) log "  busy: could not measure transcript age -- refusing to guess"; return 1 ;;
        *) log "  busy: $TRANSCRIPT_WITNESS (settle window ${AGENT_IDLE_SETTLE_SECS}s)"; return 1 ;;
    esac

    _rc=0; activity_quiet || _rc=$?
    case "$_rc" in
        0) log "  idle: $ACTIVITY_WITNESS"; return 0 ;;
        *) log "  busy: $ACTIVITY_WITNESS"; return 1 ;;
    esac
}

# --- fetch cadence ---------------------------------------------------------
# True when the last `claude update` was long enough ago. An unreadable or
# malformed stamp means "fetch" -- the failure mode of fetching too often is a
# wasted HTTP call, of fetching too rarely is a box that never updates.
fetch_due() {
    [ -f "$FETCH_STAMP" ] || return 0
    _last=$(cat "$FETCH_STAMP" 2>/dev/null || echo 0)
    case "$_last" in '' | *[!0-9]*) return 0 ;; esac
    _now=$(date +%s)
    case "$_now" in '' | *[!0-9]*) return 0 ;; esac
    [ $(( _now - _last )) -ge "$AGENT_FETCH_MIN_SECS" ]
}

# --- guidance drift --------------------------------------------------------
# The harness check above asks the kernel which build is RUNNING. Nothing asked
# the equivalent question about GUIDANCE -- the CLAUDE.md rules and skills that
# reach a box as tracked files in the chezmoi source. A rule is in force only on
# boxes that pulled it, and until this existed no box could answer "is my
# guidance current?" without someone running git by hand.
#
# It is not the same shape as the harness check, and the asymmetry is the reason:
#   cdacos/scripts   is PUBLIC  -- the externals re-fetch over anonymous HTTPS,
#                                  which is why `chezmoi apply` alone updates them
#   cdacos/dotfiles  is PRIVATE -- tracked files need credentials, so only
#                                  `chezmoi update` (git pull) brings them in
# Verified 2026-08-27: raw.githubusercontent.com returns 200 for the first and
# 404 anonymous for the second.
#
# FAST-FORWARD ONLY, and only into a clone nobody is working in. This used to
# report and never act, because `chezmoi update` runs `git pull --autostash
# --rebase` -- unattended, that could rebase over someone's local edits. The
# risk was real but narrower than the rule: a fast-forward rewrites nothing, and
# agents do edit this clone with plain git (branches, commits for a dotfiles PR).
# Report-only cost what it was meant to prevent the other way round: dotfiles#8
# merged on 2026-11-20 and three days later was in force on one box of six, the
# one whose agent had pulled by hand, while every other box's daily check logged
# "1 commit(s) behind" to a journal nobody reads.
#
# So with AGENT_UPDATE_MODE=auto it now does what `chezmoi update` does, minus
# the rebase, when -- and only when -- guidance_pullable() finds the clone on
# main, with no uncommitted or untracked files, strictly behind origin/main, and
# no target edited by hand since chezmoi last wrote it. Anything else is left
# exactly as found and reported, as before. Two consequences worth knowing:
#   - `chezmoi apply` refreshes every external that is due, and the fleet's
#     scripts mostly use refreshPeriod "1s", so a guidance update also brings
#     this box's scripts to cdacos/scripts main -- as a hand `chezmoi update`
#     does.
#   - It runs before daemon_drift() and the harness restart in main(), so a
#     script it replaces gets its daemon restarted, and a restarted agent starts
#     on the new rules, in the same tick. That includes this script: chezmoi
#     replaces files by rename, so the shell running it keeps the old inode.
#
# WHY THE FETCH IS NOT OPTIONAL, and this is the whole design. Comparing HEAD to
# the CACHED origin/main is nearly free and needs no credentials -- but on a box
# whose cached ref is itself stale it does not fail silent, it fails CONFIDENT.
# Measured on tweety 2026-08-27: HEAD ef27efa, cached origin/main 61ddf06,
# `rev-list HEAD...origin/main` = "1 behind" -- while the commit actually being
# waited on (5c44985) was not an object in that repo at all (`git cat-file -t` ->
# not a valid object name). A precise wrong number is worse than no number; it is
# the same defect as the idle gate that used to name a cause it never measured.
# So when the fetch does not happen, the count is reported WITH the age of the
# ref it was computed against, and the number carries its own expiry date.
# (Design and the measurement behind it: Tweety-8.)
guidance_drift() {
    _src=$AGENT_GUIDANCE_SOURCE
    # Absent entirely is the ordinary case -- plenty of boxes have no chezmoi --
    # so that stays silent. Present but not a repo is NOT ordinary and must say
    # so: during development this branch swallowed a wrong AGENT_GUIDANCE_SOURCE
    # three test runs in a row, which is precisely the silent-negative this file
    # spends the rest of its length arguing against.
    [ -e "$_src" ] || return 0
    if [ ! -d "$_src/.git" ]; then
        log "guidance: $_src exists but is not a git repository -- cannot check"
        return 0
    fi

    _fresh=no
    if [ "$AGENT_GUIDANCE_FETCH" = 1 ]; then
        # Through in_agent_env for the same reason `claude update` is: the timer's
        # own environment has neither PATH nor the SSH agent. Bounded, because a
        # fetch that hangs inside the tick is a worse bug than the drift it
        # is looking for.
        if in_agent_env timeout "$AGENT_GUIDANCE_TIMEOUT" \
               git -C "$_src" fetch --quiet origin 2>/dev/null; then
            _fresh=yes
        else
            log "guidance: fetch failed or timed out after ${AGENT_GUIDANCE_TIMEOUT}s"
        fi
    fi

    _head=$(git -C "$_src" rev-parse --short HEAD 2>/dev/null || true)
    _remote=$(git -C "$_src" rev-parse --short origin/main 2>/dev/null || true)
    if [ -z "$_head" ] || [ -z "$_remote" ]; then
        log "guidance: cannot resolve HEAD or origin/main in $_src -- refusing to guess"
        return 0
    fi

    _behind=$(git -C "$_src" rev-list --count HEAD..origin/main 2>/dev/null || true)
    case "$_behind" in '' | *[!0-9]*) log "guidance: cannot count revisions -- refusing to guess"; return 0 ;; esac

    # A failed apply on an earlier tick leaves the source ahead of what is in
    # force, and from then on HEAD == origin/main reads as "current" -- the
    # false-healthy this file exists to refuse. The marker keeps it a retry.
    _pending=''
    if [ -f "$GUIDANCE_UNAPPLIED" ]; then
        _pending=$(cat "$GUIDANCE_UNAPPLIED" 2>/dev/null) || _pending=''
        _pending=${_pending:-unknown}
    fi

    # A current source is not a current box. The scripts are chezmoi externals,
    # fetched from their own repo, so a scripts-only change never moves this
    # clone: stopping here left every box on the old agent-bus-cli.sh until the
    # next dotfiles commit (2026-11-27, cfd8d0f9238c on all six peers). `chezmoi
    # status` refreshes externals past their refreshPeriod, and a stale one
    # shows in the second column (what apply would do). Any second-column entry
    # counts, hand-edited ones ("MM") included: guidance_pullable then names the
    # edit and refuses, where filtering it out here would read "current".
    _stale=''
    if [ "$_behind" -eq 0 ] && [ -z "$_pending" ]; then
        _rc=0
        _st=$(in_agent_env timeout "$AGENT_GUIDANCE_APPLY_TIMEOUT" \
            chezmoi status --no-tty </dev/null 2>/dev/null) || _rc=$?
        if [ "$_rc" -ne 0 ]; then
            log "guidance: source current ($_head), but chezmoi status failed (exit $_rc) -- cannot tell whether externals are stale"
            return 0
        fi
        _stale=$(printf '%s\n' "$_st" | grep '^.[^ ]' | cut -c4- | head -n 5 | tr '\n' ' ')
        _stale=${_stale% }
        if [ -z "$_stale" ]; then
            [ "$_fresh" = yes ] && log "guidance: current ($_head)"
            return 0
        fi
    fi

    # Never report a bare count against a ref we did not just refresh.
    if [ -n "$_stale" ]; then
        _gap="source is current ($_head) but target(s) are stale: $_stale"
    elif [ "$_behind" -eq 0 ]; then
        _gap="source is current ($_head) but NOT applied -- chezmoi apply of $_pending failed on an earlier tick"
    elif [ "$_fresh" = yes ]; then
        _gap="$_behind commit(s) behind -- HEAD $_head, origin/main $_remote"
    else
        _witness="ref age unknown"
        if [ -f "$_src/.git/FETCH_HEAD" ]; then
            _mt=$(date -r "$_src/.git/FETCH_HEAD" +%s 2>/dev/null || echo '')
            case "$_mt" in
                '' | *[!0-9]*) ;;
                *) _witness="last fetched $(( ( $(date +%s) - _mt ) / 3600 ))h ago" ;;
            esac
        fi
        _gap="at least $_behind commit(s) behind -- HEAD $_head vs CACHED origin/main $_remote ($_witness). The real gap may be larger; this count is against a ref that was not refreshed"
    fi

    if [ "$AGENT_UPDATE_MODE" != auto ]; then
        log "guidance: $_gap. AGENT_UPDATE_MODE=$AGENT_UPDATE_MODE, reporting only. Run: chezmoi update"
        return 0
    fi
    if ! guidance_pullable "$_src"; then
        log "guidance: $_gap. Not updating: $GUIDANCE_BLOCKER. Run by hand once that is resolved: chezmoi update"
        return 0
    fi

    # A stale cached ref is still safe to move to: HEAD is its ancestor, so this
    # only ever goes forward. The log line above says how stale it may be.
    if [ "$_behind" -gt 0 ] &&
        ! git -C "$_src" merge --ff-only --quiet origin/main >/dev/null 2>&1; then
        log "guidance: $_gap. Fast-forward FAILED -- source left at $_head. Run: chezmoi update"
        return 0
    fi

    # </dev/null and --no-tty: a prompt must fail the apply, never wait on a tty
    # that is not there. guidance_pullable() has already ruled out the one prompt
    # an ordinary apply raises (a target edited by hand).
    _rc=0
    _out=$(in_agent_env timeout "$AGENT_GUIDANCE_APPLY_TIMEOUT" \
        chezmoi apply --no-tty </dev/null 2>&1) || _rc=$?
    [ -n "$_out" ] && printf '%s\n' "$_out" | sed 's/^/agent-update:   /' >&2
    if [ "$_rc" -ne 0 ]; then
        # The false-healthy to avoid: guidance= in the heartbeat now reads the new
        # commit while applied= still hashes the old CLAUDE.md. Say so plainly,
        # and leave the marker so the next tick retries instead of reading
        # "current".
        printf '%s\n' "$_remote" >"$GUIDANCE_UNAPPLIED" 2>/dev/null || true
        log "guidance: source is at $_remote (was $_head), but chezmoi apply FAILED (exit $_rc) -- the new guidance is NOT in force; the next tick retries. Run: chezmoi apply"
        return 0
    fi
    rm -f "$GUIDANCE_UNAPPLIED"
    # Units may be among what was just written; main() reloaded before this ran.
    systemctl --user daemon-reload 2>/dev/null || true
    if [ -n "$_stale" ]; then
        log "guidance: source current ($_head); applied stale target(s): $_stale; sessions pick it up at their next start or /clear"
    elif [ "$_behind" -eq 0 ]; then
        log "guidance: applied $_head (retry of a failed apply); sessions pick it up at their next start or /clear"
    else
        log "guidance: updated $_head -> $_remote and applied ($_behind commit(s)); sessions pick it up at their next start or /clear"
    fi
}

# Is the chezmoi source safe to fast-forward and apply unattended? 0 = yes;
# 1 = no, with the reason in GUIDANCE_BLOCKER. Called directly, never in $(...),
# so the global reaches the caller. Each check guards a way someone's work could
# be in the clone or on the box:
#   not on main          -- a branch being worked on, or a rebase in progress
#   uncommitted/untracked -- an edit in progress; untracked too, because chezmoi
#                           would APPLY a half-written new source file
#   HEAD not an ancestor -- local commits not on origin/main (an unpushed edit,
#                           or chezmoi's autoCommit without the push)
#   target edited by hand -- a local patch under test, e.g. a script in
#                           ~/.local/bin; apply would overwrite it, or prompt
# The window between these checks and the merge is milliseconds at 04:00; the
# merge itself still refuses to overwrite anything git can see.
guidance_pullable() {
    _src=$1
    GUIDANCE_BLOCKER=''

    _branch=$(git -C "$_src" symbolic-ref --short -q HEAD 2>/dev/null) || _branch=''
    if [ "$_branch" != main ]; then
        GUIDANCE_BLOCKER="source is on '${_branch:-a detached HEAD}', not main"
        return 1
    fi

    if ! _dirty=$(git -C "$_src" status --porcelain 2>/dev/null); then
        GUIDANCE_BLOCKER="git status failed in $_src -- refusing to guess"
        return 1
    fi
    if [ -n "$_dirty" ]; then
        GUIDANCE_BLOCKER="source has uncommitted or untracked files ($(printf '%s\n' "$_dirty" | wc -l) path(s))"
        return 1
    fi

    _rc=0
    git -C "$_src" merge-base --is-ancestor HEAD origin/main 2>/dev/null || _rc=$?
    case "$_rc" in
        0) ;;
        1) GUIDANCE_BLOCKER="local main has commits origin/main does not"; return 1 ;;
        *) GUIDANCE_BLOCKER="cannot compare HEAD with origin/main -- refusing to guess"; return 1 ;;
    esac

    # First column of `chezmoi status`: has the target changed since chezmoi
    # last wrote it? Second column is what apply would do, which is expected.
    _rc=0
    _st=$(in_agent_env timeout "$AGENT_GUIDANCE_APPLY_TIMEOUT" \
        chezmoi status --no-tty </dev/null 2>/dev/null) || _rc=$?
    if [ "$_rc" -ne 0 ]; then
        GUIDANCE_BLOCKER="chezmoi status failed (exit $_rc) -- refusing to guess"
        return 1
    fi
    _rc=0
    printf '%s\n' "$_st" | grep -q '^[^ ]' || _rc=$?
    case "$_rc" in
        0)
            _edited=$(printf '%s\n' "$_st" | grep '^[^ ]' | cut -c4- | head -n 5 | tr '\n' ' ')
            GUIDANCE_BLOCKER="target(s) edited by hand since chezmoi last wrote them: ${_edited% }"
            return 1 ;;
        1) return 0 ;;
        *) GUIDANCE_BLOCKER="cannot read chezmoi status -- refusing to guess"; return 1 ;;
    esac
}

# --- daemon drift ----------------------------------------------------------
#
# The harness is not the only thing on a box that runs from a file and then keeps
# its inode. agent-fsd.service executes ~/.local/bin/agent-bus-fsd.sh; chezmoi
# replaces that file by rename, so the running daemon holds the old file
# descriptor and serves the old code indefinitely. Nothing restarted it.
#
# Measured 2026-09-04, and this is why the check exists: the fsd git panel
# (fs.git/fs.gitdiff, FSD_VERSION 3) reached origin/main on 2026-09-03, and 15h
# later two of the three live boxes still answered fs.ping with version 2 and no
# "git" in their ops, so the web UI correctly hid the feature on both. The one
# box serving it was the one where the author had restarted the unit by hand --
# which was also the box the feature was declared "live" from. A capability can
# be absent fleet-wide while every daemon answers happily at the old version;
# nothing about the old daemon looks broken, so nothing surfaces it.
#
# Staleness is ASKED, not tracked: is the script on disk newer than the process
# executing it? /proc/<pid> carries the process start time as its own mtime
# (checked against `ps -o lstart=`, and stable across reads), so `test -nt`
# answers it directly -- no state file to persist, nothing to fall out of step,
# and a restart done by hand updates the answer for free. That last property is
# not incidental: hand restarts are how the first boxes get fixed, and a marker
# file would have re-restarted every one of them.
#
# The comparison is at one-second grain, because that is procfs's grain. An apply
# landing in the same second as a restart can therefore read as "not newer"; the
# process is then running the new code anyway in every ordering except a write
# that lands microseconds after the exec, which the next apply corrects.
#
# Units are declared as unit:script pairs so the next daemon costs no new code.
# agent-claude.service is deliberately absent: harness drift has its own
# comparison and its own idle gate below, and two mechanisms restarting one unit
# on different criteria would fight each other.
daemon_drift() {
    for _pair in $AGENT_MANAGED_UNITS; do
        _unit=${_pair%%:*}
        _script=${_pair#*:}
        if [ -z "$_unit" ] || [ -z "$_script" ] || [ "$_script" = "$_pair" ]; then
            log "daemon: '$_pair' is not a unit:script pair -- skipping"
            continue
        fi

        # Not installed is the ordinary case -- plenty of boxes run no daemon --
        # so it stays silent, the same way an absent chezmoi source does.
        _load=$(systemctl --user show "$_unit" -p LoadState --value 2>/dev/null || true)
        [ "$_load" = loaded ] || continue

        _active=$(systemctl --user show "$_unit" -p ActiveState --value 2>/dev/null || true)
        if [ "$_active" != active ]; then
            log "daemon: $_unit is $_active, not active -- leaving it alone"
            continue
        fi

        # Loaded and running but its script is gone is NOT ordinary: it means the
        # unit and this list disagree about where the code lives, and a silent
        # skip there would look exactly like a box that is up to date.
        if [ ! -f "$_script" ]; then
            log "daemon: $_unit is active but $_script does not exist -- cannot compare"
            continue
        fi

        _pid=$(systemctl --user show "$_unit" -p MainPID --value 2>/dev/null || true)
        case "$_pid" in
            '' | 0 | *[!0-9]*)
                log "daemon: $_unit is active but MainPID is '$_pid' -- refusing to guess"
                continue ;;
        esac
        if [ ! -d "/proc/$_pid" ]; then
            log "daemon: $_unit MainPID $_pid has no /proc entry -- refusing to guess"
            continue
        fi

        [ "$_script" -nt "/proc/$_pid" ] || continue

        if [ "$AGENT_UPDATE_MODE" != auto ]; then
            log "daemon: $_unit runs code older than $_script -- AGENT_UPDATE_MODE=$AGENT_UPDATE_MODE, reporting only"
            continue
        fi

        # No idle gate here, unlike the harness. agent-fsd.service is split from
        # agent-claude.service precisely so it "can be restarted after a config
        # change without disturbing a working session" (its own comment): it
        # holds no conversation and no context, and an in-flight fs request is
        # reissued by the caller. The cost of restarting is one dropped request;
        # the cost of not restarting is a capability the fleet silently lacks.
        log "daemon: $_unit is running code older than $_script -- restarting"
        systemctl --user restart "$_unit" || log "daemon: restart of $_unit FAILED"
    done
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

# --- restart ---------------------------------------------------------------
# Restart onto the installed build at the first idle check, retrying every
# AGENT_IDLE_RETRY_SECS; past AGENT_IDLE_WAIT_SECS, restart regardless.
#
# The bound replaces a ceiling that used to be counted in ticks across days
# (AGENT_DEFER_MAX_HOURS, 48h). With one tick a day that ceiling would have
# meant two or three nights stale, and its integer-hour arithmetic against a
# jittered tick could slip it by a further day. Inside the run the cost of a
# false "busy" is one retry, and the restart still happens in the 04:00 window
# rather than whenever a later tick happens to look idle. A forced restart is
# survivable for the reason given at the top of this file: the agent resumes,
# and the bus re-delivers un-acked mail.
#
# Between checks the agent may have been restarted by someone else -- by hand,
# or by systemd after a crash, both of which start the installed build. That is
# re-checked after every pause, so this never restarts an agent already current.
restart_when_idle() {
    _pid=$1
    _installed_path=$2
    _deadline=$(( $(date +%s) + AGENT_IDLE_WAIT_SECS ))
    while :; do
        if is_idle "$_pid"; then
            log "idle -- restarting agent-claude.service onto $(basename "$_installed_path")"
            systemctl --user restart agent-claude.service
            return 0
        fi
        if [ "$(date +%s)" -ge "$_deadline" ]; then
            log "still busy after ${AGENT_IDLE_WAIT_SECS}s -- restarting onto $(basename "$_installed_path") regardless"
            systemctl --user restart agent-claude.service
            return 0
        fi
        log "busy -- re-checking in ${AGENT_IDLE_RETRY_SECS}s"
        sleep "$AGENT_IDLE_RETRY_SECS"

        _pid=$(pgrep -u "$(id -u)" -x claude 2>/dev/null | head -n 1 || true)
        if [ -z "$_pid" ]; then
            log "claude exited while waiting -- nothing to restart"
            return 0
        fi
        if [ "$(readlink -f "/proc/$_pid/exe" 2>/dev/null || true)" = "$_installed_path" ]; then
            log "agent is already on $(basename "$_installed_path") (PID $_pid) -- no restart needed"
            return 0
        fi
    done
}

# --- main ------------------------------------------------------------------
main() {
    # Units may have been refreshed on disk by chezmoi since the last run;
    # nothing else reloads them.
    systemctl --user daemon-reload 2>/dev/null || true

    # The fetch keeps its own stamp, from when the tick was hourly. `claude
    # update` is a network call against an upstream the whole fleet shares, and
    # nothing about checking for drift requires re-fetching first -- the drift
    # being checked is between the running process and what is ALREADY on disk.
    # With a daily tick the stamp is always due; it still stops a hand-run
    # check from re-fetching.
    if [ "$AGENT_UPDATE_MODE" = auto ] && fetch_due; then
        in_agent_env claude update 2>&1 | sed 's/^/agent-update:   /' >&2 ||
            log "claude update failed; continuing with what is on disk"
        date +%s > "$FETCH_STAMP"
    fi

    # Guidance first: bringing it current runs `chezmoi apply`, which can replace
    # a daemon's script (so daemon_drift must come after, to restart onto it in
    # this tick) and the rules a restarted agent starts on. Before the harness
    # lookup too, because whether an agent is running has no bearing on whether
    # the box's guidance is current -- and a box with claude stopped used to skip
    # this check entirely. Also deliberately before the up-to-date return below:
    # a box can be on the current build and still be running week-old rules.
    guidance_drift

    # Before the harness lookup, and deliberately so: a daemon's staleness has
    # nothing to do with whether an agent happens to be running on this box, and
    # the early return below would otherwise skip the check entirely on any box
    # whose claude is stopped -- which is exactly when a restart is safest.
    daemon_drift

    pid=$(pgrep -u "$(id -u)" -x claude 2>/dev/null | head -n 1 || true)
    if [ -z "$pid" ]; then
        log "no running claude -- nothing to compare or restart"
        return 0
    fi

    # Compare fully resolved paths, not basenames. A native install resolves both
    # sides to versions/<v>; a packaged one (/usr/bin/claude, no versions/ dir)
    # resolves to neither. Basenames there would read "claude" vs "claude" or
    # "claude" vs "unknown" -- either a missed update or, worse, permanent phantom
    # drift restarting the agent every day forever.
    #
    # This guard is written against the SHAPE of a packaged install, deliberately
    # and not against any particular box. It used to cite tweety as the live
    # counterexample; tweety has since been migrated and is native as of
    # 2026-08-27 (reported by Tweety-8: ~/.local/bin/claude -> versions/2.1.247).
    # The citation is removed rather than updated, because a rationale that rests
    # on one named machine reads as obsolete the moment that machine changes, and
    # invites someone to simplify this back to basenames on the grounds that the
    # case is now hypothetical. It is not: any non-native install reintroduces it,
    # and the failure mode is a daily restart loop that looks like a working
    # updater. (Flagged by Tweety-8, who noticed its own box had falsified it.)
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
        return 0
    fi

    log "harness drift: PID $pid runs $running_path, installed is $installed_path"

    if [ "$AGENT_UPDATE_MODE" != auto ]; then
        log "AGENT_UPDATE_MODE=$AGENT_UPDATE_MODE -- reporting only, leaving the agent alone"
        return 0
    fi

    restart_when_idle "$pid" "$installed_path"
}

# One check at a time: a hand run of this script while a tick is still waiting
# for idle must not race it to the restart.
exec 9>"$LOCK"
flock -n 9 || { log "another check is already running"; exit 0; }
main
