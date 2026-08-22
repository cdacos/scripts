#!/bin/sh
# agent-supervision-install.sh - put this box's agent under systemd.
#
#   install   (default) linger + enable the units; starts the file daemon but
#             deliberately does NOT start the agent -- see cutover.
#   cutover   hand a hand-started (tmux) agent over to systemd. Kills the running
#             claude, starts agent.target, waits for the new session, and only
#             then retires the old tmux server. Detached, because it outlives the
#             agent that launched it.
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

    # A --user unit dies at logout and never starts at boot without this.
    if [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" != yes ]; then
        log "enabling linger for $(id -un)"
        sudo -n loginctl enable-linger "$(id -un)" 2>/dev/null ||
            loginctl enable-linger "$(id -un)" ||
            die "could not enable linger; a --user unit will not survive logout"
    fi

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
    old_tmux=$(pgrep -u "$(id -u)" -x tmux 2>/dev/null | head -n 1 || true)
    old_claude=$(pgrep -u "$(id -u)" -x claude 2>/dev/null || true)

    if [ -n "$old_claude" ]; then
        log "cutover: stopping hand-started claude: $old_claude"
        # shellcheck disable=SC2086
        kill $old_claude 2>/dev/null || true
        n=0
        while [ "$n" -lt 30 ] && pgrep -u "$(id -u)" -x claude >/dev/null 2>&1; do
            sleep 1; n=$((n + 1))
        done
        if pgrep -u "$(id -u)" -x claude >/dev/null 2>&1; then
            log "cutover: claude did not exit in 30s; sending SIGKILL"
            pkill -KILL -u "$(id -u)" -x claude 2>/dev/null || true
            sleep 2
        fi
    fi

    log "cutover: starting agent.target"
    systemctl --user start agent.target || log "cutover: WARNING agent.target start returned non-zero"

    n=0
    while [ "$n" -lt 60 ]; do
        newpid=$(pgrep -u "$(id -u)" -x claude 2>/dev/null | head -n 1 || true)
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

cmd_status() {
    echo "--- units ---"
    # shellcheck disable=SC2086
    systemctl --user list-units --no-pager --all $UNITS 2>/dev/null | head -8 || true
    echo "--- agent ---"
    pid=$(pgrep -u "$(id -u)" -x claude 2>/dev/null | head -n 1 || true)
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
    status) cmd_status ;;
    *) die "usage: $0 [install|cutover|status]" ;;
esac
