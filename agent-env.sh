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
# Override with AGENT_ENV_FILE if a box lays its dotfiles out differently.

AGENT_ENV_FILE="${AGENT_ENV_FILE:-$HOME/.config/shell/common.sh}"

# This file used to borrow ~/.cache/daily_check_stamp under a lock and a trap,
# because sourcing common.sh non-interactively claimed the human's daily
# tool-and-drift check and reported it to nobody. That is now fixed at source --
# common.sh runs the check in interactive shells only (cdacos/dotfiles ef27efa) --
# so there is nothing left to protect and roughly thirty lines of machinery are
# gone. Found, and then fixed better than I had, by Tweety on 2026-08-22.

# Detection, not prevention. agent-supervision-install.sh refuses to install
# against an unguarded common.sh, but that is a point-in-time assertion about a
# file that keeps moving: every later `chezmoi apply` rewrites it from the clone,
# and the units then run for months without anyone re-checking. If the guard is
# ever reverted, rolled back or hand-edited away, the stamp theft resumes and
# nothing reports it -- the same invisibility this whole class of bug lives in.
# This neither prevents the start nor restores the old machinery; it just means
# the day the residual stops being empty, the journal says so. (Tweety's idea.)
if grep -q '_daily_check' "$AGENT_ENV_FILE" 2>/dev/null &&
   ! grep -qE 'case .*_daily_check' "$AGENT_ENV_FILE" 2>/dev/null; then
    echo "agent-env: WARNING $AGENT_ENV_FILE calls _daily_check unconditionally; this start will consume the daily tool-and-drift check and report it to nobody. Fix with 'chezmoi update' (not plain 'chezmoi apply')." >&2
fi

if [ -r "$AGENT_ENV_FILE" ]; then
    # Output to stderr: it belongs in the journal, never in the supervised
    # process's stdout (claude's is a TUI). Kept even though common.sh is now
    # quiet -- it is one redirect, and nothing guarantees the next line added to
    # that file will be.
    { . "$AGENT_ENV_FILE"; } >&2 || echo "agent-env: $AGENT_ENV_FILE failed to load" >&2
else
    echo "agent-env: no $AGENT_ENV_FILE -- falling back to PATH only" >&2
fi

case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH="$HOME/.local/bin:$PATH"; export PATH ;;
esac
