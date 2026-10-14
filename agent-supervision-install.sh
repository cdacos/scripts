#!/bin/sh
# agent-supervision-install.sh - put this box's agent under systemd.
#
#   install   (default) linger + enable the units; starts the file daemon but
#             deliberately does NOT start the agent -- see cutover.
#   cutover   hand a hand-started (tmux) agent over to systemd. Kills the running
#             claude, starts agent.target, waits for the new session, and only
#             then retires the old tmux server. Detached, because it outlives the
#             agent that launched it.
#   up        bring the agent back after a reboot or a crash: linger, reset any
#             failed unit, start agent.target, then check the session's screen
#             for the prompts that block it invisibly (expired login, folder
#             trust). Safe to re-run; never restarts a running agent.
#   status    what is running, what version, and whether it has drifted.
#
# The units and scripts themselves arrive via chezmoi externals; this only does
# the parts chezmoi cannot (linger, daemon-reload, enable, the handover).
set -eu

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent"
LOG="$STATE_DIR/cutover.log"
UNITS="agent.target agent-claude.service agent-fsd.service agent-update.timer"

log() { echo "$(date -Is) $*"; }
die() { echo "install: $*" >&2; exit 1; }

# The claude processes that are agents. `claude update` has the same name but is
# the updater: it must never be the holder that makes `up` refuse, nor a target
# of cutover's kill.
agent_pids() {
    for _p in $(pgrep -u "$(id -u)" -x claude 2>/dev/null || true); do
        [ "$(tr '\0' '\n' <"/proc/$_p/cmdline" 2>/dev/null | sed -n 2p)" = update ] || echo "$_p"
    done
}

any_alive() {
    for _p in "$@"; do kill -0 "$_p" 2>/dev/null && return 0; done
    return 1
}

# `install` starts agent-update.timer. On a box up longer than OnBootSec that
# timer is already overdue, so it fires at once: `claude update`, then a drift
# check that may restart agent-claude.service. An `up` straight afterwards took
# the updater for an agent and refused (porky, 2026-10-14); a cutover would have
# killed it mid-install. So both wait for it, bounded: the unit's own limit is
# TimeoutStartSec=15min, and a hung fetch should not hold either step that long.
UPDATE_WAIT_SECS=300
wait_for_update_check() {
    _n=0
    while :; do
        _state=$(systemctl --user is-active agent-update.service 2>/dev/null) || true
        case "$_state" in activating | active | deactivating | reloading) ;; *) return 0 ;; esac
        [ "$_n" -lt "$UPDATE_WAIT_SECS" ] || return 1
        [ "$_n" -gt 0 ] || log "waiting for agent-update.service ($_state) to finish, up to ${UPDATE_WAIT_SECS}s"
        sleep 5
        _n=$((_n + 5))
    done
}

# A --user unit dies at logout and never starts at boot without this.
ensure_linger() {
    if [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" != yes ]; then
        log "enabling linger for $(id -un)"
        sudo -n loginctl enable-linger "$(id -un)" 2>/dev/null ||
            loginctl enable-linger "$(id -un)" ||
            die "could not enable linger; a --user unit will not survive logout"
    fi
}

cmd_install() {
    for t in script tmux jq flock systemctl loginctl pgrep; do
        command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"
    done
    [ -x "$HOME/.local/bin/agent-run.sh" ] || die "agent-run.sh not on ~/.local/bin -- run chezmoi apply first"
    [ -f "$HOME/.config/systemd/user/agent-claude.service" ] || die "units not installed -- run chezmoi apply first"

    # The units are the only thing that ever executes agent-env.sh, so this is the
    # one moment where a stale common.sh matters. The agent-env.sh external entry
    # was added to the shared dotfiles (b73f749) THIRTEEN MINUTES before the guard
    # that makes it safe (ef27efa), so a box that pulled in between -- or that
    # applies without pulling -- holds the external while its common.sh still runs
    # the daily check unconditionally. Such a box silently eats the human's daily
    # tool-and-drift report and shows nothing anywhere a person would look.
    # `chezmoi apply` does not pull; `chezmoi update` does. Check, do not assume.
    envfile="${AGENT_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/shell/common.sh}"
    if [ -r "$envfile" ] && grep -q '_daily_check' "$envfile" &&
       ! grep -qE 'case .*_daily_check' "$envfile"; then
        die "$envfile calls _daily_check unconditionally. Run 'chezmoi update' (pull AND apply -- plain 'chezmoi apply' will not do it) before installing, or this box will silently consume the daily tool-and-drift check."
    fi

    ensure_linger
    systemctl --user daemon-reload
    # shellcheck disable=SC2086
    systemctl --user enable $UNITS
    systemctl --user start agent-update.timer

    # The file daemon has no session to disturb, so it can migrate immediately.
    if ! systemctl --user is-active --quiet agent-fsd.service; then
        stray=$(pgrep -u "$(id -u)" -f 'agent-bus-fsd.sh serve' 2>/dev/null || true)
        [ -n "$stray" ] && { log "retiring hand-started file daemon: $stray"; kill $stray 2>/dev/null || true; sleep 2; }
        systemctl --user start agent-fsd.service
    fi

    log "installed. The agent itself is NOT started -- run '$0 cutover' when ready."
    cmd_status
}

# Runs detached: it kills the very session that invoked it.
do_cutover() {
    mkdir -p "$STATE_DIR"
    log "cutover: starting"
    if ! wait_for_update_check; then
        log "cutover: FAILED -- agent-update.service still running after ${UPDATE_WAIT_SECS}s. Nothing was stopped; re-run cutover once it finishes."
        return 1
    fi
    old_tmux=$(pgrep -u "$(id -u)" -x tmux 2>/dev/null | head -n 1 || true)
    old_claude=$(agent_pids)

    if [ -n "$old_claude" ]; then
        # shellcheck disable=SC2086
        set -- $old_claude
        log "cutover: stopping hand-started claude: $*"
        kill "$@" 2>/dev/null || true
        n=0
        while [ "$n" -lt 30 ] && any_alive "$@"; do
            sleep 1; n=$((n + 1))
        done
        if any_alive "$@"; then
            log "cutover: claude did not exit in 30s; sending SIGKILL"
            kill -KILL "$@" 2>/dev/null || true
            sleep 2
        fi
    fi

    log "cutover: starting agent.target"
    systemctl --user start agent.target || log "cutover: WARNING agent.target start returned non-zero"

    n=0
    while [ "$n" -lt 60 ]; do
        newpid=$(agent_pids | head -n 1)
        [ -n "$newpid" ] && break
        sleep 1; n=$((n + 1))
    done

    if [ -z "${newpid:-}" ]; then
        log "cutover: FAILED -- no claude after 60s. Old tmux left alone as a fallback."
        systemctl --user status agent-claude.service --no-pager -n 20 2>&1 | sed 's/^/cutover:   /'
        return 1
    fi

    log "cutover: agent up as PID $newpid on $(basename "$(readlink "/proc/$newpid/exe" 2>/dev/null || echo unknown)")"
    # Only now is the old tmux dead weight. Until this point it was the fallback.
    if [ -n "$old_tmux" ]; then
        log "cutover: retiring orphaned tmux server PID $old_tmux (new attach point: tmux -L agent attach)"
        kill "$old_tmux" 2>/dev/null || true
    fi
    log "cutover: done"
}

cmd_cutover() {
    mkdir -p "$STATE_DIR"
    echo "cutover running detached; follow it with: tail -f $LOG"
    setsid nohup "$0" __cutover_worker >>"$LOG" 2>&1 < /dev/null &
    exit 0
}

cmd_up() {
    [ -f "$HOME/.config/systemd/user/agent-claude.service" ] ||
        die "units not installed -- run 'chezmoi update', then '$0 install'"
    ensure_linger
    systemctl --user daemon-reload
    # A unit that hit its start limit stays `failed` until reset; start alone
    # would be refused.
    # shellcheck disable=SC2086
    systemctl --user reset-failed $UNITS 2>/dev/null || true

    wait_for_update_check ||
        die "agent-update.service still running after ${UPDATE_WAIT_SECS}s -- see journalctl --user -u agent-update.service, then re-run $0 up"

    # start, not restart: a running agent is left exactly as it is. If the unit
    # is down, ANY claude on the box -- a hand-started tmux agent or a human's
    # own interactive session -- makes agent-run.sh refuse (one per VM), so the
    # start would only burn StartLimitBurst and park the unit in `failed`.
    if ! systemctl --user is-active --quiet agent-claude.service &&
        holder=$(agent_pids | head -n 1) && [ -n "$holder" ]; then
        systemctl --user start agent-fsd.service agent-update.timer
        ps -o pid=,lstart=,args= -p "$holder" | cut -c1-120 || true
        log "NOT starting the agent: claude PID $holder already owns this box."
        log "  a hand-started agent: $0 cutover. Your own session: exit it, re-run $0 up."
        cmd_status
        return 1
    fi
    systemctl --user start agent.target agent-update.timer

    n=0
    while [ "$n" -lt 60 ] && [ -z "$(agent_pids)" ]; do
        sleep 1; n=$((n + 1))
    done
    [ -n "$(agent_pids)" ] || {
        systemctl --user status agent-claude.service --no-pager -n 20 2>&1 || true
        die "no claude after 60s"
    }

    # These prompts block the opening turn while every unit reads active, so
    # only the screen shows them. Give the TUI a moment to draw first.
    sleep 10
    # Only the bottom of the screen: further up is conversation, which can
    # mention a login without being blocked by one.
    screen=$(tmux -L agent capture-pane -p -t agent 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 15 || true)
    if printf '%s\n' "$screen" | grep -qiE '/login|log ?in again|expired|trust (this|the files)|do you trust'; then
        printf '%s\n' "$screen"
        log "ACTION NEEDED: the agent looks stuck at a prompt. Check: tmux -L agent attach"
        log "  answer it (e.g. /login), then detach with Ctrl-b d"
        stuck=1
    fi
    systemctl --user is-active --quiet agent-fsd.service ||
        log "WARNING agent-fsd.service is not active: journalctl --user -u agent-fsd.service -b"
    cmd_status
    [ -z "${stuck:-}" ] || return 2
}

cmd_status() {
    echo "--- units ---"
    # shellcheck disable=SC2086
    systemctl --user list-units --no-pager --all $UNITS 2>/dev/null | head -8 || true
    echo "--- agent ---"
    pid=$(agent_pids | head -n 1)
    if [ -z "$pid" ]; then
        echo "no claude running"
    else
        running=$(basename "$(readlink "/proc/$pid/exe" 2>/dev/null || echo unknown)")
        installed=$(basename "$(readlink -f "$HOME/.local/bin/claude" 2>/dev/null || echo unknown)")
        supervised=no
        systemctl --user show agent-claude.service -p ControlGroup --value 2>/dev/null | grep -q . &&
            grep -q "agent-claude.service" "/proc/$pid/cgroup" 2>/dev/null && supervised=yes
        echo "pid $pid  running $running  installed $installed  supervised=$supervised"
        [ "$running" = "$installed" ] || echo "DRIFT: a restart would move it to $installed"
    fi
}

case "${1:-install}" in
    install) cmd_install ;;
    cutover) cmd_cutover ;;
    __cutover_worker) do_cutover ;;
    up) cmd_up ;;
    status) cmd_status ;;
    *) die "usage: $0 [install|cutover|up|status]" ;;
esac
