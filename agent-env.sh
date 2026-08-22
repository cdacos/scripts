# agent-env.sh - give a systemd-supervised process the agent's shell environment.
# SOURCE this file; do not execute it.
#
# systemd starts processes with a clean environment, and the three obvious ways
# to restore it all fail:
#
#   EnvironmentFile=~/.carlos_secrets   systemd silently drops `export K=v` lines
#                                       -- it logs "Ignoring invalid environment
#                                       assignment" and the variable is unset.
#   bash -lc '...'                      ~/.bashrc returns early when not
#                                       interactive, so a login shell sources
#                                       none of the agent's environment. Verified
#                                       with `env -i`: AGENT_BUS_TOKEN unset,
#                                       ~/.local/bin missing from PATH, exit 127.
#   bash -lic '...'                     works, but emits "cannot set terminal
#                                       process group" / "no job control" on every
#                                       start plus the daily check-tools banner.
#
# So: keep the login shell for the system profile, then source the one file
# ~/.bashrc delegates to. One source of truth, and no second copy of the bus
# token or the GitHub PAT on disk.
#
# Override with AGENT_ENV_FILE if a box lays its dotfiles out differently.
#
# Sourcing common.sh also fires its once-a-day check-tools banner and claims that
# day's stamp, so a human logging in later that day will not see it. Cosmetic,
# but real; noted here rather than worked around.

AGENT_ENV_FILE="${AGENT_ENV_FILE:-$HOME/.config/shell/common.sh}"
if [ -r "$AGENT_ENV_FILE" ]; then
    # Output to stderr: it belongs in the journal, never in the supervised
    # process's stdout (claude's is a TUI).
    { . "$AGENT_ENV_FILE"; } >&2 || echo "agent-env: $AGENT_ENV_FILE failed to load" >&2
else
    echo "agent-env: no $AGENT_ENV_FILE -- falling back to PATH only" >&2
fi

case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH="$HOME/.local/bin:$PATH"; export PATH ;;
esac
