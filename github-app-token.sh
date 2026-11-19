#!/bin/sh
# github-app-token.sh — GitHub App installation tokens for a fleet agent.
#
#   github-app-token.sh <owner>            print a one-hour installation token for <owner>
#   github-app-token.sh --is-app <owner>   exit 0 if <owner> is served by the App
#   github-app-token.sh --drop <owner>     forget <owner>'s cached token and installation
#   github-app-token.sh credential <op>    git credential helper (get / store / erase)
#   github-app-token.sh setup              write the git config that routes the App's orgs here
#
# Config in ~/.config/github-app (GITHUB_APP_CONF), written when the App was enrolled:
#   app.json   {"app_id", "bot_login", "bot_user_id", ...}
#   key.pem    the App's private key, 0600. Only openssl reads it; it is never printed.
#   orgs       the owners the App serves, one per line
# An owner not in orgs is not ours: --is-app fails, `credential` stays silent so git tries its next
# helper, and gh-wrapper.sh keeps the user's GH_TOKEN.
#
# Tokens are cached per owner in $XDG_RUNTIME_DIR/github-app (else ~/.cache/github-app), 0600, for
# 55 of their 60 minutes. "Not installed" is never cached. A failed mint drops the cached
# installation id, and `credential erase` (git got a 401 with our token) drops the token, so an
# uninstall or a reinstall recovers by itself. The JWT and the token reach curl on stdin
# (`-K -`), never in argv.
set -eu

CONF="${GITHUB_APP_CONF:-$HOME/.config/github-app}"
CACHE="${XDG_RUNTIME_DIR:-$HOME/.cache}/github-app"
API=https://api.github.com
nl='
'

die() {
	echo "github-app-token.sh: $*" >&2
	exit 1
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
valid_owner() {
	case $1 in '' | -* | *[!a-z0-9-]*) return 1 ;; esac
	[ ${#1} -le 39 ]
}
is_app_owner() { [ -r "$CONF/orgs" ] && grep -qixF -- "$1" "$CONF/orgs"; }
message() { printf '%s' "$1" | jq -r '.message // empty' 2>/dev/null | cut -c1-200; }
b64u() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
drop() { rm -f "$CACHE/$1.token" "$CACHE/$1.inst"; }

# as_app METHOD PATH: a request as the App (JWT in $jwt). Prints the body, then a line with the
# HTTP status.
as_app() {
	printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\n' "$jwt" |
		curl -sS --max-time 30 -K - -X "$1" -w '\n%{http_code}' "$API$2"
}

mint() {
	app_id=$(jq -r '.app_id // empty' "$CONF/app.json" 2>/dev/null) || app_id=
	case $app_id in '' | *[!0-9]*) die "no app_id in $CONF/app.json" ;; esac
	[ -r "$CONF/key.pem" ] || die "cannot read $CONF/key.pem"
	now=$(date +%s)
	h=$(printf '{"alg":"RS256","typ":"JWT"}' | b64u)
	p=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$app_id" | b64u)
	s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$CONF/key.pem" -binary | b64u)
	[ -n "$s" ] || die "signing the JWT with $CONF/key.pem failed"
	jwt="$h.$p.$s"

	inst=
	if [ -s "$CACHE/$1.inst" ]; then inst=$(cat "$CACHE/$1.inst"); fi
	case $inst in
	'' | *[!0-9]*)
		inst=
		# The owner's installation: an organization first, then a user account.
		for kind in orgs users; do
			r=$(as_app GET "/$kind/$1/installation") || die "cannot reach $API"
			st=${r##*"$nl"} body=${r%"$nl"*}
			case $st in
			200)
				inst=$(printf '%s' "$body" | jq -r '.id // empty')
				break
				;;
			404) ;;
			*) die "installation lookup for $1: HTTP $st $(message "$body")" ;;
			esac
		done
		case $inst in '' | *[!0-9]*) die "the App is not installed on $1" ;; esac
		printf '%s\n' "$inst" >"$CACHE/$1.inst"
		;;
	esac

	r=$(as_app POST "/app/installations/$inst/access_tokens") || die "cannot reach $API"
	st=${r##*"$nl"} body=${r%"$nl"*}
	if [ "$st" != 201 ]; then
		drop "$1" # uninstalled, or reinstalled under a new id: look it up again next time
		die "minting a token for $1 (installation $inst): HTTP $st $(message "$body")"
	fi
	tok=$(printf '%s' "$body" | jq -r '.token // empty')
	[ -n "$tok" ] || die "the mint reply for $1 carries no token"
	tmp=$(mktemp "$CACHE/.$1.XXXXXX")
	printf '%s %s\n' $((now + 3300)) "$tok" >"$tmp"
	mv -f "$tmp" "$CACHE/$1.token"
	printf '%s\n' "$tok"
}

token() {
	is_app_owner "$1" || die "$1 is not listed in $CONF/orgs"
	umask 077
	mkdir -p "$CACHE"
	if [ -s "$CACHE/$1.token" ]; then
		exp='' tok=''
		read -r exp tok <"$CACHE/$1.token" || true
		case $exp in
		'' | *[!0-9]*) ;;
		*)
			if [ -n "$tok" ] && [ "$exp" -gt "$(date +%s)" ]; then
				printf '%s\n' "$tok"
				return 0
			fi
			;;
		esac
	fi
	mint "$1"
}

# git's credential protocol: key=value lines on stdin, ended by a blank line. Needs
# credential.https://github.com.useHttpPath, so git sends path=<owner>/<repo>.git.
credential() {
	host='' path=''
	while IFS= read -r line && [ -n "$line" ]; do
		case $line in
		host=*) host=${line#host=} ;;
		path=*) path=${line#path=} ;;
		esac
	done
	[ "$host" = github.com ] && [ -n "$path" ] || return 0
	path=${path#/}
	owner=$(lower "${path%%/*}")
	valid_owner "$owner" && is_app_owner "$owner" || return 0
	case ${1:-} in
	get)
		tok=$(token "$owner") || exit 1 # fail loudly: never an empty password
		printf 'username=x-access-token\npassword=%s\n' "$tok"
		;;
	erase) drop "$owner" ;;
	esac
}

# Writes $CONF/gitconfig and $CONF/identity.gitconfig from app.json and orgs, and includes the
# first from ~/.gitconfig.local (per-machine, not chezmoi-managed), last, so the bot identity
# overrides the user's [user] there for the App's repos only.
setup() {
	[ -r "$CONF/orgs" ] || die "no $CONF/orgs: enrol the App first"
	login=$(jq -r '.bot_login // empty' "$CONF/app.json")
	uid=$(jq -r '.bot_user_id // empty' "$CONF/app.json")
	[ -n "$login" ] || die "no bot_login in $CONF/app.json"
	case $uid in '' | *[!0-9]*) die "no bot_user_id in $CONF/app.json" ;; esac
	umask 077
	tmp=$(mktemp "$CONF/.gitconfig.XXXXXX")
	{
		echo "# Written by github-app-token.sh setup from $CONF/orgs; rerun setup after changing it."
		echo "# Repos of these owners go over HTTPS with the App's token, as the App's bot."
		printf '[credential "https://github.com"]\n\tuseHttpPath = true\n\thelper = !github-app-token.sh credential\n'
		while IFS= read -r org || [ -n "$org" ]; do
			org=$(lower "$org")
			valid_owner "$org" || continue
			printf '[url "https://github.com/%s/"]\n\tinsteadOf = git@github.com:%s/\n\tinsteadOf = ssh://git@github.com/%s/\n' \
				"$org" "$org" "$org"
			for form in "git@github.com:$org/**" "https://github.com/$org/**"; do
				printf '[includeIf "hasconfig:remote.*.url:%s"]\n\tpath = %s\n' "$form" "$CONF/identity.gitconfig"
			done
		done <"$CONF/orgs"
	} >"$tmp"
	mv -f "$tmp" "$CONF/gitconfig"
	printf '[user]\n\tname = %s\n\temail = %s+%s@users.noreply.github.com\n' "$login" "$uid" "$login" \
		>"$CONF/identity.gitconfig"
	local_cfg="$HOME/.gitconfig.local"
	if ! git config --file "$local_cfg" --get-all include.path 2>/dev/null | grep -qxF "$CONF/gitconfig"; then
		printf '[include]\n\tpath = %s\n' "$CONF/gitconfig" >>"$local_cfg"
		echo "github-app-token.sh: included $CONF/gitconfig from $local_cfg" >&2
	fi
	echo "github-app-token.sh: $(grep -c '^\[url ' "$CONF/gitconfig") org(s) routed through the App as $login" >&2
}

usage() {
	sed -n '2,8s/^# \{0,1\}//p' "$0" >&2
	exit 2
}

case ${1:-} in
--is-app)
	o=$(lower "${2:-}")
	valid_owner "$o" && is_app_owner "$o"
	;;
--drop)
	o=$(lower "${2:-}")
	valid_owner "$o" || usage
	drop "$o"
	;;
credential) credential "${2:-}" ;;
setup) setup ;;
'' | -h | --help) usage ;;
*)
	o=$(lower "$1")
	valid_owner "$o" || die "invalid owner '$1'"
	token "$o"
	;;
esac
