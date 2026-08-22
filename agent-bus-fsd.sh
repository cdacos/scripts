#!/bin/sh
# agent-bus-fsd.sh - serve this box's source tree to the agent-bus web UI.
#
# The bus is a scratch container on another machine: it cannot see your ~/src,
# and per the bus's own rule ("the bus stays frozen; new integrations are
# clients") it never should. So each agent serves its own files and this daemon
# is that server -- a client of the bus like any other, holding no inbound port,
# which is what makes it work from a NATed VM or a laptop container alike.
#
# It watches a request topic over SSE, answers only requests addressed to its
# own agent name, and publishes replies to a response topic. Topics rather than
# DMs on purpose: a DM would append every click to permanent per-agent history
# (messages.jsonl/sent.jsonl, which nothing ever prunes), and a daemon
# long-polling an inbox would contend for the claim on the bare agent name with
# the session monitor that legitimately holds it. Topic publishes touch only
# topics/<name>/<date>.jsonl.
#
# Requires: curl, jq. Environment: AGENT_BUS_URL, AGENT_BUS_TOKEN.

set -e

FSD_VERSION=1

# A literal tab and newline, for splitting and for rejecting filenames that
# would corrupt the TSV the listing pass parses.
TAB=$(printf '\t')
NL='
'

show_help() {
    cat <<'EOF'
Usage: agent-bus-fsd.sh [serve|once|check|-h]

Serves this box's source tree to the agent-bus web UI's Files tab. Runs as a
long-lived daemon; it makes only outbound requests, so it works behind NAT and
needs no open port.

Commands:
  serve            Watch the request topic and answer forever (default)
  once             Answer a single request, then exit (for testing)
  check            Verify environment, root and bus reachability, then exit
  -h, --help       Show this help

Environment:
  AGENT_BUS_URL            Base URL of the bus                     (required)
  AGENT_BUS_TOKEN          Your bearer token                       (required)
  AGENT_BUS_FS_ROOT        Directory to serve                      (default ~/src)
  AGENT_BUS_FS_REQ         Request topic to watch                  (default fs-req)
  AGENT_BUS_FS_RSP         Response topic to publish to            (default fs-rsp)
  AGENT_BUS_FS_MAX_INLINE  Bytes of text sent in a message         (default 262144)
  AGENT_BUS_FS_MAX_BLOB    Bytes a file may be to upload at all    (default 104857600)
  AGENT_BUS_FS_MAX_ENTRIES Directory entries per listing           (default 2000)
  AGENT_BUS_FS_GITIGNORE   Withhold gitignored files and .git       (default 1)
  AGENT_BUS_FS_AGENT       Answer as this agent name     (default: from /whoami)

Anything larger than MAX_INLINE, and anything that is not text, is uploaded as a
blob and referenced by id -- the UI fetches it back from the bus.

Scope: only paths under AGENT_BUS_FS_ROOT are served. Request paths are logical
and relative to that root; a ".." component is refused outright. Symlinks are
followed, but the resolved path must still land under the root or under one of
the root's direct children -- so a deliberate link like ~/src/notes -> ~/notes
works, while a link escaping to / does not.

Access is exactly the bus's own: any holder of a valid agent token may browse,
and an anonymous visitor to /ui has no token so cannot ask anything.

What is NOT served, unless AGENT_BUS_FS_GITIGNORE=0:
  - anything a repo's .gitignore covers. That is where secrets live by
    convention, and it is the one layer a browser would expose that pushing to
    a remote would not. The repo's own declaration of what it will not share is
    a better rule than any pattern list this script could guess.
  - .git directories, which hold every version of every tracked file --
    including a secret that was committed and later deleted. Withholding
    .gitignore'd files while serving .git would be theatre.
Tracked file contents are otherwise served raw, with no redaction. Anything
committed is on the remote already; the gitignored layer is not.

Examples:
  agent-bus-fsd.sh check
  agent-bus-fsd.sh serve &
  AGENT_BUS_FS_ROOT=$HOME/work agent-bus-fsd.sh serve
EOF
}

error() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

log() {
    printf '%s fsd: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >&2
}

# --- Environment ------------------------------------------------------------

require_env() {
    [ -n "$AGENT_BUS_URL" ] || error "AGENT_BUS_URL is not set"
    [ -n "$AGENT_BUS_TOKEN" ] || error "AGENT_BUS_TOKEN is not set"
    command -v curl >/dev/null 2>&1 || error "curl is required"
    command -v jq >/dev/null 2>&1 || error "jq is required"
    # Normalise: a trailing slash would yield //path and break routing.
    AGENT_BUS_URL="${AGENT_BUS_URL%/}"

    ROOT="${AGENT_BUS_FS_ROOT:-$HOME/src}"
    [ -d "$ROOT" ] || error "root is not a directory: $ROOT"
    ROOT=$(canon "$ROOT")
    [ -n "$ROOT" ] || error "cannot resolve root: ${AGENT_BUS_FS_ROOT:-$HOME/src}"

    REQ_TOPIC="${AGENT_BUS_FS_REQ:-fs-req}"
    RSP_TOPIC="${AGENT_BUS_FS_RSP:-fs-rsp}"
    MAX_INLINE="${AGENT_BUS_FS_MAX_INLINE:-262144}"
    MAX_BLOB="${AGENT_BUS_FS_MAX_BLOB:-104857600}"
    MAX_ENTRIES="${AGENT_BUS_FS_MAX_ENTRIES:-2000}"
    GITIGNORE="${AGENT_BUS_FS_GITIGNORE:-1}"

    # Fail closed and loudly at startup rather than quietly serving everything:
    # a control that silently stops applying is worse than one that was never on.
    if [ "$GITIGNORE" = 1 ] && ! command -v git >/dev/null 2>&1; then
        error "git is required to honour AGENT_BUS_FS_GITIGNORE (set it to 0 to serve every file)"
    fi

    # GNU find lists a directory in one process; the portable fallback forks
    # twice per entry, which a 40k-entry node_modules would feel.
    if find . -maxdepth 0 -printf '' >/dev/null 2>&1; then
        LISTER=gnu
    else
        LISTER=posix
    fi
}

# canon <path> -> absolute path with symlinks resolved, empty on failure.
# realpath is coreutils; the fallback resolves the parent directory, which is
# enough for containment because the caller re-tests the leaf's existence.
canon() {
    if command -v realpath >/dev/null 2>&1; then
        realpath "$1" 2>/dev/null || true
        return
    fi
    _cd=$(dirname -- "$1")
    _cb=$(basename -- "$1")
    (cd "$_cd" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$_cb") || true
}

# curl_auth passes the bearer token as a curl config file on stdin rather than
# as -H in argv. This daemon is long-lived, so an argv copy of the token would
# sit in `ps` output for every co-resident process to read for as long as it
# runs -- a standing leak, where a short CLI invocation is at least momentary.
# Callers must therefore leave stdin free; publish_rsp spools its body to a
# temp file for exactly that reason.
curl_auth() {
    printf 'header = "Authorization: Bearer %s"\n' "$AGENT_BUS_TOKEN" |
        curl -K - "$@"
}

# The daemon deliberately sends no X-Agent-Session: it is not a Claude session,
# and allocating a session number would put a phantom handle in `agents` output
# and drag it into the claim machinery. It is the legacy client path.
api() {
    _m="$1"
    _p="$2"
    shift 2
    curl_auth -sS -X "$_m" "$@" "${AGENT_BUS_URL}${_p}"
}

resolve_me() {
    if [ -n "$AGENT_BUS_FS_AGENT" ]; then
        ME="$AGENT_BUS_FS_AGENT"
        return
    fi
    ME=$(api GET /whoami | jq -r '.agent // empty')
    [ -n "$ME" ] || error "could not resolve own agent name from /whoami (bad token?)"
}

# --- Path safety ------------------------------------------------------------

# allowed_roots prints every prefix a resolved path may sit under: the root
# itself, plus each direct child resolved. The children matter because a
# deliberately placed symlink (~/src/notes -> ~/notes) is part of the tree the
# owner meant to serve, while a link two levels down pointing at / is not.
allowed_roots() {
    printf '%s\n' "$ROOT"
    for _e in "$ROOT"/*; do
        [ -e "$_e" ] || continue
        _r=$(canon "$_e")
        if [ -n "$_r" ]; then
            printf '%s\n' "$_r"
        fi
    done
}

# safe_path <logical> -> resolved absolute path on stdout, non-zero if refused.
safe_path() {
    _p="$1"
    # Paths are logical and always relative to the root; drop any leading slash.
    while :; do
        case "$_p" in
            /*) _p="${_p#/}" ;;
            *) break ;;
        esac
    done
    # Reject a ".." component exactly -- not as a substring, so "..hidden" and
    # "v1..v2" stay reachable.
    _rest="$_p"
    while [ -n "$_rest" ]; do
        case "$_rest" in
            */*)
                _seg="${_rest%%/*}"
                _rest="${_rest#*/}"
                ;;
            *)
                _seg="$_rest"
                _rest=""
                ;;
        esac
        if [ "$_seg" = ".." ]; then
            return 1
        fi
    done

    if [ -z "$_p" ]; then
        _full="$ROOT"
    else
        _full="$ROOT/$_p"
    fi
    [ -e "$_full" ] || return 1
    _real=$(canon "$_full")
    [ -n "$_real" ] || return 1

    _hit=$(
        allowed_roots | while IFS= read -r _base; do
            case "$_real" in
                "$_base" | "$_base"/*)
                    printf 'ok\n'
                    break
                    ;;
            esac
        done
    )
    [ "$_hit" = "ok" ] || return 1

    printf '%s\n' "$_real"
}

# --- Exclusions -------------------------------------------------------------

# path_excluded <resolved> -- 0 when the path must not be served, printing the
# reason. Distinct from the containment failure above, and deliberately so: the
# containment message is vague to stop a caller mapping the filesystem by
# probing, whereas these rules are public (.gitignore is committed and readable),
# so naming them costs nothing and saves confusion.
path_excluded() {
    # Both rules ride AGENT_BUS_FS_GITIGNORE, so setting it to 0 really does
    # serve every file under the root -- an escape hatch that quietly kept one
    # exclusion would make `check`'s "excluded: NOTHING" a lie.
    [ "$GITIGNORE" = 1 ] || return 1
    case "$1/" in
        */.git/*)
            printf '.git is not served (it holds every version of every tracked file)\n'
            return 0
            ;;
    esac
    # A file nested inside an ignored directory is reported ignored too, so this
    # one call covers node_modules/foo/bar as well as a named file.
    if printf '%s\n' "$(basename -- "$1")" |
        git -C "$(dirname -- "$1")" check-ignore --stdin >/dev/null 2>&1; then
        printf 'not served: excluded by .gitignore\n'
        return 0
    fi
    return 1
}

# gitignored_names <dir> -- reads candidate names on stdin, prints those the
# repo ignores. One git process per listing rather than one per entry; a
# directory outside any repo exits 128 and filters nothing, which is right --
# .gitignore is a repo's statement about itself and says nothing elsewhere.
gitignored_names() {
    [ "$GITIGNORE" = 1 ] || return 0
    git -C "$1" check-ignore --stdin 2>/dev/null || true
}

# --- Metadata ---------------------------------------------------------------

stat_size() {
    stat -c '%s' -- "$1" 2>/dev/null || stat -f '%z' -- "$1" 2>/dev/null || echo 0
}

# lang_of <name> -> a hint for the UI's highlighter. Kept here rather than in
# the browser so a peer with an unusual tree can extend it in one place.
lang_of() {
    case "$1" in
        *.go | go.mod | go.sum) echo go ;;
        *.cs | *.csx) echo cs ;;
        *.ts | *.tsx) echo ts ;;
        *.js | *.jsx | *.mjs | *.cjs) echo js ;;
        *.py) echo python ;;
        *.sh | *.bash | *.zsh | .bashrc | .profile | .zshrc) echo shell ;;
        *.sql) echo sql ;;
        *.json | *.jsonl) echo json ;;
        *.yml | *.yaml) echo yaml ;;
        *.md | *.markdown) echo markdown ;;
        *.html | *.htm | *.cshtml | *.razor | *.vue) echo html ;;
        *.css | *.scss | *.less) echo css ;;
        *.xml | *.csproj | *.props | *.targets | *.svg | *.plist) echo xml ;;
        *.toml) echo toml ;;
        *.rs) echo rust ;;
        *.c | *.h | *.cpp | *.hpp | *.cc) echo c ;;
        *.rb) echo ruby ;;
        *.java | *.kt) echo java ;;
        *.php) echo php ;;
        Dockerfile | *.dockerfile | Dockerfile.*) echo dockerfile ;;
        Makefile | makefile | GNUmakefile | *.mk) echo makefile ;;
        *) echo text ;;
    esac
}

ctype_of() {
    case "$1" in
        *.png) echo image/png ;;
        *.jpg | *.jpeg) echo image/jpeg ;;
        *.gif) echo image/gif ;;
        *.webp) echo image/webp ;;
        *.svg) echo image/svg+xml ;;
        *.pdf) echo application/pdf ;;
        *) echo application/octet-stream ;;
    esac
}

# is_binary <path> -- true when the first 8 KiB hold a NUL byte, the same cheap
# test file(1) leads with, and one that needs no extra dependency.
is_binary() {
    _n=$(head -c 8000 -- "$1" 2>/dev/null | wc -c | tr -d ' ')
    _t=$(head -c 8000 -- "$1" 2>/dev/null | LC_ALL=C tr -d '\000' | wc -c | tr -d ' ')
    [ "$_n" != "$_t" ]
}

# --- Replies ----------------------------------------------------------------

# publish_rsp reads the complete message JSON on stdin and spools it to a temp
# file, because curl_auth needs stdin for the token config -- see there.
publish_rsp() {
    _tmp=$(mktemp "${TMPDIR:-/tmp}/agent-bus-fsd.XXXXXX") || {
        log "mktemp failed; dropping reply"
        return 0
    }
    cat >"$_tmp"
    curl_auth -sS -X POST -H 'Content-Type: application/json' \
        --data-binary "@$_tmp" "${AGENT_BUS_URL}/topics/${RSP_TOPIC}" >/dev/null ||
        log "publish to ${RSP_TOPIC} failed"
    rm -f "$_tmp"
}

reply_error() {
    jq -n --arg rid "$1" --arg agent "$ME" --arg err "$2" \
        '{body: ("fs error: " + $err),
          meta: {kind: "fs.rsp", rid: $rid, agent: $agent, ok: false, error: $err}}' |
        publish_rsp
}

# --- Listing ----------------------------------------------------------------
#
# Both listers emit the same five tab-separated fields:
#   <type-not-followed> <type-followed> <size> <mtime-epoch> <name>
# Types are find's letters: d directory, f regular file, l dangling link,
# anything else is "other". Rows that do not split into exactly five fields --
# which is what a filename containing a tab or newline produces -- are dropped
# by the jq pass rather than silently mangling the listing.

list_tsv_gnu() {
    find "$1" -maxdepth 1 -mindepth 1 -printf '%y\t%Y\t%s\t%T@\t%f\n' 2>/dev/null || true
}

list_tsv_posix() {
    for _f in "$1"/* "$1"/.*; do
        [ -e "$_f" ] || [ -L "$_f" ] || continue
        _b="${_f##*/}"
        case "$_b" in
            . | ..) continue ;;
            *"$TAB"* | *"$NL"*) continue ;;
        esac
        if [ -L "$_f" ]; then _y=l; else _y=f; fi
        if [ -d "$_f" ]; then
            _yy=d
            _sz=0
        elif [ -f "$_f" ]; then
            _yy=f
            _sz=$(stat_size "$_f")
        else
            _yy=o
            _sz=0
        fi
        if [ ! -L "$_f" ] && [ "$_yy" = d ]; then _y=d; fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$_y" "$_yy" "$_sz" 0 "$_b"
    done
}

# do_list <rid> <logical> <resolved>
do_list() {
    _rid="$1"
    _logical="$2"
    _dir="$3"
    if [ ! -d "$_dir" ]; then
        reply_error "$_rid" "not a directory: $_logical"
        return
    fi
    # Read past MAX_ENTRIES so the cut can be made after sorting -- truncating
    # find's arbitrary order would hand back an arbitrary three files out of
    # thirteen, where a user expects the alphabetical first three. The hard cap
    # only bounds memory on a pathological directory.
    _cap=$((MAX_ENTRIES * 10))
    if [ "$_cap" -lt 20000 ]; then
        _cap=20000
    fi
    if [ "$LISTER" = gnu ]; then
        _raw=$(list_tsv_gnu "$_dir" | head -n "$_cap")
    else
        _raw=$(list_tsv_posix "$_dir" | head -n "$_cap")
    fi
    # One git call for the whole directory, and filtered before the cap so the
    # count reported is of entries actually served.
    _ign=$(printf '%s\n' "$_raw" | cut -f5 | gitignored_names "$_dir")

    # .git is hidden from listings under the same flag that hides ignored
    # files, so the flag off really does mean "serve everything".
    if [ "$GITIGNORE" = 1 ]; then _hidegit=true; else _hidegit=false; fi

    printf '%s\n' "$_raw" | jq -R -s \
        --arg rid "$_rid" --arg agent "$ME" --arg path "$_logical" \
        --arg ign "$_ign" --argjson max "$MAX_ENTRIES" \
        --argjson hidegit "$_hidegit" '
        (($ign | split("\n") | map(select(length > 0))) | INDEX(.)) as $skip
        |
        (split("\n") | map(select(length > 0)) | map(split("\t"))
         | map(select(length == 5))
         | map(select((($hidegit and .[4] == ".git") | not) and ($skip[.[4]] | not)))
         | map({
              name:  .[4],
              type:  (if .[1] == "d" then "dir"
                      elif .[1] == "f" then "file" else "other" end),
              size:  (.[2] | tonumber? // 0),
              mtime: (.[3] | tonumber? // 0 | floor),
              link:  (.[0] == "l")
           })
         | sort_by(.type != "dir", (.name | ascii_downcase))) as $all
        | ($all | length > $max) as $trunc
        | ($all[0:$max]) as $entries
        | {body: ("listing " + (if $path == "" then "." else $path end)
                  + " (" + ($entries | length | tostring) + " entries"
                  + (if $trunc then ", truncated" else "" end) + ")"),
           meta: {kind: "fs.rsp", rid: $rid, agent: $agent, ok: true,
                  op: "list", path: $path, trunc: $trunc, entries: $entries}}' |
        publish_rsp
}

# --- Reading ----------------------------------------------------------------

# do_read <rid> <logical> <resolved>
do_read() {
    _rid="$1"
    _logical="$2"
    _file="$3"
    if [ ! -f "$_file" ]; then
        reply_error "$_rid" "not a regular file: $_logical"
        return
    fi
    if [ ! -r "$_file" ]; then
        reply_error "$_rid" "not readable: $_logical"
        return
    fi
    _size=$(stat_size "$_file")
    _name="${_logical##*/}"
    _lang=$(lang_of "$_name")

    if is_binary "$_file"; then _bin=true; else _bin=false; fi

    if [ "$_bin" = true ] || [ "$_size" -gt "$MAX_INLINE" ]; then
        if [ "$_size" -gt "$MAX_BLOB" ]; then
            reply_error "$_rid" "$_logical is ${_size} bytes, over the ${MAX_BLOB} byte limit"
            return
        fi
        # Blobs are content-addressed, so re-reading an unchanged file uploads
        # nothing new and the UI can cache on the id.
        _ctype=$(ctype_of "$_name")
        _blob=$(api POST /blobs -H "Content-Type: $_ctype" \
            --data-binary "@$_file" | jq -r '.id // empty')
        if [ -z "$_blob" ]; then
            reply_error "$_rid" "blob upload failed for $_logical"
            return
        fi
        # ctype rides along so the UI can decide to preview an image without
        # having to re-derive the type from the extension.
        jq -n --arg rid "$_rid" --arg agent "$ME" --arg path "$_logical" \
            --arg blob "$_blob" --arg lang "$_lang" --arg name "$_name" \
            --arg ctype "$_ctype" \
            --argjson size "$_size" --argjson binary "$_bin" '
            {body: ($name + " (" + ($size | tostring) + " bytes) served as blob " + $blob),
             meta: {kind: "fs.rsp", rid: $rid, agent: $agent, ok: true,
                    op: "read", path: $path, mode: "blob", blob: $blob,
                    size: $size, lang: $lang, binary: $binary, ctype: $ctype}}' |
            publish_rsp
        return
    fi

    # Content rides in meta, not body: the bus rejects an empty body, so an
    # empty file would otherwise 400, and a topic feed should not have whole
    # source files dumped into it. jq slurps the file whole, so a trailing
    # newline survives -- command substitution only trims the quoted literal.
    _content=$(jq -R -s '.' <"$_file")
    jq -n --arg rid "$_rid" --arg agent "$ME" --arg path "$_logical" \
        --arg lang "$_lang" --arg name "$_name" --argjson size "$_size" \
        --argjson content "$_content" '
        {body: ($name + " (" + ($size | tostring) + " bytes)"),
         meta: {kind: "fs.rsp", rid: $rid, agent: $agent, ok: true,
                op: "read", path: $path, mode: "inline", size: $size,
                lang: $lang, binary: false, content: $content}}' |
        publish_rsp
}

do_ping() {
    jq -n --arg rid "$1" --arg agent "$ME" --arg root "$ROOT" \
        --argjson version "$FSD_VERSION" '
        {body: ($agent + " serving " + $root),
         meta: {kind: "fs.rsp", rid: $rid, agent: $agent, ok: true,
                op: "ping", root: $root, version: $version}}' |
        publish_rsp
}

# --- Dispatch ---------------------------------------------------------------

# handle_request <message-json>
handle_request() {
    _msg="$1"
    _kind=$(printf '%s' "$_msg" | jq -r '.meta.kind // empty' 2>/dev/null || true)
    case "$_kind" in
        fs.list | fs.read | fs.ping) ;;
        *) return 0 ;;
    esac
    # Case-insensitive: agents.json capitalises names, humans rarely do.
    _target=$(printf '%s' "$_msg" | jq -r '.meta.agent // empty' | tr '[:upper:]' '[:lower:]')
    _lm=$(printf '%s' "$ME" | tr '[:upper:]' '[:lower:]')
    [ "$_target" = "$_lm" ] || return 0

    _rid=$(printf '%s' "$_msg" | jq -r '.meta.rid // empty')
    [ -n "$_rid" ] || return 0
    _path=$(printf '%s' "$_msg" | jq -r '.meta.path // ""')

    log "$_kind ${_path:-.} (rid $_rid)"

    if [ "$_kind" = "fs.ping" ]; then
        do_ping "$_rid"
        return 0
    fi

    if ! _real=$(safe_path "$_path"); then
        # One message for "outside the root" and for "does not exist", on
        # purpose: telling them apart would let a caller map the filesystem
        # above the root by probing, which is the one thing containment is for.
        reply_error "$_rid" "no such path under the served root: $_path"
        return 0
    fi

    if _why=$(path_excluded "$_real"); then
        reply_error "$_rid" "$_why"
        return 0
    fi

    case "$_kind" in
        fs.list) do_list "$_rid" "$_path" "$_real" ;;
        fs.read) do_read "$_rid" "$_path" "$_real" ;;
    esac
}

# --- Main loop --------------------------------------------------------------

# watch_once streams the request topic until the connection drops.
#
# Requests are handled off the reader loop, because the loop falling behind
# loses work rather than merely delaying it: the bus notifies SSE watchers
# through a 16-deep channel it drops from when full ("slow subscriber: drop the
# nudge; disk has the message"), which is harmless for an inbox that can be
# re-read but fatal for a request that only ever exists as a nudge. So a big
# blob upload must never sit in front of the next read.
#
# The handler is double-forked -- ( cmd & ) rather than cmd & -- so the inner
# job is orphaned onto init, which reaps it. A plain background job would leave
# a zombie per request, since a POSIX shell only reaps what it waits for and
# `wait` here would defeat the point.
#
# curl feeds a FIFO rather than a pipe into the loop, so that the loop runs in
# *this* shell and curl's pid is known. The obvious `curl | while read` spawns
# both halves in subshells, and killing the daemon by the pid its operator has
# (the one `$!` or a pidfile gave them) then leaves that pipeline orphaned onto
# init, still subscribed and still answering. Two daemons for one agent both
# reply to the same rid and the UI keeps whichever lands first -- so a restart
# after an AGENT_BUS_FS_ROOT change would silently serve the old root half the
# time. cleanup runs on EXIT, INT and TERM so a plain kill really stops it.
watch_once() {
    _fifodir=$(mktemp -d "${TMPDIR:-/tmp}/agent-bus-fsd.XXXXXX") || {
        log "mktemp -d failed; cannot start reader"
        return 1
    }
    _fifo="$_fifodir/stream"
    mkfifo "$_fifo" || {
        rm -rf "$_fifodir"
        log "mkfifo failed; cannot start reader"
        return 1
    }

    # Inlined rather than routed through curl_auth because $_reader_pid must be
    # curl itself: backgrounding a pipeline sets $! to its last element, but
    # backgrounding a *function* that wraps a pipeline sets it to the wrapper
    # subshell -- and killing that wrapper would orphan the curl inside, leaving
    # the subscription open. The token still travels on stdin, never in argv.
    # The redirect is set up in the forked child before curl execs, so the write
    # end is always opened: a curl that fails immediately closes it and the loop
    # sees EOF, rather than blocking on a FIFO nobody ever opens.
    printf 'header = "Authorization: Bearer %s"\n' "$AGENT_BUS_TOKEN" |
        curl -K - -sSN "${AGENT_BUS_URL}/topics/${REQ_TOPIC}/watch" >"$_fifo" 2>/dev/null &
    _reader_pid=$!
    # A signal must tear down and leave; without the explicit exit the handler
    # would return and the read loop would carry on as if nothing had happened.
    trap 'stop_reader; exit 143' INT TERM
    trap 'stop_reader' EXIT

    while IFS= read -r _line; do
        case "$_line" in
            'data: '*)
                if [ "$ONCE" = "1" ]; then
                    # Synchronous, so `once` cannot exit before replying.
                    handle_request "${_line#data: }"
                    stop_reader
                    return 0
                fi
                (handle_request "${_line#data: }" &)
                ;;
            *) : ;; # ": keepalive" comments, "id:" lines, blank separators
        esac
    done <"$_fifo"

    stop_reader
}

# Idempotent: watch_once calls it on the normal path and the trap calls it on a
# signal, and `serve` reconnects in a loop, so it must tolerate being run twice.
stop_reader() {
    trap - EXIT INT TERM
    if [ -n "$_reader_pid" ]; then
        kill "$_reader_pid" 2>/dev/null || true
        wait "$_reader_pid" 2>/dev/null || true
        _reader_pid=""
    fi
    if [ -n "$_fifodir" ]; then
        rm -rf "$_fifodir"
        _fifodir=""
    fi
    return 0
}

_reader_pid=""
_fifodir=""

serve() {
    log "serving $ROOT as $ME ($REQ_TOPIC -> $RSP_TOPIC, lister $LISTER)"
    _backoff=1
    while :; do
        watch_once || true
        if [ "$ONCE" = "1" ]; then
            return 0
        fi
        log "stream ended; reconnecting in ${_backoff}s"
        sleep "$_backoff"
        # Cap the backoff: the bus restarting should not leave every daemon on
        # the fleet asleep for ten minutes afterwards.
        _backoff=$((_backoff * 2))
        if [ "$_backoff" -gt 30 ]; then
            _backoff=30
        fi
    done
}

ONCE=0

case "${1:-serve}" in
    -h | --help | help)
        show_help
        ;;
    check)
        require_env
        resolve_me
        printf 'agent   : %s\n' "$ME"
        printf 'root    : %s\n' "$ROOT"
        printf 'bus     : %s\n' "$AGENT_BUS_URL"
        printf 'topics  : %s -> %s\n' "$REQ_TOPIC" "$RSP_TOPIC"
        printf 'lister  : %s\n' "$LISTER"
        printf 'roots   : %s allowed prefixes\n' "$(allowed_roots | wc -l | tr -d ' ')"
        if [ "$GITIGNORE" = 1 ]; then
            printf 'excluded: gitignored files and .git\n'
            # Name the repos whose ignored files are being withheld, so starting
            # the daemon says what it is holding back rather than leaving the
            # operator to guess.
            for _e in "$ROOT"/*; do
                [ -d "$_e" ] || continue
                _n=$(git -C "$_e" ls-files --others --ignored --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
                [ "$_n" = 0 ] || printf '          %s: %s ignored file(s) withheld\n' "${_e##*/}" "$_n"
            done
        else
            printf 'excluded: NOTHING - every file under the root is served\n'
        fi
        api GET /topics >/dev/null || error "cannot reach the bus"
        printf 'status  : ok\n'
        ;;
    once)
        require_env
        resolve_me
        ONCE=1
        serve
        ;;
    serve)
        require_env
        resolve_me
        serve
        ;;
    *)
        error "unknown command: $1 (try --help)"
        ;;
esac
