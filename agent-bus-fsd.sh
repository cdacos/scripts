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

FSD_VERSION=3

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
  AGENT_BUS_FS_MAX_HITS    Search matches returned per query       (default 200)
  AGENT_BUS_FS_GREP_TIMEOUT  Seconds one search may run            (default 15)
  AGENT_BUS_FS_GIT_TIMEOUT   Seconds one git command may run       (default 10)
  AGENT_BUS_FS_GIT_BASE    Branch the git panel compares against   (default main)
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

The git ops (fs.git, fs.gitdiff) back the web UI's branch panel: which repo a
path is in, its branch, which files differ from AGENT_BUS_FS_GIT_BASE, and one
file's diff. The comparison is merge-base(base, HEAD) against the working tree,
so it shows this branch's own work -- committed and not -- and never the commits
the base has gained since. Read-only: nothing here writes the index, so browsing
cannot disturb an agent working in the same checkout.

Search (fs.grep) uses ripgrep when a real rg binary is on PATH, otherwise
`git grep --no-index --exclude-standard`, and plain grep only where there is no
git at all. All three honour the same exclusions as browsing; the reply names
which engine ran, and says so when a cap or the timeout cut it short.

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
    MAX_HITS="${AGENT_BUS_FS_MAX_HITS:-200}"
    GREP_TIMEOUT="${AGENT_BUS_FS_GREP_TIMEOUT:-15}"
    GIT_TIMEOUT="${AGENT_BUS_FS_GIT_TIMEOUT:-10}"
    GIT_BASE="${AGENT_BUS_FS_GIT_BASE:-main}"
    GITIGNORE="${AGENT_BUS_FS_GITIGNORE:-1}"

    # Resolved once rather than per query: which engine is available is a
    # property of the box, and `check` should be able to report it.
    RG_BIN=$(grep_binary rg || true)
    GIT_BIN=$(grep_binary git || true)
    TIMEOUT_BIN=$(grep_binary timeout || true)
    if rg_usable; then
        RG_OK=1
    else
        RG_OK=0
        if [ -n "$RG_BIN" ]; then
            log "rg at $RG_BIN did not produce the expected field format; using $(grep_engine) instead"
        fi
    fi

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

# safe_logical <logical> -> "$ROOT/<cleaned>" without testing existence.
#
# safe_path refuses anything that is not on disk, which is right for reading and
# listing and wrong for a diff: a file DELETED on this branch is precisely what
# you want to look at. So this does the half of the job that does not need the
# filesystem -- strip leading slashes, refuse a ".." component -- and leaves
# containment to the caller. Only do_gitdiff may use it, and only because the
# result never reaches open(2): it goes to git as a pathspec, resolved against
# the index and trees of a repo already proved to sit under the served root.
safe_logical() {
    _p="$1"
    while :; do
        case "$_p" in
            /*) _p="${_p#/}" ;;
            *) break ;;
        esac
    done
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
    [ -n "$_p" ] || return 1
    printf '%s/%s\n' "$ROOT" "$_p"
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
    # source files dumped into it.
    #
    # --rawfile, not --arg or --argjson: a single argv entry is capped at
    # MAX_ARG_STRLEN, which is 128 KiB and has nothing to do with the much
    # larger ARG_MAX everyone reaches for. Every text file between that and the
    # 256 KiB MAX_INLINE therefore died with "Argument list too long" on a
    # stderr nobody reads, published nothing, and left the tab spinning until
    # its 20s timeout -- ten real files under this root, one of them a plan doc.
    # Passing the path lets jq read the bytes itself, and it still slurps the
    # file whole, so a trailing newline survives.
    jq -n --arg rid "$_rid" --arg agent "$ME" --arg path "$_logical" \
        --arg lang "$_lang" --arg name "$_name" --argjson size "$_size" \
        --rawfile content "$_file" '
        {body: ($name + " (" + ($size | tostring) + " bytes)"),
         meta: {kind: "fs.rsp", rid: $rid, agent: $agent, ok: true,
                op: "read", path: $path, mode: "inline", size: $size,
                lang: $lang, binary: false, content: $content}}' |
        publish_rsp
}

# --- Searching --------------------------------------------------------------
#
# Search has to withhold exactly what browsing withholds, which rules out the
# obvious single recursive pass. Measured on this 7-repo root, a plain
# `git grep --no-index` returned 8890 of 14042 matched files from .git or an
# ignored node_modules, because --no-index alone does not consult a nested
# repository's .gitignore. Adding --exclude-standard takes that to zero and
# still sweeps the whole root in about a second, so that is the git engine.
#
# Every engine normalises to <path> TAB <line> TAB <text>, split on the first
# two tabs only. Requiring <line> to be digits is what makes that safe: a
# filename holding a tab yields a non-numeric field and the row is dropped,
# while tabs inside a source line -- which are everywhere -- survive intact.

# Milliseconds since the epoch. GNU/busybox date has %N; BSD date prints it
# literally, so a non-numeric result falls back to whole seconds rather than
# poisoning the arithmetic that reads it.
now_ms() {
    _n=$(date +%s%N 2>/dev/null || true)
    case "$_n" in
        '' | *[!0-9]*) printf '%s000\n' "$(date +%s)" ;;
        *) printf '%s\n' $((_n / 1000000)) ;;
    esac
}

# grep_binary <name> -- absolute path of a real executable, or nothing.
#
# The absolute-path test is the whole point. A box whose interactive shell
# defines rg as a *function* (Claude Code ships exactly such a shim, and this
# box has one) satisfies `command -v rg` while having no rg binary anywhere;
# running it would launch a different program entirely.
grep_binary() {
    _b=$(command -v "$1" 2>/dev/null) || return 1
    case "$_b" in
        /*)
            [ -x "$_b" ] || return 1
            printf '%s\n' "$_b"
            ;;
        *) return 1 ;;
    esac
}

# rg_usable -- does this ripgrep actually emit the three fields the parser
# needs? Proved against a synthetic file at startup rather than inferred from a
# version number.
#
# This exists because the -I mistake above cost nothing at all to make and
# produced no error: rg exited 0, wrote output, and every row was silently
# discarded downstream. A flag whose meaning shifts under us -- across a major
# version, a distro patch, or a user's RIPGREP_CONFIG_PATH -- must fail loudly
# here and fall back to git, not return "no matches" for a file that has them.
rg_usable() {
    [ -n "$RG_BIN" ] || return 1
    _pd=$(mktemp -d "${TMPDIR:-/tmp}/agent-bus-fsd-probe.XXXXXX") || return 1
    printf 'alpha\nbeta gamma\n' >"$_pd/probe.txt"
    # RIPGREP_CONFIG_PATH is cleared for the probe and for every real search, so
    # a user's config file cannot bend the output format under us.
    _po=$(cd "$_pd" 2>/dev/null && RIPGREP_CONFIG_PATH= "$RG_BIN" \
        --no-heading --line-number --with-filename --color never --smart-case \
        --fixed-strings --field-match-separator "$TAB" -e 'beta' -- . 2>/dev/null |
        head -n 1)
    rm -rf "$_pd"
    case "$_po" in
        "./probe.txt${TAB}2${TAB}beta gamma" | "probe.txt${TAB}2${TAB}beta gamma") return 0 ;;
        *) return 1 ;;
    esac
}

grep_engine() {
    if [ "$RG_OK" = 1 ]; then
        printf 'rg\n'
    elif [ -n "$GIT_BIN" ]; then
        printf 'git\n'
    else
        printf 'grep\n'
    fi
}

# Bounded so a pathological query can neither pin the box nor outlive the UI's
# own wait. Detection of the cut is by elapsed time rather than exit status:
# these all run at the head of a pipeline, where $? belongs to the tail.
run_bounded() {
    if [ -n "$TIMEOUT_BIN" ]; then
        "$TIMEOUT_BIN" "$GREP_TIMEOUT" "$@"
    else
        "$@"
    fi
}

# Case handling is smart-case throughout: an all-lowercase query is
# case-insensitive, one with a capital in it is not. rg has the flag; the other
# two get the same rule applied by hand so search behaves identically whichever
# engine a peer's box happens to have.
grep_icase_flag() {
    case "$1" in
        *[A-Z]*) printf '' ;;
        *) printf -- '-i' ;;
    esac
}

# Each runner cds into the search directory and searches "." so the engine
# emits relative paths. Stripping a literal "./" prefix is safe; stripping an
# absolute prefix with sed would not be, since a directory name may hold
# characters sed reads as syntax.

# No -I here, deliberately. It means "skip binary files" to grep(1) but
# "--no-filename" to ripgrep, which stripped the path off every row and left the
# parser dropping all of them -- a search that returned zero while looking
# perfectly healthy. ripgrep skips binary content by default anyway.
grep_run_rg() {
    _o="--no-heading --line-number --with-filename --color never --hidden --smart-case"
    if [ "$3" != true ]; then _o="$_o --fixed-strings"; fi
    if [ "$GITIGNORE" != 1 ]; then _o="$_o --no-ignore"; fi
    # shellcheck disable=SC2086
    (cd "$1" 2>/dev/null && RIPGREP_CONFIG_PATH= run_bounded "$RG_BIN" $_o --glob '!.git' \
        --field-match-separator "$TAB" -e "$2" -- . 2>/dev/null) | sed 's#^\./##'
}

grep_run_git() {
    _o="-zn -I --no-index"
    if [ "$GITIGNORE" = 1 ]; then _o="$_o --exclude-standard"; fi
    if [ "$3" != true ]; then _o="$_o --fixed-strings"; fi
    _o="$_o $(grep_icase_flag "$2")"
    # shellcheck disable=SC2086
    (cd "$1" 2>/dev/null && run_bounded "$GIT_BIN" grep $_o -e "$2" -- . 2>/dev/null) |
        tr '\000' '\011' | sed 's#^\./##'
}

# Only reachable with GITIGNORE=0, since the daemon refuses to start without git
# while the flag is on -- so this engine deliberately has no ignore handling.
grep_run_grep() {
    _o="-rnI --binary-files=without-match --exclude-dir=.git"
    if [ "$3" != true ]; then _o="$_o -F"; fi
    _o="$_o $(grep_icase_flag "$2")"
    # shellcheck disable=SC2086
    (cd "$1" 2>/dev/null && run_bounded grep $_o -e "$2" -- . 2>/dev/null) |
        sed 's#^\./##' | sed "s#:#$TAB#; s#:#$TAB#"
}

# grep_names <dir> <query> -- served paths whose name contains the query.
#
# Worth its own pass because the thing you are looking for is often a file, not
# a line: "fsd" finds agent-bus-fsd.sh, which no content search would surface.
# The empty pattern is how the git engine enumerates what it would serve --
# same exclusions as the content search, by construction rather than by a
# second list of rules that could drift out of step.
grep_names() {
    case "$(grep_engine)" in
        rg)
            _o="--files --hidden"
            if [ "$GITIGNORE" != 1 ]; then _o="$_o --no-ignore"; fi
            # shellcheck disable=SC2086
            (cd "$1" 2>/dev/null && RIPGREP_CONFIG_PATH= run_bounded "$RG_BIN" $_o --glob '!.git' 2>/dev/null)
            ;;
        git)
            _o="-lI --no-index"
            if [ "$GITIGNORE" = 1 ]; then _o="$_o --exclude-standard"; fi
            # shellcheck disable=SC2086
            (cd "$1" 2>/dev/null && run_bounded "$GIT_BIN" grep $_o -e '' -- . 2>/dev/null)
            ;;
        *)
            (cd "$1" 2>/dev/null && run_bounded find . -type f -not -path '*/.git/*' 2>/dev/null)
            ;;
    esac | sed 's#^\./##' | grep -i -F -e "$2" 2>/dev/null | head -n 50
}

# do_grep <rid> <logical> <resolved> <query> <regex?>
do_grep() {
    _rid="$1"
    _logical="$2"
    _dir="$3"
    _q="$4"
    _rx="$5"
    if [ -z "$_q" ]; then
        reply_error "$_rid" "empty search"
        return
    fi
    # Searching "from" a file means searching the directory holding it, which is
    # what the UI asks for when you search with a file already open.
    if [ ! -d "$_dir" ]; then
        _dir=$(dirname -- "$_dir")
        case "$_logical" in
            */*) _logical="${_logical%/*}" ;;
            *) _logical="" ;;
        esac
    fi

    _engine=$(grep_engine)
    _hitfile=$(mktemp "${TMPDIR:-/tmp}/agent-bus-fsd.XXXXXX") || {
        reply_error "$_rid" "mktemp failed"
        return
    }
    _namefile=$(mktemp "${TMPDIR:-/tmp}/agent-bus-fsd.XXXXXX") || {
        rm -f "$_hitfile"
        reply_error "$_rid" "mktemp failed"
        return
    }

    _t0=$(now_ms)
    # A hard line cap ahead of jq bounds memory on a query like "e"; the real
    # per-file and overall caps are applied after grouping, so what comes back
    # is the alphabetical first N rather than an arbitrary N.
    _scan=$((MAX_HITS * 20))
    case "$_engine" in
        rg) grep_run_rg "$_dir" "$_q" "$_rx" ;;
        git) grep_run_git "$_dir" "$_q" "$_rx" ;;
        *) grep_run_grep "$_dir" "$_q" "$_rx" ;;
    esac | head -n "$_scan" >"$_hitfile" 2>/dev/null || true
    grep_names "$_dir" "$_q" >"$_namefile" 2>/dev/null || true
    _t1=$(now_ms)
    _elapsed=$((_t1 - _t0))
    # timeout(1) fires at the head of a pipeline, where its status is lost, so
    # the wall clock is what tells us the sweep was cut short. The margin
    # absorbs now_ms falling back to whole seconds on a box without GNU date.
    if [ -n "$TIMEOUT_BIN" ] && [ "$_elapsed" -ge "$((GREP_TIMEOUT * 1000 - 500))" ]; then
        _timedout=true
    else
        _timedout=false
    fi

    jq -R -s --rawfile names "$_namefile" \
        --arg rid "$_rid" --arg agent "$ME" --arg path "$_logical" \
        --arg q "$_q" --arg engine "$_engine" \
        --argjson max "$MAX_HITS" --argjson timedout "$_timedout" \
        --argjson elapsed "$_elapsed" '
        def clip: if length > 400 then .[0:400] + " …" else . end;
        (split("\n") | map(select(length > 0))
         | map(
             (index("\t")) as $i
             | select($i != null)
             | {p: .[0:$i], r: .[$i+1:]}
             | (.r | index("\t")) as $j
             | select($j != null)
             | {path: .p, line: .r[0:$j], text: .r[$j+1:]}
             | select(.line | test("^[0-9]+$"))
             | {path: .path, line: (.line | tonumber), text: (.text | clip)})
        ) as $all
        # 20 per file so one generated file cannot crowd out every other hit.
        | ($all | group_by(.path) | map(.[0:20]) | flatten) as $capped
        | ($capped[0:$max]) as $hits
        | (($capped | length) > $max) as $overcap
        | (($all | length) > ($capped | length)) as $overfile
        | ($names | split("\n") | map(select(length > 0))) as $files
        | {body: ("search " + $q + ": " + ($hits | length | tostring) + " matches in "
                  + ($hits | map(.path) | unique | length | tostring) + " files"),
           meta: {kind: "fs.rsp", rid: $rid, agent: $agent, ok: true,
                  op: "grep", path: $path, query: $q, engine: $engine,
                  matches: $hits, files: $files, elapsed: $elapsed,
                  trunc: ($overcap or $overfile or $timedout),
                  truncwhy: (if $timedout then "timed out"
                             elif $overcap then "capped at " + ($max | tostring) + " matches"
                             elif $overfile then "capped at 20 matches per file"
                             else "" end)}}' <"$_hitfile" |
        publish_rsp
    rm -f "$_hitfile" "$_namefile"
}

# The ops list is how the UI knows whether to offer search: a fleet updates one
# box at a time, and a search box that silently times out against last week's
# daemon is worse than one that says why it is disabled. Version alone would do
# it, but naming the ops means the next capability needs no new field.
do_ping() {
    jq -n --arg rid "$1" --arg agent "$ME" --arg root "$ROOT" \
        --arg engine "$(grep_engine)" --arg gitbase "$GIT_BASE" \
        --argjson version "$FSD_VERSION" '
        {body: ($agent + " serving " + $root),
         meta: {kind: "fs.rsp", rid: $rid, agent: $agent, ok: true,
                op: "ping", root: $root, version: $version,
                ops: ["list", "read", "ping", "grep", "git", "gitdiff"],
                gitbase: $gitbase, engine: $engine}}' |
        publish_rsp
}

# --- Git --------------------------------------------------------------------
#
# Two ops behind the UI's branch panel: fs.git names the repo a path sits in
# and lists what differs from the base branch, fs.gitdiff returns one file's
# diff. Both are strictly read-only -- no add, no stash, no checkout, nothing
# that writes the index -- because an agent is very likely working in the same
# checkout while somebody browses it, and a browser must not be able to disturb
# a colleague's tree.
#
# The comparison is merge-base(BASE, HEAD) against the WORKING TREE, chosen
# deliberately over the two obvious alternatives:
#
#   - against BASE's tip rather than the merge base, which would report every
#     commit the base gained since you branched as though it were your change;
#   - against HEAD rather than the working tree, which would hide uncommitted
#     edits -- and then the "view file" link, which serves what is on disk,
#     would show content the diff had just claimed was not there.
#
# So the panel and the plain-file view always describe the same bytes. A repo
# sitting on the base branch itself has merge-base == HEAD, which makes the
# list exactly its uncommitted work; that is the right answer and not a
# special case.

# Bounded like search is, and for the same reason: a diff against the working
# tree stats every tracked file, so a cold cache on a large repo is slow enough
# to outlive the UI's own wait if a disk is struggling.
git_bounded() {
    if [ -n "$TIMEOUT_BIN" ]; then
        "$TIMEOUT_BIN" "$GIT_TIMEOUT" "$@"
    else
        "$@"
    fi
}

# logical_roots -- prints "<logical>TAB<resolved>" for the served root (whose
# logical path is empty) and for each of its direct children.
#
# The same set of prefixes safe_path allows, and for the same reason, but paired
# with the name each one is reached by. Resolving alone is not enough here: the
# answer has to be a path the UI can hand back as fs.read or fs.gitdiff, and
# that is the logical one.
logical_roots() {
    printf '%s%s\n' "$TAB" "$ROOT"
    for _e in "$ROOT"/*; do
        [ -e "$_e" ] || continue
        _r=$(canon "$_e")
        [ -n "$_r" ] || continue
        printf '%s%s%s\n' "${_e##*/}" "$TAB" "$_r"
    done
}

# git_repo_root <dir> -> the repo root as a logical path (empty when the served
# root is itself a repo), non-zero when <dir> is in no repo this daemon serves.
git_repo_root() {
    _top=$(git_bounded git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
    [ -n "$_top" ] || return 1
    _top=$(canon "$_top")
    [ -n "$_top" ] || return 1
    # Matched against every prefix safe_path allows, not merely against the
    # served root, because a direct child may be a symlink out of the tree --
    # on this box dotfiles -> ~/.local/share/chezmoi and marvin-memories ->
    # ~/.claude/... are two of the six repos. Those links are deliberate and
    # browsing already treats them as part of the tree, so reporting "no repo"
    # for them left the root menu offering a door that opened onto nothing.
    #
    # A repo whose root sits above ALL of those prefixes is still refused: its
    # branch is a fact about a tree the operator did not offer, and its changed
    # files would name paths this daemon is obliged to refuse.
    #
    # "/" is the sentinel for "the served root itself", because an empty line
    # and no line at all are indistinguishable through a command substitution,
    # and it is the one byte a path component can never contain.
    _hit=$(
        logical_roots | while IFS="$TAB" read -r _lg _rs; do
            [ -n "$_rs" ] || continue
            case "$_top" in
                "$_rs")
                    printf '%s\n' "${_lg:-/}"
                    break
                    ;;
                "$_rs"/*)
                    _sub="${_top#"$_rs"/}"
                    if [ -n "$_lg" ]; then
                        printf '%s/%s\n' "$_lg" "$_sub"
                    else
                        printf '%s\n' "$_sub"
                    fi
                    break
                    ;;
            esac
        done
    )
    [ -n "$_hit" ] || return 1
    if [ "$_hit" = "/" ]; then
        printf '\n'
    else
        printf '%s\n' "$_hit"
    fi
}

# git_branch <repodir> -- prints "<detached>TAB<name>": false and the branch
# name, or true and the short sha when HEAD is detached.
#
# Both facts come back on stdout rather than one of them in a global, because
# every caller here is a command substitution and a subshell cannot write its
# parent's variables -- a global would read as empty at exactly the point jq
# demands a boolean. An unborn HEAD (a fresh repo, no commit) has a symbolic ref
# and no sha, so it reports its branch name and fails the base lookup below
# rather than here.
git_branch() {
    _b=$(git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    if [ -n "$_b" ]; then
        printf 'false\t%s\n' "$_b"
        return 0
    fi
    printf 'true\t%s\n' "$(git -C "$1" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
}

# git_branch_name <repodir> -- just the name half, for a caller that does not
# care whether HEAD is attached.
git_branch_name() {
    _bi=$(git_branch "$1")
    printf '%s\n' "${_bi#*"$TAB"}"
}

# git_base_ref <repodir> -- the ref the comparison will actually use.
#
# Local heads only, never origin/*: a remote-tracking ref is as stale as the
# last fetch, and a panel that quietly compares against a week-old idea of the
# base is worse than one that says the base is missing. "master" is tried after
# the configured name so a repo that predates the rename still gets a panel.
git_base_ref() {
    for _r in "$GIT_BASE" master; do
        [ -n "$_r" ] || continue
        if git -C "$1" rev-parse --verify --quiet "refs/heads/$_r" >/dev/null 2>&1; then
            printf '%s\n' "$_r"
            return 0
        fi
    done
    return 1
}

# git_changed <repodir> <mergebase> -- prints "<status>\t<path>" per changed
# file, paths relative to the repo root.
#
# --no-renames on purpose. Rename detection emits a third field and a similarity
# score, which the two-field parse below would have to special-case; and in a
# panel whose rows are per-file diffs, "the old path was deleted, the new one
# added" is both true and separately clickable, where one R row hides half of
# what changed behind a name you can no longer open.
#
# Untracked files are appended as A, and always with --exclude-standard even
# when AGENT_BUS_FS_GITIGNORE is off. An ignored file is not a change to the
# branch -- it is a build output -- and a node_modules that would drown the
# panel in ten thousand rows is not made more relevant by the operator having
# opted to serve it.
git_changed() {
    git_bounded git -C "$1" diff --name-status --no-renames "$2" -- 2>/dev/null || true
    git_bounded git -C "$1" ls-files --others --exclude-standard 2>/dev/null |
        while IFS= read -r _o; do
            [ -n "$_o" ] || continue
            printf 'A\t%s\n' "$_o"
        done
}

# git_meta_json <repodir> <logical repo path> -- resolves branch and base and
# prints them as a JSON object, or an object carrying only "baseerr" when there
# is nothing to compare against. Shared by both ops so a diff can never be
# taken against a base the panel above it disagrees with.
git_meta_json() {
    _rdir="$1"
    _rp="$2"
    _bi=$(git_branch "$_rdir")
    GIT_DETACHED="${_bi%%"$TAB"*}"
    _br="${_bi#*"$TAB"}"
    if ! _bs=$(git_base_ref "$_rdir"); then
        jq -n --arg repo "$_rp" --arg branch "$_br" --arg want "$GIT_BASE" \
            --argjson detached "$GIT_DETACHED" '
            {repo: $repo, branch: $branch, detached: $detached, base: null,
             baseerr: ("no " + $want + " branch in this repo to compare against")}'
        return 0
    fi
    _mb=$(git_bounded git -C "$_rdir" merge-base "$_bs" HEAD 2>/dev/null || true)
    if [ -z "$_mb" ]; then
        # Unrelated histories, or a HEAD with no commit behind it yet.
        jq -n --arg repo "$_rp" --arg branch "$_br" --arg bs "$_bs" \
            --argjson detached "$GIT_DETACHED" '
            {repo: $repo, branch: $branch, detached: $detached, base: $bs,
             baseerr: ($branch + " and " + $bs + " share no history")}'
        return 0
    fi
    jq -n --arg repo "$_rp" --arg branch "$_br" --arg bs "$_bs" --arg mb "$_mb" \
        --argjson detached "$GIT_DETACHED" '
        {repo: $repo, branch: $branch, detached: $detached, base: $bs,
         mergebase: $mb, baseerr: null}'
}

# do_git_repos <rid> <logical> <dir> -- the reply for a directory that is in no
# repo, which on a multi-repo root is the root itself. Direct children only:
# one level is what makes it a menu of branches rather than a recursive crawl,
# and a repo nested deeper is reached by clicking into it.
do_git_repos() {
    _rid="$1"
    _logical="$2"
    _dir="$3"
    _rows=""
    for _e in "$_dir"/*; do
        [ -d "$_e" ] || continue
        [ -e "$_e/.git" ] || continue
        _n="${_e##*/}"
        case "$_logical" in
            "") _rp="$_n" ;;
            *) _rp="$_logical/$_n" ;;
        esac
        _br=$(git_branch_name "$_e")
        _cnt=""
        if _bs=$(git_base_ref "$_e"); then
            _mb=$(git_bounded git -C "$_e" merge-base "$_bs" HEAD 2>/dev/null || true)
            if [ -n "$_mb" ]; then
                # The same filter the listing applies, so a repo cannot
                # advertise six changes and then show five: a path git had to
                # quote is unlistable, and counting it here would make the
                # menu disagree with the panel it leads to.
                _cnt=$(git_changed "$_e" "$_mb" | cut -f2 | grep -cv '^"' || true)
            fi
        fi
        # Tab-separated and newline-joined, then split in jq: a repo directory
        # name containing either would be dropped rather than shifting every
        # field after it, the same rule the listing applies.
        _rows="$_rows$_rp$TAB$_br$TAB$_cnt$NL"
    done
    printf '%s' "$_rows" | jq -R -s \
        --arg rid "$_rid" --arg agent "$ME" --arg path "$_logical" '
        (split("\n") | map(select(length > 0)) | map(split("\t"))
         | map(select(length == 3))
         | map({path: .[0], branch: .[1],
                changed: (.[2] | if . == "" then null else tonumber? end)})
         | sort_by(.path | ascii_downcase)) as $repos
        | {body: ("git: " + ($repos | length | tostring) + " repos under "
                  + (if $path == "" then "." else $path end)),
           meta: {kind: "fs.rsp", rid: $rid, agent: $agent, ok: true,
                  op: "git", path: $path, repo: null, repos: $repos}}' |
        publish_rsp
}

# do_git <rid> <logical> <resolved>
do_git() {
    _rid="$1"
    _logical="$2"
    _real="$3"
    [ -n "$GIT_BIN" ] || {
        reply_error "$_rid" "git is not installed on this box"
        return
    }
    if [ -d "$_real" ]; then
        _dir="$_real"
        _dlog="$_logical"
    else
        _dir=$(dirname -- "$_real")
        case "$_logical" in
            */*) _dlog="${_logical%/*}" ;;
            *) _dlog="" ;;
        esac
    fi
    if ! _repo=$(git_repo_root "$_dir"); then
        do_git_repos "$_rid" "$_dlog" "$_dir"
        return
    fi
    if [ -n "$_repo" ]; then
        _rdir="$ROOT/$_repo"
    else
        _rdir="$ROOT"
    fi
    _info=$(git_meta_json "$_rdir" "$_repo")
    if [ -z "$_info" ]; then
        reply_error "$_rid" "could not read git state for ${_repo:-the served root}"
        return
    fi
    if [ "$(printf '%s' "$_info" | jq -r '.baseerr // empty')" != "" ]; then
        printf '%s' "$_info" | jq \
            --arg rid "$_rid" --arg agent "$ME" --arg path "$_logical" '
            . as $i
            | {body: ("git: " + $i.branch + " — " + $i.baseerr),
               meta: {kind: "fs.rsp", rid: $rid, agent: $agent, ok: true,
                      op: "git", path: $path, repo: $i.repo, branch: $i.branch,
                      detached: $i.detached, base: $i.base, baseerr: $i.baseerr,
                      files: []}}' |
            publish_rsp
        return
    fi
    _mb=$(printf '%s' "$_info" | jq -r '.mergebase')
    _changed=$(git_changed "$_rdir" "$_mb")

    printf '%s' "$_changed" | jq -R -s \
        --arg rid "$_rid" --arg agent "$ME" --arg path "$_logical" \
        --argjson info "$_info" --argjson max "$MAX_ENTRIES" \
        --arg prefix "${_repo:+$_repo/}" '
        (split("\n") | map(select(length > 0))) as $lines
        # A path git had to quote (one holding a tab, a newline or a control
        # character) arrives wrapped in double quotes and C-escaped, so the
        # name in it is not the name on disk and clicking it would 404. Dropped
        # rather than mangled -- but counted, because a panel that silently
        # omits a changed file is the one thing worse than one that says it did.
        | ($lines | map(split("\t")) | map(select(length == 2))) as $rows
        | ($rows | map(select((.[1] | startswith("\"")) | not))) as $ok
        | (($lines | length) - ($ok | length)) as $skipped
        | ($ok | map({status: .[0][0:1], rel: .[1], path: ($prefix + .[1])})
               | sort_by(.rel | ascii_downcase)) as $all
        | ($all | length > $max) as $trunc
        | {body: ("git: " + $info.branch + ", "
                  + ($all | length | tostring) + " file(s) vs " + $info.base),
           meta: {kind: "fs.rsp", rid: $rid, agent: $agent, ok: true,
                  op: "git", path: $path, repo: $info.repo,
                  branch: $info.branch, detached: $info.detached,
                  base: $info.base, mergebase: $info.mergebase,
                  files: $all[0:$max], trunc: $trunc, skipped: $skipped}}' |
        publish_rsp
}

# do_gitdiff <rid> <logical>
#
# Takes the logical path itself rather than a resolved one, because a DELETED
# file is exactly the interesting case and safe_path insists on existence. That
# is safe here only because the path never reaches open(2): it is used solely as
# a git pathspec inside a repo whose root has already been proved to sit under
# the served root, and git resolves a pathspec against its own index and trees
# rather than by walking the filesystem. A ".." component is still refused, and
# the file is still put through the .gitignore rule whenever it exists on disk.
do_gitdiff() {
    _rid="$1"
    _logical="$2"
    [ -n "$GIT_BIN" ] || {
        reply_error "$_rid" "git is not installed on this box"
        return
    }
    if ! _full=$(safe_logical "$_logical"); then
        reply_error "$_rid" "no such path under the served root: $_logical"
        return
    fi
    if [ -e "$_full" ] && _why=$(path_excluded "$_full"); then
        reply_error "$_rid" "$_why"
        return
    fi
    # Walk up to the nearest directory that still exists: a file deleted along
    # with its directory has no dirname to ask about.
    _dir=$(dirname -- "$_full")
    while [ ! -d "$_dir" ]; do
        case "$_dir" in
            "$ROOT" | "$ROOT"/*) ;;
            *) break ;;
        esac
        _dir=$(dirname -- "$_dir")
    done
    if [ ! -d "$_dir" ] || ! _repo=$(git_repo_root "$_dir"); then
        reply_error "$_rid" "$_logical is not inside a repo"
        return
    fi
    if [ -n "$_repo" ]; then
        _rdir="$ROOT/$_repo"
        _rel="${_full#"$ROOT/$_repo/"}"
    else
        _rdir="$ROOT"
        _rel="${_full#"$ROOT/"}"
    fi
    _info=$(git_meta_json "$_rdir" "$_repo")
    if [ -z "$_info" ]; then
        reply_error "$_rid" "could not read git state for ${_repo:-the served root}"
        return
    fi
    _be=$(printf '%s' "$_info" | jq -r '.baseerr // empty')
    if [ -n "$_be" ]; then
        reply_error "$_rid" "$_be"
        return
    fi
    _base=$(printf '%s' "$_info" | jq -r '.base')
    _mb=$(git_bounded git -C "$_rdir" merge-base "$_base" HEAD 2>/dev/null || true)
    [ -n "$_mb" ] || {
        reply_error "$_rid" "cannot resolve a merge base with $_base"
        return
    }

    _st=$(git_bounded git -C "$_rdir" diff --name-status --no-renames "$_mb" -- "$_rel" 2>/dev/null |
        head -n 1 | cut -f1 | cut -c1)
    # One byte past the limit, so that "did it fit" is answerable without
    # holding a 40 MB diff in a shell variable to find out. The SIGPIPE head
    # induces at the cap is why every one of these ends in `|| true`.
    _cap=$((MAX_INLINE + 1))
    _diff=$(git_bounded git -C "$_rdir" diff "$_mb" -- "$_rel" 2>/dev/null |
        head -c "$_cap" || true)
    _untracked=false
    # Only now, and only for a path git has never heard of. An untracked file is
    # in no tree, so the diff above has nothing to say about it; --no-index
    # against /dev/null renders it as the wholly-added file it is, exiting 1
    # because the two differ, which here is the expected outcome.
    #
    # Both halves of the test are needed. Asking the index alone ("is it
    # tracked?") calls a `git rm`-ed file untracked -- it left the index too --
    # and answers an empty --no-index diff for the deletion that is the whole
    # reason this op takes a lexical path.
    if [ -z "$_diff" ] && [ -f "$_full" ] &&
        ! git -C "$_rdir" ls-files --error-unmatch -- "$_rel" >/dev/null 2>&1 &&
        ! git -C "$_rdir" cat-file -e "$_mb:$_rel" 2>/dev/null; then
        _untracked=true
        _st=A
        _diff=$(git_bounded git -C "$_rdir" diff --no-index -- /dev/null "$_rel" 2>/dev/null |
            head -c "$_cap" || true)
    fi

    _trunc=false
    if [ "${#_diff}" -gt "$MAX_INLINE" ]; then
        # Cut back to a line boundary: half a diff line renders as a phantom
        # change, and a trailing "+" with nothing after it reads as a bug.
        _diff=$(printf '%s\n' "$_diff" | sed '$d')
        _trunc=true
    fi

    # Spooled rather than passed, for the MAX_ARG_STRLEN reason spelt out in
    # do_read: a diff is exactly the kind of payload that clears 128 KiB, and
    # the failure is a silent one.
    _dtmp=$(mktemp "${TMPDIR:-/tmp}/agent-bus-fsd-diff.XXXXXX") || {
        reply_error "$_rid" "mktemp failed"
        return
    }
    printf '%s' "$_diff" >"$_dtmp"

    printf '%s' "$_info" | jq \
        --arg rid "$_rid" --arg agent "$ME" --arg path "$_logical" \
        --arg rel "$_rel" --arg st "$_st" --rawfile diff "$_dtmp" \
        --argjson untracked "$_untracked" --argjson trunc "$_trunc" '
        . as $i
        | {body: ("git diff " + $path + " vs " + $i.base
                  + (if $diff == "" then " (identical)" else "" end)),
           meta: {kind: "fs.rsp", rid: $rid, agent: $agent, ok: true,
                  op: "gitdiff", path: $path, repo: $i.repo, rel: $rel,
                  branch: $i.branch, base: $i.base, mergebase: $i.mergebase,
                  status: (if $st == "" then null else $st end),
                  untracked: $untracked, diff: $diff, trunc: $trunc}}' |
        publish_rsp
    rm -f "$_dtmp"
}

# --- Dispatch ---------------------------------------------------------------

# handle_request <message-json>
handle_request() {
    _msg="$1"
    _kind=$(printf '%s' "$_msg" | jq -r '.meta.kind // empty' 2>/dev/null || true)
    case "$_kind" in
        fs.list | fs.read | fs.ping | fs.grep | fs.git | fs.gitdiff) ;;
        *) return 0 ;;
    esac
    # Case-insensitive: agents.json capitalises names, humans rarely do.
    _target=$(printf '%s' "$_msg" | jq -r '.meta.agent // empty' | tr '[:upper:]' '[:lower:]')
    _lm=$(printf '%s' "$ME" | tr '[:upper:]' '[:lower:]')
    [ "$_target" = "$_lm" ] || return 0

    _rid=$(printf '%s' "$_msg" | jq -r '.meta.rid // empty')
    [ -n "$_rid" ] || return 0
    _path=$(printf '%s' "$_msg" | jq -r '.meta.path // ""')

    _query=$(printf '%s' "$_msg" | jq -r '.meta.query // ""')
    _regex=$(printf '%s' "$_msg" | jq -r 'if .meta.regex == true then "true" else "false" end')

    if [ "$_kind" = "fs.grep" ]; then
        log "$_kind ${_path:-.} q=$_query (rid $_rid)"
    else
        log "$_kind ${_path:-.} (rid $_rid)"
    fi

    if [ "$_kind" = "fs.ping" ]; then
        do_ping "$_rid"
        return 0
    fi

    # Ahead of safe_path, which would refuse the deleted file that is the whole
    # point of asking for a diff. do_gitdiff does its own containment.
    if [ "$_kind" = "fs.gitdiff" ]; then
        do_gitdiff "$_rid" "$_path"
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
        fs.grep) do_grep "$_rid" "$_path" "$_real" "$_query" "$_regex" ;;
        fs.git) do_git "$_rid" "$_path" "$_real" ;;
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
        _connected_at=$(date +%s)
        watch_once || true
        if [ "$ONCE" = "1" ]; then
            return 0
        fi
        # Reset after a connection that actually lasted, or the backoff is a
        # one-way ratchet: it only ever climbs, so a bad hour last week pins
        # every reconnect since at the cap, and a routine bus restart today
        # costs 30s of silence instead of 1s. Silence is the entire cost --
        # while this daemon is off the stream the bus drops nudges to absent
        # subscribers with no queue, no retry and no log line anywhere, so a
        # Files-tab click simply ceases to exist until the UI's 20s timeout.
        # Duration rather than "we read a line", because a rejected connection
        # still writes its error body into the FIFO: counting lines would read
        # a 401 as success and reconnect at 1s forever.
        if [ "$(($(date +%s) - _connected_at))" -ge 60 ]; then
            _backoff=1
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
    if [ -n "$TIMEOUT_BIN" ]; then
        printf 'search  : %s, bounded at %ss\n' "$(grep_engine)" "$GREP_TIMEOUT"
    else
        printf 'search  : %s, UNBOUNDED (no timeout(1) on PATH)\n' "$(grep_engine)"
    fi
    if [ -n "$RG_BIN" ] && [ "$RG_OK" != 1 ]; then
        printf '          WARNING: %s exists but failed the output-format probe\n' "$RG_BIN"
    fi
        printf 'git     : base %s, bounded at %ss\n' "$GIT_BASE" "$GIT_TIMEOUT"
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
