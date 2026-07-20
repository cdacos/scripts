#!/bin/sh
input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd // empty')
parent=$(basename "$(dirname "$cwd")")
folder=$(basename "$cwd")
user=$(id -un 2>/dev/null || echo "${USER:-?}")
model=$(echo "$input" | jq -r '.model.display_name // empty' | awk '{print $1}')
dir_display="$parent/$folder"
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
window_size=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
rate_5h=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
rate_7d=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)

# One distinct, cool 256-colour per section.
C_USER='\033[1;38;5;141m'   # violet (bold)
C_MODEL='\033[38;5;213m'    # pink
C_CTX='\033[38;5;79m'       # teal
C_USAGE='\033[38;5;150m'    # sage green
C_BRANCH='\033[38;5;215m'   # peach
C_DIR='\033[38;5;75m'       # sky blue
NC='\033[0m'
SEP=' | '

# Append a coloured section to $parts, inserting the separator when needed.
# $1 = colour escape, $2 = text.
parts=""
add() {
  seg=$(printf '%b%s%b' "$1" "$2" "$NC")
  [ -n "$parts" ] && parts="$parts$SEP"
  parts="$parts$seg"
}

# <username> | <context> | <model> | <usage> | <git branch> | <folder>
add "$C_USER" "$user"

if [ -n "$used" ]; then
  fmt_window=$(echo "$window_size" | awk '{if($1>=1000000)printf "%.0fM",$1/1000000;else if($1>=1000)printf "%.0fk",$1/1000;else printf "%d",$1}')
  add "$C_CTX" "$(printf '%s%% of %s' "$used" "$fmt_window")"
fi

if [ -n "$rate_5h" ] || [ -n "$rate_7d" ]; then
  rate_parts=""
  [ -n "$rate_5h" ] && rate_parts="5h: ${rate_5h}%"
  if [ -n "$rate_7d" ]; then
    [ -n "$rate_parts" ] && rate_parts="$rate_parts  "
    rate_parts="${rate_parts}7d: ${rate_7d}%"
  fi
  add "$C_USAGE" "$rate_parts"
fi

[ -n "$model" ] && add "$C_MODEL" "$model"

[ -n "$branch" ] && add "$C_BRANCH" "$branch"

add "$C_DIR" "$dir_display"

printf '%s' "$parts"
