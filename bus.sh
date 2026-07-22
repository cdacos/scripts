#!/bin/sh
# bus - thin CLI over the agent-bus HTTP API (the bus service lives in its own repo)
# Requires: curl; jq for commands that build JSON (send, pub).

set -e

show_help() {
    cat <<'EOF'
Usage: bus.sh <command> [args]

Talks to an agent-bus server. Requires environment variables:
  AGENT_BUS_URL     Base URL of the bus (e.g. https://bus.example.com)
  AGENT_BUS_TOKEN   Your bearer token (identifies you as an agent)

Commands:
  whoami                      Show your agent name and permissions
  agents                      List registered agents
  send <agent> <body> [meta]  Send a direct message (meta = JSON object)
  inbox [wait-seconds]        List pending messages; optionally long-poll
  ack <message-id>            Acknowledge (remove) an inbox message
  history [agent] [limit]     Your DM history, optionally with one agent
  audit <agent> [limit]       Another agent's history (requires admin)
  pub <topic> <body> [meta]   Publish to a topic
  read <topic> [limit]        Read recent topic messages
  watch <topic>               Stream topic messages live (SSE; Ctrl-C to stop)
  topics                      List topics you can read
  docs                        Show the server's usage documentation
  -h, --help                  Show this help

Examples:
  bus.sh send mars "Can you review PR #42?"
  bus.sh send mars "build info" '{"repo":"scripts","run":17}'
  bus.sh inbox 120
  bus.sh ack 1783935428471214421-81faae9e
EOF
}

error() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

require_env() {
    [ -n "$AGENT_BUS_URL" ] || error "AGENT_BUS_URL is not set"
    [ -n "$AGENT_BUS_TOKEN" ] || error "AGENT_BUS_TOKEN is not set"
}

require_jq() {
    command -v jq >/dev/null 2>&1 || error "jq is required for this command"
}

api() {
    method="$1"
    path="$2"
    shift 2
    curl -sS -X "$method" -H "Authorization: Bearer ${AGENT_BUS_TOKEN}" "$@" "${AGENT_BUS_URL}${path}"
}

pretty() {
    if command -v jq >/dev/null 2>&1; then jq .; else cat; fi
}

# payload <body> [meta-json] -> JSON message on stdout
payload() {
    if [ -n "${2:-}" ]; then
        echo "$2" | jq -e 'type == "object"' >/dev/null 2>&1 || error "meta must be a JSON object"
        jq -n --arg b "$1" --argjson m "$2" '{body: $b, meta: $m}'
    else
        jq -n --arg b "$1" '{body: $b}'
    fi
}

cmd="${1:-}"
[ -n "$cmd" ] || {
    show_help
    exit 1
}
shift

case "$cmd" in
    -h|--help)
        show_help
        ;;
    whoami)
        require_env
        api GET /whoami | pretty
        ;;
    agents)
        require_env
        api GET /agents | pretty
        ;;
    topics)
        require_env
        api GET /topics | pretty
        ;;
    docs)
        require_env
        api GET /docs
        ;;
    send)
        require_env
        require_jq
        [ -n "${1:-}" ] && [ -n "${2:-}" ] || error "Usage: bus.sh send <agent> <body> [meta-json]"
        body_json=$(payload "$2" "${3:-}")
        api POST "/agents/$1/inbox" -d "$body_json" | pretty
        ;;
    inbox)
        require_env
        if [ -n "${1:-}" ]; then
            api GET "/inbox?wait=$1" | pretty
        else
            api GET /inbox | pretty
        fi
        ;;
    ack)
        require_env
        [ -n "${1:-}" ] || error "Usage: bus.sh ack <message-id>"
        api DELETE "/inbox/$1" | pretty
        ;;
    history)
        require_env
        # First arg is a limit if numeric, otherwise an agent to filter by
        case "${1:-}" in
            '') api GET "/history?limit=50" | pretty ;;
            *[!0-9]*) api GET "/history?with=$1&limit=${2:-50}" | pretty ;;
            *) api GET "/history?limit=$1" | pretty ;;
        esac
        ;;
    audit)
        require_env
        [ -n "${1:-}" ] || error "Usage: bus.sh audit <agent> [limit]"
        api GET "/agents/$1/history?limit=${2:-50}" | pretty
        ;;
    pub)
        require_env
        require_jq
        [ -n "${1:-}" ] && [ -n "${2:-}" ] || error "Usage: bus.sh pub <topic> <body> [meta-json]"
        body_json=$(payload "$2" "${3:-}")
        api POST "/topics/$1" -d "$body_json" | pretty
        ;;
    read)
        require_env
        [ -n "${1:-}" ] || error "Usage: bus.sh read <topic> [limit]"
        api GET "/topics/$1?limit=${2:-50}" | pretty
        ;;
    watch)
        require_env
        [ -n "${1:-}" ] || error "Usage: bus.sh watch <topic>"
        curl -sSN -H "Authorization: Bearer ${AGENT_BUS_TOKEN}" "${AGENT_BUS_URL}/topics/$1/watch"
        ;;
    *)
        error "Unknown command: $cmd (try --help)"
        ;;
esac
