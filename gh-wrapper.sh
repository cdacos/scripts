#!/bin/sh
# gh-wrapper.sh — installed as ~/.local/bin/gh, ahead of the real gh on PATH. Chooses GH_TOKEN by
# repo owner, then runs the real gh. Owners listed in ~/.config/github-app/orgs get the GitHub
# App's installation token from github-app-token.sh; every other owner keeps the user's GH_TOKEN.
# `gh api user` always keeps the user's token: GitHub refuses App tokens on /user.
# With no github-app-token.sh on PATH, or no orgs file, it is a plain pass-through.
#
# The owner, first match wins: GITHUB_APP_OWNER; -R/--repo; a github.com URL argument;
# `gh repo <sub> OWNER/REPO`; GH_REPO; a repos/OWNER/ path for `gh api`; the checkout's origin.
# The real gh is GH_REAL, else the first gh on PATH that is not this file.
set -u

canon() { readlink -f "$1" 2>/dev/null || printf '%s' "$1"; }

real_gh() {
	if [ -n "${GH_REAL:-}" ]; then
		printf '%s' "$GH_REAL"
		return
	fi
	self=$(canon "$0")
	old_ifs=$IFS
	IFS=:
	set -f
	for d in $PATH; do
		if [ -n "$d" ] && [ -x "$d/gh" ] && [ "$(canon "$d/gh")" != "$self" ]; then
			printf '%s' "$d/gh"
			break
		fi
	done
	set +f
	IFS=$old_ifs
}

target() {
	if [ -n "${GITHUB_APP_OWNER:-}" ]; then
		echo "$GITHUB_APP_OWNER"
		return
	fi
	prev=
	for a in "$@"; do
		case $prev in -R | --repo)
			echo "$a"
			return
			;;
		esac
		case $a in
		--repo=*)
			echo "${a#--repo=}"
			return
			;;
		-R?*)
			echo "${a#-R}"
			return
			;;
		esac
		prev=$a
	done
	for a in "$@"; do
		case $a in https://github.com/* | http://github.com/* | github.com/*)
			echo "${a#*github.com/}"
			return
			;;
		esac
	done
	if [ "${1:-}" = repo ] && [ $# -ge 3 ]; then
		for a in "$@"; do
			case $a in repo | -* | *:* | */*/*) ;; ?*/?*)
				echo "$a"
				return
				;;
			esac
		done
	fi
	if [ -n "${GH_REPO:-}" ]; then
		echo "$GH_REPO"
		return
	fi
	if [ "${1:-}" = api ]; then
		for a in "$@"; do
			case $a in repos/*/* | /repos/*/*)
				a=${a#/}
				echo "${a#repos/}"
				return
				;;
			esac
		done
	fi
	url=$(git remote get-url origin 2>/dev/null) || return 0
	case $url in
	git@github.com:*) echo "${url#git@github.com:}" ;;
	*github.com/*) echo "${url#*github.com/}" ;;
	esac
}

REAL=$(real_gh)
if [ -z "$REAL" ]; then
	echo "gh-wrapper.sh: no gh on PATH other than this wrapper" >&2
	exit 127
fi

user_api=0
if [ "${1:-}" = api ]; then
	for a in "$@"; do
		case $a in user | /user | user/* | /user/*) user_api=1 ;; esac
	done
fi
if [ "$user_api" = 0 ] && command -v github-app-token.sh >/dev/null 2>&1; then
	t=$(target "$@")
	t=${t#github.com/}
	owner=$(printf '%s' "${t%%/*}" | tr '[:upper:]' '[:lower:]')
	if [ -n "$owner" ] && github-app-token.sh --is-app "$owner"; then
		tok=$(github-app-token.sh "$owner") || exit 1
		GH_TOKEN=$tok
		export GH_TOKEN
		unset tok
	fi
fi
exec "$REAL" "$@"
