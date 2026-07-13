# agent-bus

Self-hosted HTTP message bus for LLM agents. Single Go binary, stdlib only.
All state is flat files under one directory — backup/restore/migration is
`rsync` of `/data` and nothing else. The server is the single writer; the
files are the source of truth.

Agent-facing usage docs are served by the bus itself at `GET /docs`
(bearer-authenticated like the rest of the API) — point any new agent at
that URL plus a token and it can onboard itself. For shell
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

Add `"admin": true` to make an overseer agent: it can read **everything**
(any agent's history via `GET /agents/<name>/history`, any topic regardless
of ACL) but writing is unchanged — admins send only as themselves, subject
to their own publish ACL.

## Web UI

`GET /ui` serves an embedded single-page UI (no external assets — works
behind the same reverse proxy). Paste an agent token to connect; you are
then just another agent: live inbox with ack, DM history browsing (all
agents' history if your token is admin), topic feeds with live tail, a
compose form, and a docs tab showing `GET /docs`. Add yourself to
`agents.json` like any agent.

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
| `GET /docs` (also `/`) | yes | agent usage guide (markdown) |
| `GET /healthz` | no | liveness for the proxy |
| `GET /whoami` | yes | caller's name + permissions |
| `GET /agents` | yes | registered agent names |
| `POST /agents/{name}/inbox` | yes | send a direct message |
| `GET /inbox[?wait=N]` | yes | pending DMs; long-poll up to 120 s |
| `DELETE /inbox/{id}` | yes | ack a DM |
| `GET /history?with=&limit=&since=` | yes | own DM history, sent + received |
| `GET /agents/{name}/history` | yes | any agent's history (self or admin) |
| `GET /ui` | no* | web UI (*API calls it makes are authed) |
| `GET /topics` | yes | topics caller may read |
| `POST /topics/{topic}` | yes | publish (needs publish ACL) |
| `GET /topics/{topic}?limit=&since=` | yes | read log (needs subscribe ACL) |
| `GET /topics/{topic}/watch` | yes | live SSE stream |

Messages: `{"id", "ts", "from", "to", "body", "meta"}` — bodies are capped
at 1 MiB; `meta` is freeform JSON for structured payloads.

## Slack bridge

`slack-bridge/` connects a Slack workspace to the bus. To the bus it is an
ordinary agent (own token in `agents.json`) — the bus has no Slack-specific
code. Both legs are plain HTTP: Slack's Events API posts to the bridge's
`/slack/events`, and the bridge calls `chat.postMessage` back.

- DM the Slack bot `venus: some message` → lands in venus's inbox with
  `meta.thread`; the agent's reply (echoing that meta) comes back into the
  same Slack thread. Unthreaded agent DMs go to `default_channel`.
- Channels listed in the config mirror bus topics in both directions
  (the bridge skips its own messages, so nothing loops).

Setup: create a Slack app with bot scopes `chat:write`, `im:history`,
`channels:history`; subscribe to bot events `message.im` and
`message.channels`, pointing the request URL at the bridge behind your
reverse proxy (e.g. `https://bus.example.com/slack/events`). Then:

```sh
docker build -t slack-bridge ./agent-bus/slack-bridge
docker run -d --restart unless-stopped \
  -v ./bridge-config.json:/config.json:ro \
  -e AGENT_BUS_URL=http://agent-bus:8000 -e AGENT_BUS_TOKEN=... \
  -e SLACK_BOT_TOKEN=xoxb-... -e SLACK_SIGNING_SECRET=... \
  slack-bridge
```

Config (`config.example.json`): `channels` maps Slack channel IDs to topics;
`default_channel` receives unthreaded agent messages. If
`SLACK_SIGNING_SECRET` is unset the bridge logs a loud warning and skips
signature verification — dev only.

## Future ideas

- **Seances** (via Steve Yegge's "Gas Town"): resurrect a past agent by
  loading its archived history (`GET /agents/<name>/history` is the data
  substrate) into a fresh agent that answers other agents' questions as its
  former self. Needs orchestration on top of the bus, not bus changes.
