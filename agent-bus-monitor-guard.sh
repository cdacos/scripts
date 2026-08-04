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

# Monitor already armed -> fine to stop.
if pgrep -f 'agent-bus-cli.sh wake' >/dev/null 2>&1; then
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
