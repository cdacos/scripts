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

# REDUNDANT ONCE THE GUARD IS FLEET-WIDE -- AND DELIBERATELY STILL HERE.
# common.sh now runs its daily check in interactive shells only (cdacos/dotfiles
# ef27efa), which fixes this at the source and makes everything in this block a
# no-op. It is not removed yet because the two halves travel by different roads:
# agent-env.sh ships as a chezmoi *external*, refetched from GitHub on nearly
# every apply, while common.sh is a managed file served from the box's local
# source clone. A box that runs `chezmoi apply` without pulling therefore gets
# the new agent-env.sh beside an old, unguarded common.sh. Deleting this first
# would silently restore the original bug on exactly the boxes slowest to update,
# and silently is the whole problem. Remove once marvin, speedy and tweety have
# each confirmed the guarded common.sh. (Ordering hazard spotted by Tweety.)
#
# --- borrow the daily-check stamp, then give it back ------------------------
# Two guards, because the harm is invisible from the human side by construction:
#
#   flock  agent.target starts agent-claude and agent-fsd together, so two
#          agent-env.sh instances race at every boot. Unlocked they interleave --
#          A pins, B reads the pinned value as "original", A restores, B restores
#          the pin -- and the stamp is left claimed for good. Not hypothetical:
#          that is the normal boot path.
#   trap   a death between pin and restore (OOM, systemd stop, a failing source)
#          would leave the stamp pinned, reintroducing the exact failure this
#          designs out, on the error path where nobody looks.
#
# Honest limit: the lock only serialises agent-env.sh against itself. A human's
# interactive shell reaches common.sh through ~/.bashrc and takes no lock, so a
# shell started inside the pinned window still short-circuits. That window is
# milliseconds and closing it would mean editing a shared dotfile, so it is left
# open deliberately rather than by oversight. (Residual raised by Tweety.)
_ae_stamp="$HOME/.cache/daily_check_stamp"
_ae_done=0

_ae_restore_stamp() {
    [ "$_ae_done" = 1 ] && return 0
    _ae_done=1
    if [ "$_ae_had" = 1 ]; then
        printf '%s\n' "$_ae_was" > "$_ae_stamp" 2>/dev/null || true
    else
        rm -f "$_ae_stamp" 2>/dev/null || true
    fi
    flock -u 9 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
}

mkdir -p "$HOME/.cache" 2>/dev/null || true
exec 9>"$HOME/.cache/.daily_check_stamp.lock" 2>/dev/null || true
flock -w 5 9 2>/dev/null || true

if [ -f "$_ae_stamp" ]; then
    _ae_had=1; _ae_was=$(cat "$_ae_stamp" 2>/dev/null || true)
else
    _ae_had=0; _ae_was=""
fi
date +%j > "$_ae_stamp" 2>/dev/null || true

_ae_prev_trap=$(trap -p EXIT 2>/dev/null)
trap '_ae_restore_stamp' EXIT INT TERM HUP

if [ -r "$AGENT_ENV_FILE" ]; then
    # Output to stderr: it belongs in the journal, never in the supervised
    # process's stdout (claude's is a TUI).
    { . "$AGENT_ENV_FILE"; } >&2 || echo "agent-env: $AGENT_ENV_FILE failed to load" >&2
else
    echo "agent-env: no $AGENT_ENV_FILE -- falling back to PATH only" >&2
fi

_ae_restore_stamp
trap - EXIT INT TERM HUP
[ -n "$_ae_prev_trap" ] && eval "$_ae_prev_trap"
unset _ae_stamp _ae_had _ae_was _ae_done _ae_prev_trap
unset -f _ae_restore_stamp

case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH="$HOME/.local/bin:$PATH"; export PATH ;;
esac
