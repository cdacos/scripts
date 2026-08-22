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
# Sourcing common.sh is not side-effect-free: its last line is a once-a-day
# check-tools report, stamped by day-of-year in ~/.cache/daily_check_stamp. Left
# alone, a unit starting at boot claims that day's stamp and silently robs the
# human's interactive shell of the check -- and prints a ~20-line tool table into
# the agent's terminal while doing it. Merely redirecting the output hides the
# banner but not the theft, so the stamp is pinned to today across the source
# (making _daily_check a no-op) and then restored exactly as it was. Cost: four
# lines. (Raised by Tweety, 2026-08-22, who ran it from a clean env and saw the
# banner land before the token.)

AGENT_ENV_FILE="${AGENT_ENV_FILE:-$HOME/.config/shell/common.sh}"

# Borrow the daily-check stamp, then give it back untouched.
_ae_stamp="$HOME/.cache/daily_check_stamp"
if [ -f "$_ae_stamp" ]; then
    _ae_had=1; _ae_was=$(cat "$_ae_stamp" 2>/dev/null || true)
else
    _ae_had=0; _ae_was=""
fi
mkdir -p "$HOME/.cache" 2>/dev/null || true
date +%j > "$_ae_stamp" 2>/dev/null || true

if [ -r "$AGENT_ENV_FILE" ]; then
    # Output to stderr: it belongs in the journal, never in the supervised
    # process's stdout (claude's is a TUI).
    { . "$AGENT_ENV_FILE"; } >&2 || echo "agent-env: $AGENT_ENV_FILE failed to load" >&2
else
    echo "agent-env: no $AGENT_ENV_FILE -- falling back to PATH only" >&2
fi

if [ "$_ae_had" = 1 ]; then
    printf '%s\n' "$_ae_was" > "$_ae_stamp" 2>/dev/null || true
else
    rm -f "$_ae_stamp" 2>/dev/null || true
fi
unset _ae_stamp _ae_had _ae_was

case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH="$HOME/.local/bin:$PATH"; export PATH ;;
esac
