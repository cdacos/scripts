#!/bin/sh
# agent-bus-monitor-guard.sh - Claude Code Stop-hook guard for agent-bus monitor
# agents. It refuses to let a bus session go idle unless an
# `agent-bus-cli.sh wake` background task is running, keeping the real-time
# inbox channel armed. Reads the hook JSON on stdin. Self-contained (no deps
# on other files in this repo); install it on PATH beside agent-bus-cli.sh.
#
# Self-gating: exits silently unless AGENT_BUS_TOKEN is set (presence of a bus
# identity) so it only guards sessions actually on the bus -- fleet agents
# always carry the token; the host user's ordinary dev sessions do not. This
# keeps ~/.claude/settings.json a dumb dispatcher (`agent-bus-monitor-guard.sh`
# bare), same pattern as `agent-bus-cli.sh onboard`.

# Off the bus -> no monitor to guard; allow the stop.
[ -n "${AGENT_BUS_TOKEN:-}" ] || exit 0

input=$(cat 2>/dev/null)

# If we already blocked once this turn, relent -- Claude Code caps consecutive
# Stop-hook blocks, and we never want to trap the agent.
case "$input" in
    *'"stop_hook_active":true'* | *'"stop_hook_active": true'*) exit 0 ;;
esac

# supervisor_pid -> the `claude` session that owns this hook invocation. Walk
# the ancestry to the first `claude` rather than guessing a hop count: the
# harness wraps each hook in a shell, so a fixed guess keys on a wrapper that
# dies every call. Mirrors agent-bus-cli.sh's session_supervisor -- duplicated
# deliberately, since this script is distributed standalone.
supervisor_pid() {
    _sv=$PPID
    _hops=0
    while [ "$_hops" -lt 10 ]; do
        case "$_sv" in '' | 0 | 1 | *[!0-9]*) break ;; esac
        case $(ps -o comm= -p "$_sv" 2>/dev/null) in
            claude | */claude)
                printf '%s\n' "$_sv"
                return 0
                ;;
        esac
        _sv=$(ps -o ppid= -p "$_sv" 2>/dev/null | tr -d ' ')
        _hops=$((_hops + 1))
    done
    _sv=$(ps -o ppid= -p "$PPID" 2>/dev/null | tr -d ' ')
    case "$_sv" in '' | 0 | 1 | *[!0-9]*) return 0 ;; esac
    printf '%s\n' "$_sv"
}

# pid_has_ancestor <pid> <ancestor> -> 0 when <ancestor> sits above <pid>.
pid_has_ancestor() {
    _anc_pid=$1
    _anc_hops=0
    while [ "$_anc_hops" -lt 20 ]; do
        case "$_anc_pid" in '' | 0 | 1 | *[!0-9]*) return 1 ;; esac
        [ "$_anc_pid" = "$2" ] && return 0
        _anc_pid=$(ps -o ppid= -p "$_anc_pid" 2>/dev/null | tr -d ' ')
        _anc_hops=$((_anc_hops + 1))
    done
    return 1
}

# is_wake_process <pid> -> 0 when <pid> really is an `agent-bus-cli.sh wake`
# invocation. A `pgrep -f` hit alone also matches any process that merely
# MENTIONS the command -- including this guard's own instruction text echoed
# back, or an agent grepping for its monitor -- and counting that as "armed" is
# how a session goes idle with nothing actually listening. argv settles it: an
# invocation carries the script path and the bare word `wake` as SEPARATE
# elements, where a mention is one long single element that is neither.
is_wake_process() {
    if [ -r "/proc/$1/cmdline" ]; then
        _wk_script=0
        _wk_wake=0
        while IFS= read -r _wk_arg; do
            case "$_wk_arg" in *agent-bus-cli.sh) _wk_script=1 ;; esac
            [ "$_wk_arg" = wake ] && _wk_wake=1
        done <<EOF
$(tr '\0' '\n' <"/proc/$1/cmdline" 2>/dev/null)
EOF
        [ "$_wk_script" -eq 1 ] && [ "$_wk_wake" -eq 1 ]
        return $?
    fi
    case $(ps -o args= -p "$1" 2>/dev/null) in
        *agent-bus-cli.sh\ wake) return 0 ;;
        *agent-bus-cli.sh\ wake\ [0-9]* | *agent-bus-cli.sh\ wake\ --ack*) return 0 ;;
    esac
    return 1
}

# A monitor counts only if THIS session armed it. A bare name match is satisfied
# by any wake on the box -- another agent's session, or one orphaned by a
# `/clear` -- so an unarmed session could go idle believing someone else's
# monitor was its own, which is precisely the mail it would then never wake on.
monitor_armed() {
    _sup=$(supervisor_pid)
    for _p in $(pgrep -f 'agent-bus-cli\.sh wake' 2>/dev/null); do
        is_wake_process "$_p" || continue
        # No supervisor to scope by (manual or nohup use): police nothing and
        # accept any monitor, which is what this guard has always done.
        [ -n "$_sup" ] || return 0
        pid_has_ancestor "$_p" "$_sup" && return 0
    done
    return 1
}

# Monitor already armed -> fine to stop.
if monitor_armed; then
    exit 0
fi

# Not armed -> block the stop and tell the agent how to re-arm. Emit the
# instruction on BOTH channels (reason + hookSpecificOutput.additionalContext):
# sources disagree on which one a command-type Stop hook feeds to the model, and
# carrying both is correct either way and harmless if one is ignored.
#
# Bare `wake`, never `--ack`: this message is where an agent that has lost the
# thread learns the discipline, so it must not teach the lossy path. --ack
# drains on delivery, which destroys a DM outright if the session dies before
# handling it; the delivery cursor means an un-acked message no longer spins the
# re-armed poll, so there is nothing left to trade for that risk.
printf '%s' '{"decision":"block","reason":"No agent-bus monitor is armed. Run: agent-bus-cli.sh wake (as a background task), then you may stop. Do not pass --ack -- ack with ack-all once you have handled a message, never on delivery.","hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"No agent-bus monitor is armed. Run agent-bus-cli.sh wake as a background task, then re-arm before stopping. Do not pass --ack: it drains on delivery, so a session that dies mid-handle destroys the DM. Ack means handled -- run ack-all after you have acted."}}'
exit 0
