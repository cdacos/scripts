// agent-bus: self-hosted message bus for LLM agents.
//
// All state lives on the filesystem under BUS_DATA (default /data):
//
//	config/agents.json                 agent registry: token hashes + topic ACLs
//	agents/<name>/inbox/<id>.json      undelivered direct messages (removed on ack)
//	agents/<name>/messages.jsonl       every message received (durable history)
//	agents/<name>/sent.jsonl           every message sent
//	topics/<topic>/<YYYY-MM-DD>.jsonl  topic logs, day-partitioned
//
// The server is the single writer; files are the source of truth. TLS and
// hostname are the reverse proxy's problem. Agent-facing usage docs are
// served at GET /docs (and /).
package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Fixed-width UTC timestamp so string comparison equals time comparison.
const tsFormat = "2006-01-02T15:04:05.000000000Z"

const maxBodyBytes = 1 << 20 // 1 MiB per message
const maxWaitSecs = 120

var nameRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$`)
var msgIDRe = regexp.MustCompile(`^[0-9]{19}-[a-f0-9]{8}$`)

type Message struct {
	ID   string         `json:"id"`
	TS   string         `json:"ts"`
	From string         `json:"from"`
	To   string         `json:"to"`
	Body string         `json:"body"`
	Meta map[string]any `json:"meta,omitempty"`
}

type AgentConfig struct {
	TokenSHA256 string   `json:"token_sha256"`
	Publish     []string `json:"publish"`
	Subscribe   []string `json:"subscribe"`
}

type Config map[string]AgentConfig

// pubsub is the in-memory notification layer for long-poll and SSE.
// Durable delivery never depends on it: messages are on disk before publish.
type pubsub struct {
	mu   sync.Mutex
	subs map[string]map[chan Message]struct{}
}

func newPubsub() *pubsub {
	return &pubsub{subs: map[string]map[chan Message]struct{}{}}
}

func (p *pubsub) subscribe(key string) chan Message {
	ch := make(chan Message, 16)
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.subs[key] == nil {
		p.subs[key] = map[chan Message]struct{}{}
	}
	p.subs[key][ch] = struct{}{}
	return ch
}

func (p *pubsub) unsubscribe(key string, ch chan Message) {
	p.mu.Lock()
	defer p.mu.Unlock()
	delete(p.subs[key], ch)
	if len(p.subs[key]) == 0 {
		delete(p.subs, key)
	}
}

func (p *pubsub) publish(key string, m Message) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for ch := range p.subs[key] {
		select {
		case ch <- m:
		default: // slow subscriber: drop the nudge; disk has the message
		}
	}
}

type server struct {
	dataDir string

	cfgMu      sync.Mutex
	cfg        Config
	cfgMtime   time.Time
	cfgChecked time.Time

	locks sync.Map // file path -> *sync.Mutex
	bus   *pubsub
}

// config returns the agent registry, hot-reloading agents.json when its
// mtime changes (checked at most every 2s).
func (s *server) config() Config {
	s.cfgMu.Lock()
	defer s.cfgMu.Unlock()
	if time.Since(s.cfgChecked) < 2*time.Second {
		return s.cfg
	}
	s.cfgChecked = time.Now()
	path := filepath.Join(s.dataDir, "config", "agents.json")
	fi, err := os.Stat(path)
	if err != nil {
		if s.cfg == nil {
			log.Printf("warning: %s not found; all authenticated requests will fail", path)
			s.cfg = Config{}
		}
		return s.cfg
	}
	if s.cfg != nil && fi.ModTime().Equal(s.cfgMtime) {
		return s.cfg
	}
	b, err := os.ReadFile(path)
	if err != nil {
		log.Printf("error reading %s: %v (keeping previous config)", path, err)
		return s.cfg
	}
	var cfg Config
	if err := json.Unmarshal(b, &cfg); err != nil {
		log.Printf("error parsing %s: %v (keeping previous config)", path, err)
		return s.cfg
	}
	s.cfg = cfg
	s.cfgMtime = fi.ModTime()
	log.Printf("loaded config: %d agent(s)", len(cfg))
	return s.cfg
}

func (s *server) authenticate(r *http.Request) (string, *AgentConfig) {
	tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok {
		return "", nil
	}
	sum := sha256.Sum256([]byte(strings.TrimSpace(tok)))
	hexSum := hex.EncodeToString(sum[:])
	for name, ac := range s.config() {
		if subtle.ConstantTimeCompare([]byte(strings.ToLower(ac.TokenSHA256)), []byte(hexSum)) == 1 {
			acCopy := ac
			return name, &acCopy
		}
	}
	return "", nil
}

func matchACL(patterns []string, name string) bool {
	for _, p := range patterns {
		if p == "*" || p == name {
			return true
		}
		if prefix, ok := strings.CutSuffix(p, "*"); ok && strings.HasPrefix(name, prefix) {
			return true
		}
	}
	return false
}

func newID() string {
	var b [4]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return fmt.Sprintf("%019d-%s", time.Now().UnixNano(), hex.EncodeToString(b[:]))
}

func now() string {
	return time.Now().UTC().Format(tsFormat)
}

// lock serializes writes to a single file path.
func (s *server) lock(key string) func() {
	v, _ := s.locks.LoadOrStore(key, &sync.Mutex{})
	m := v.(*sync.Mutex)
	m.Lock()
	return m.Unlock
}

func (s *server) appendJSONL(path string, m Message) error {
	defer s.lock(path)()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	_, err = f.Write(append(b, '\n'))
	return err
}

// writeInboxFile durably stores an undelivered message: write temp, atomic rename.
func (s *server) writeInboxFile(agent string, m Message) error {
	dir := filepath.Join(s.dataDir, "agents", agent, "inbox")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	tmp := filepath.Join(dir, "."+m.ID+".tmp")
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(dir, m.ID+".json"))
}

func (s *server) readInbox(agent string) ([]Message, error) {
	dir := filepath.Join(s.dataDir, "agents", agent, "inbox")
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return []Message{}, nil
		}
		return nil, err
	}
	names := []string{}
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".json") && !strings.HasPrefix(e.Name(), ".") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names) // IDs are time-prefixed, so this is chronological
	msgs := []Message{}
	for _, n := range names {
		b, err := os.ReadFile(filepath.Join(dir, n))
		if err != nil {
			continue
		}
		var m Message
		if err := json.Unmarshal(b, &m); err != nil {
			continue
		}
		msgs = append(msgs, m)
	}
	return msgs, nil
}

// --- HTTP plumbing ---

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func jsonErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

type authedHandler func(w http.ResponseWriter, r *http.Request, caller string, ac *AgentConfig)

func (s *server) auth(h authedHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		caller, ac := s.authenticate(r)
		if ac == nil {
			jsonErr(w, http.StatusUnauthorized, "missing or invalid bearer token; see GET /docs")
			return
		}
		h(w, r, caller, ac)
	}
}

type sendRequest struct {
	Body string         `json:"body"`
	Meta map[string]any `json:"meta,omitempty"`
}

func decodeSend(w http.ResponseWriter, r *http.Request) (*sendRequest, bool) {
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	var req sendRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonErr(w, http.StatusBadRequest, "invalid JSON body: "+err.Error())
		return nil, false
	}
	if strings.TrimSpace(req.Body) == "" {
		jsonErr(w, http.StatusBadRequest, `"body" is required and must be non-empty`)
		return nil, false
	}
	return &req, true
}

// --- Handlers ---

func (s *server) handleDocs(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/markdown; charset=utf-8")
	w.Write([]byte(docsMarkdown))
}

func (s *server) handleWhoami(w http.ResponseWriter, _ *http.Request, caller string, ac *AgentConfig) {
	writeJSON(w, http.StatusOK, map[string]any{
		"agent":     caller,
		"publish":   ac.Publish,
		"subscribe": ac.Subscribe,
	})
}

func (s *server) handleAgents(w http.ResponseWriter, _ *http.Request, _ string, _ *AgentConfig) {
	names := []string{}
	for name := range s.config() {
		names = append(names, name)
	}
	sort.Strings(names)
	writeJSON(w, http.StatusOK, map[string]any{"agents": names})
}

func (s *server) handleSendDM(w http.ResponseWriter, r *http.Request, caller string, _ *AgentConfig) {
	target := r.PathValue("name")
	if !nameRe.MatchString(target) {
		jsonErr(w, http.StatusBadRequest, "invalid agent name")
		return
	}
	if _, ok := s.config()[target]; !ok {
		jsonErr(w, http.StatusNotFound, "unknown agent: "+target)
		return
	}
	req, ok := decodeSend(w, r)
	if !ok {
		return
	}
	m := Message{ID: newID(), TS: now(), From: caller, To: "agent:" + target, Body: req.Body, Meta: req.Meta}
	if err := s.writeInboxFile(target, m); err != nil {
		jsonErr(w, http.StatusInternalServerError, "storing message: "+err.Error())
		return
	}
	// History appends are best-effort: the inbox copy above is authoritative.
	if err := s.appendJSONL(filepath.Join(s.dataDir, "agents", target, "messages.jsonl"), m); err != nil {
		log.Printf("error appending history for %s: %v", target, err)
	}
	if err := s.appendJSONL(filepath.Join(s.dataDir, "agents", caller, "sent.jsonl"), m); err != nil {
		log.Printf("error appending sent log for %s: %v", caller, err)
	}
	s.bus.publish("agent:"+target, m)
	writeJSON(w, http.StatusCreated, map[string]string{"id": m.ID, "ts": m.TS})
}

func (s *server) handleInbox(w http.ResponseWriter, r *http.Request, caller string, _ *AgentConfig) {
	wait, _ := strconv.Atoi(r.URL.Query().Get("wait"))
	if wait > maxWaitSecs {
		wait = maxWaitSecs
	}
	msgs, err := s.readInbox(caller)
	if err != nil {
		jsonErr(w, http.StatusInternalServerError, "reading inbox: "+err.Error())
		return
	}
	if len(msgs) == 0 && wait > 0 {
		key := "agent:" + caller
		ch := s.bus.subscribe(key)
		defer s.bus.unsubscribe(key, ch)
		// Re-check after subscribing to close the race with a concurrent send.
		msgs, err = s.readInbox(caller)
		if err == nil && len(msgs) == 0 {
			select {
			case <-ch:
			case <-time.After(time.Duration(wait) * time.Second):
			case <-r.Context().Done():
				return
			}
			msgs, _ = s.readInbox(caller)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": msgs})
}

func (s *server) handleAck(w http.ResponseWriter, r *http.Request, caller string, _ *AgentConfig) {
	id := r.PathValue("id")
	if !msgIDRe.MatchString(id) {
		jsonErr(w, http.StatusBadRequest, "invalid message id")
		return
	}
	path := filepath.Join(s.dataDir, "agents", caller, "inbox", id+".json")
	if err := os.Remove(path); err != nil {
		if os.IsNotExist(err) {
			jsonErr(w, http.StatusNotFound, "no such message in your inbox")
			return
		}
		jsonErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) handlePublish(w http.ResponseWriter, r *http.Request, caller string, ac *AgentConfig) {
	topic := r.PathValue("topic")
	if !nameRe.MatchString(topic) {
		jsonErr(w, http.StatusBadRequest, "invalid topic name")
		return
	}
	if !matchACL(ac.Publish, topic) {
		jsonErr(w, http.StatusForbidden, "no publish permission for topic: "+topic)
		return
	}
	req, ok := decodeSend(w, r)
	if !ok {
		return
	}
	m := Message{ID: newID(), TS: now(), From: caller, To: "topic:" + topic, Body: req.Body, Meta: req.Meta}
	day := time.Now().UTC().Format("2006-01-02")
	path := filepath.Join(s.dataDir, "topics", topic, day+".jsonl")
	if err := s.appendJSONL(path, m); err != nil {
		jsonErr(w, http.StatusInternalServerError, "storing message: "+err.Error())
		return
	}
	s.bus.publish("topic:"+topic, m)
	writeJSON(w, http.StatusCreated, map[string]string{"id": m.ID, "ts": m.TS})
}

func (s *server) handleTopicRead(w http.ResponseWriter, r *http.Request, _ string, ac *AgentConfig) {
	topic := r.PathValue("topic")
	if !nameRe.MatchString(topic) {
		jsonErr(w, http.StatusBadRequest, "invalid topic name")
		return
	}
	if !matchACL(ac.Subscribe, topic) {
		jsonErr(w, http.StatusForbidden, "no subscribe permission for topic: "+topic)
		return
	}
	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			jsonErr(w, http.StatusBadRequest, "invalid limit")
			return
		}
		limit = min(n, 1000)
	}
	sinceStr := ""
	if v := r.URL.Query().Get("since"); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			jsonErr(w, http.StatusBadRequest, "invalid since (want RFC3339): "+err.Error())
			return
		}
		sinceStr = t.UTC().Format(tsFormat)
	}
	dir := filepath.Join(s.dataDir, "topics", topic)
	files, err := filepath.Glob(filepath.Join(dir, "*.jsonl"))
	if err != nil {
		jsonErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	sort.Strings(files) // day-partitioned names sort chronologically
	msgs := []Message{}
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(b), "\n") {
			if line == "" {
				continue
			}
			var m Message
			if err := json.Unmarshal([]byte(line), &m); err != nil {
				continue
			}
			if sinceStr != "" && m.TS <= sinceStr {
				continue
			}
			msgs = append(msgs, m)
		}
	}
	if len(msgs) > limit {
		msgs = msgs[len(msgs)-limit:]
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": msgs})
}

func (s *server) handleTopics(w http.ResponseWriter, _ *http.Request, _ string, ac *AgentConfig) {
	entries, err := os.ReadDir(filepath.Join(s.dataDir, "topics"))
	if err != nil && !os.IsNotExist(err) {
		jsonErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	topics := []string{}
	for _, e := range entries {
		if e.IsDir() && matchACL(ac.Subscribe, e.Name()) {
			topics = append(topics, e.Name())
		}
	}
	sort.Strings(topics)
	writeJSON(w, http.StatusOK, map[string]any{"topics": topics})
}

func (s *server) handleWatch(w http.ResponseWriter, r *http.Request, _ string, ac *AgentConfig) {
	topic := r.PathValue("topic")
	if !nameRe.MatchString(topic) {
		jsonErr(w, http.StatusBadRequest, "invalid topic name")
		return
	}
	if !matchACL(ac.Subscribe, topic) {
		jsonErr(w, http.StatusForbidden, "no subscribe permission for topic: "+topic)
		return
	}
	fl, ok := w.(http.Flusher)
	if !ok {
		jsonErr(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	fmt.Fprintf(w, ": watching topic %s\n\n", topic)
	fl.Flush()

	key := "topic:" + topic
	ch := s.bus.subscribe(key)
	defer s.bus.unsubscribe(key, ch)
	keepalive := time.NewTicker(25 * time.Second)
	defer keepalive.Stop()
	for {
		select {
		case m := <-ch:
			b, _ := json.Marshal(m)
			fmt.Fprintf(w, "id: %s\ndata: %s\n\n", m.ID, b)
			fl.Flush()
		case <-keepalive.C:
			fmt.Fprint(w, ": keepalive\n\n")
			fl.Flush()
		case <-r.Context().Done():
			return
		}
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	s := &server{
		dataDir: envOr("BUS_DATA", "/data"),
		bus:     newPubsub(),
	}
	listen := envOr("BUS_LISTEN", ":8000")

	for _, d := range []string{"config", "agents", "topics"} {
		if err := os.MkdirAll(filepath.Join(s.dataDir, d), 0o755); err != nil {
			log.Fatalf("creating %s: %v", d, err)
		}
	}
	s.config() // load (or warn) at startup

	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", s.handleDocs)
	mux.HandleFunc("GET /docs", s.handleDocs)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte("ok\n"))
	})
	mux.Handle("GET /whoami", s.auth(s.handleWhoami))
	mux.Handle("GET /agents", s.auth(s.handleAgents))
	mux.Handle("POST /agents/{name}/inbox", s.auth(s.handleSendDM))
	mux.Handle("GET /inbox", s.auth(s.handleInbox))
	mux.Handle("DELETE /inbox/{id}", s.auth(s.handleAck))
	mux.Handle("GET /topics", s.auth(s.handleTopics))
	mux.Handle("POST /topics/{topic}", s.auth(s.handlePublish))
	mux.Handle("GET /topics/{topic}", s.auth(s.handleTopicRead))
	mux.Handle("GET /topics/{topic}/watch", s.auth(s.handleWatch))

	srv := &http.Server{
		Addr:              listen,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		// No Read/WriteTimeout: long-poll and SSE hold connections open.
	}
	log.Printf("agent-bus listening on %s, data in %s", listen, s.dataDir)
	log.Fatal(srv.ListenAndServe())
}

const docsMarkdown = `# Agent Bus — usage guide for agents

You are an agent connected to a self-hosted message bus. Other agents send
you direct messages (your **inbox**) and everyone shares pub/sub **topics**.
All messages are stored durably on the server; acking a message only removes
it from your pending inbox, never from history.

## Authentication

Every endpoint except this page and /healthz requires a bearer token:

    Authorization: Bearer <token>

Your operator gives you the base URL and token, typically as environment
variables AGENT_BUS_URL and AGENT_BUS_TOKEN. Verify your identity first:

    curl -s -H "Authorization: Bearer $AGENT_BUS_TOKEN" "$AGENT_BUS_URL/whoami"
    # -> {"agent":"venus","publish":["*"],"subscribe":["*"]}

List the other agents you can talk to:

    curl -s -H "Authorization: Bearer $AGENT_BUS_TOKEN" "$AGENT_BUS_URL/agents"

## Direct messages

**Send** to another agent (body required, meta optional freeform JSON):

    curl -s -X POST -H "Authorization: Bearer $AGENT_BUS_TOKEN" \
      -d '{"body":"Can you review PR #42?","meta":{"repo":"scripts"}}' \
      "$AGENT_BUS_URL/agents/mars/inbox"

**Check your inbox** (messages remain until you ack them):

    curl -s -H "Authorization: Bearer $AGENT_BUS_TOKEN" "$AGENT_BUS_URL/inbox"

Add "?wait=60" to long-poll: the request blocks up to 60 seconds (max 120)
until a message arrives, then returns immediately.

**Ack** a message after you have processed it:

    curl -s -X DELETE -H "Authorization: Bearer $AGENT_BUS_TOKEN" \
      "$AGENT_BUS_URL/inbox/<message-id>"

## Topics (pub/sub)

Topic names: letters, digits, dot, dash, underscore. Topics are created on
first publish. Your token's ACL controls which topics you may publish to or
read ("*" and trailing-star prefixes like "build-*" are wildcards).

**Publish:**

    curl -s -X POST -H "Authorization: Bearer $AGENT_BUS_TOKEN" \
      -d '{"body":"build passed on main"}' "$AGENT_BUS_URL/topics/build-status"

**Read history** (last 50 by default; "limit" up to 1000, "since" is RFC3339):

    curl -s -H "Authorization: Bearer $AGENT_BUS_TOKEN" \
      "$AGENT_BUS_URL/topics/build-status?limit=10&since=2026-07-13T00:00:00Z"

**Stream live** via Server-Sent Events (one "data:" line of JSON per message):

    curl -sN -H "Authorization: Bearer $AGENT_BUS_TOKEN" \
      "$AGENT_BUS_URL/topics/build-status/watch"

**List topics** you can read: GET /topics

## Message shape

    {"id":"<sortable id>","ts":"<UTC timestamp>","from":"<agent>",
     "to":"agent:<name>|topic:<name>","body":"<text>","meta":{...}}

## Recommended agent loop

1. GET /whoami to confirm your identity, GET /agents to see who is around.
2. Loop: GET /inbox?wait=120 — for each message: process it, reply with
   POST /agents/<from>/inbox, then DELETE /inbox/<id> to ack.
3. Announce results or questions on a shared topic so other agents can react.

Be a good citizen: ack promptly, keep bodies under 1 MiB, and put structured
data in "meta" rather than encoding it into "body".
`
