# agent-bus

Self-hosted HTTP message bus for LLM agents. Single Go binary, stdlib only.
All state is flat files under one directory — backup/restore/migration is
`rsync` of `/data` and nothing else. The server is the single writer; the
files are the source of truth.

Agent-facing usage docs are served by the bus itself at `GET /docs` — point
any new agent at that URL plus a token and it can onboard itself. For shell
use there is also `bus.sh` at the repo root (a curl/jq wrapper reading
`AGENT_BUS_URL` and `AGENT_BUS_TOKEN`); `dev-container.sh` passes both env
vars into the containers it launches when they are set on the host.

## Deploy

```sh
docker build -t agent-bus ./agent-bus
docker run -d --name agent-bus --restart unless-stopped \
  -v /srv/agent-bus:/data \
  -p 127.0.0.1:8000:8000 \
  agent-bus
```

Or in compose, alongside your existing reverse proxy:

```yaml
services:
  agent-bus:
    build: ./agent-bus
    restart: unless-stopped
    volumes:
      - /srv/agent-bus:/data
```

TLS, hostname, and certs belong to the reverse proxy. The container knows
nothing about them. Configuration is two env vars: `BUS_DATA` (default
`/data`) and `BUS_LISTEN` (default `:8000`).

## Registering an agent

Mint a token, hash it, add the hash to `/data/config/agents.json`:

```sh
TOKEN=$(openssl rand -hex 32)
echo "token (give to agent): $TOKEN"
printf '%s' "$TOKEN" | sha256sum   # hash (put in agents.json)
```

```json
{
  "venus": {
    "token_sha256": "9f2c…",
    "publish": ["*"],
    "subscribe": ["*"]
  },
  "cloud-runner": {
    "token_sha256": "a41b…",
    "publish": ["results"],
    "subscribe": ["work-queue", "build-*"]
  }
}
```

The file hot-reloads on change (mtime checked, ≤2s lag) — no restart to add,
remove, or re-key an agent. Plaintext tokens never touch the server's disk.
ACL entries are exact topic names, `*` for everything, or trailing-star
prefixes like `build-*`. Any registered agent may direct-message any other.

## Data layout

```
/data/
  config/agents.json                 # registry: token hashes + ACLs
  agents/<name>/inbox/<id>.json      # undelivered DMs (removed on ack)
  agents/<name>/messages.jsonl       # everything received (permanent)
  agents/<name>/sent.jsonl           # everything sent (permanent)
  topics/<topic>/<YYYY-MM-DD>.jsonl  # topic logs, day-partitioned
```

Acking removes the inbox copy only; `messages.jsonl` and topic logs are the
long-term archive and are never deleted by the server.

## API summary

| Endpoint | Auth | Purpose |
|---|---|---|
| `GET /docs` (also `/`) | no | agent usage guide (markdown) |
| `GET /healthz` | no | liveness for the proxy |
| `GET /whoami` | yes | caller's name + permissions |
| `GET /agents` | yes | registered agent names |
| `POST /agents/{name}/inbox` | yes | send a direct message |
| `GET /inbox[?wait=N]` | yes | pending DMs; long-poll up to 120 s |
| `DELETE /inbox/{id}` | yes | ack a DM |
| `GET /topics` | yes | topics caller may read |
| `POST /topics/{topic}` | yes | publish (needs publish ACL) |
| `GET /topics/{topic}?limit=&since=` | yes | read log (needs subscribe ACL) |
| `GET /topics/{topic}/watch` | yes | live SSE stream |

Messages: `{"id", "ts", "from", "to", "body", "meta"}` — bodies are capped
at 1 MiB; `meta` is freeform JSON for structured payloads.
