#!/bin/sh
# Check for missing tools and chezmoi drift

# Tool table: cmd|description|apt|brew|url|alt-cmd (optional)
TOOLS="
chezmoi|dotfile manager|-|chezmoi|https://www.chezmoi.io/install/
starship|shell prompt|starship|starship|https://starship.rs
atuin|shell history|-|atuin|https://atuin.sh
bat|cat with syntax|bat|bat|https://github.com/sharkdp/bat|batcat
lsd|ls deluxe|lsd|lsd|https://github.com/lsd-rs/lsd
rg|fast grep|ripgrep|ripgrep|https://github.com/BurntSushi/ripgrep
fd|fast find|fd-find|fd|https://github.com/sharkdp/fd|fdfind
jq|JSON processor|jq|jq|https://jqlang.github.io/jq/
sd|sed alternative|sd|sd|https://github.com/chmln/sd
fzf|fuzzy finder|fzf|fzf|https://github.com/junegunn/fzf
doggo|DNS client|-|doggo|https://doggo.mrkaran.dev
zoxide|smart cd|zoxide|zoxide|https://github.com/ajeetdsouza/zoxide
glances|system monitor|glances|glances|https://nicolargo.github.io/glances/
termscp|TUI file transfer|-|termscp|https://termscp.veeso.dev
"

brew_pkgs=""
apt_pkgs=""
apt_urls=""
has_missing=""

echo ""
printf "  %-10s %-18s %s\n" "TOOL" "DESCRIPTION" "URL"
echo "--------------------------------------------------------------"

while IFS='|' read -r cmd desc apt brew url alt; do
    [ -z "$cmd" ] && continue
    if command -v "$cmd" >/dev/null 2>&1 || { [ -n "$alt" ] && command -v "$alt" >/dev/null 2>&1; }; then
        mark="✓"
    else
        mark="✗"
        has_missing=1
        brew_pkgs="$brew_pkgs $brew"
        if [ "$apt" != "-" ]; then
            apt_pkgs="$apt_pkgs $apt"
        else
            apt_urls="$apt_urls $url"
        fi
    fi
    printf "%-3s %-10s %-18s %s\n" "$mark" "$cmd" "$desc" "$url"
done <<EOF
$TOOLS
EOF

if [ -n "$has_missing" ]; then
    echo ""
    case "$(uname -s)" in
        Darwin)
            echo "  brew install$brew_pkgs"
            ;;
        Linux)
            if [ -n "$apt_pkgs" ]; then
                echo "  sudo apt install$apt_pkgs"
            fi
            if [ -n "$apt_urls" ]; then
                echo "  # Not in apt:$apt_urls"
            fi
            ;;
    esac
fi
echo ""

# Also check for chezmoi drift
if command -v chezmoi >/dev/null 2>&1; then
    drift=$(chezmoi status 2>/dev/null)
    if [ -n "$drift" ]; then
        echo ""
        echo "----------------------------------------"
        echo "Chezmoi files out of sync:"
        echo "$drift"
        echo "Run 'chezmoi diff' to review"
        echo ""
    fi
fi
