#!/bin/sh
# agent-bus-monitor-guard.sh - Claude Code Stop-hook guard for agent-bus monitor
# agents. Wired from ~/.claude/settings.json's Stop hook, which gates it on
# AGENT_BUS_TOKEN (presence of a bus identity) so it only runs for sessions that
# are actually on the bus -- fleet agents always carry the token; the host
# user's ordinary dev sessions do not. It refuses to let such a session go idle
# unless an
# `agent-bus-cli.sh wake` background task is running, keeping the real-time
# inbox channel armed. Reads the hook JSON on stdin. Self-contained (no deps
# on other files in this repo); install it on PATH beside agent-bus-cli.sh.

input=$(cat 2>/dev/null)

# If we already blocked once this turn, relent -- Claude Code caps consecutive
# Stop-hook blocks, and we never want to trap the agent.
case "$input" in
    *'"stop_hook_active":true'* | *'"stop_hook_active": true'*) exit 0 ;;
esac

# Monitor already armed -> fine to stop.
if pgrep -f 'agent-bus-cli.sh wake' >/dev/null 2>&1; then
    exit 0
fi

# Not armed -> block the stop and tell the agent how to re-arm. Emit the
# instruction on BOTH channels (reason + hookSpecificOutput.additionalContext):
# sources disagree on which one a command-type Stop hook feeds to the model, and
# carrying both is correct either way and harmless if one is ignored.
printf '%s' '{"decision":"block","reason":"No agent-bus monitor is armed. Run: agent-bus-cli.sh wake --ack (as a background task), then you may stop.","hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"No agent-bus monitor is armed. Run agent-bus-cli.sh wake --ack as a background task, then re-arm before stopping."}}'
exit 0
