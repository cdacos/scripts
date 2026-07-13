// slack-bridge: connects a Slack workspace to an agent-bus.
//
// To the bus it is just another agent (normal token in agents.json) — the
// bus needs no changes to support it. Both legs are plain HTTP:
//
//	Slack -> bus: Slack Events API posts to /slack/events on this process
//	              (put it behind the same reverse proxy as the bus)
//	bus -> Slack: chat.postMessage via the Slack Web API
//
// Behavior:
//   - DM the Slack bot "venus: some message" to drop it in venus's inbox;
//     the agent's reply comes back into the same Slack thread (agents echo
//     meta.thread, as instructed in the delivered message).
//   - Slack channels mapped in the config mirror bus topics both ways.
//
// Env:
//
//	AGENT_BUS_URL, AGENT_BUS_TOKEN  bus connection
//	SLACK_BOT_TOKEN                 xoxb- token for Web API calls
//	SLACK_SIGNING_SECRET            verifies Events API signatures
//	                                (empty = verification OFF, dev only)
//	BRIDGE_LISTEN                   listen address (default :8100)
//	BRIDGE_CONFIG                   config path (default /config.json)
//	SLACK_API_BASE                  Web API base (default https://slack.com/api)
package main

import (
	"bufio"
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Config struct {
	Channels       map[string]string `json:"channels"`        // Slack channel ID -> bus topic
	DefaultChannel string            `json:"default_channel"` // where unthreaded agent DMs land
}

type BusMessage struct {
	ID   string         `json:"id"`
	TS   string         `json:"ts"`
	From string         `json:"from"`
	To   string         `json:"to"`
	Body string         `json:"body"`
	Meta map[string]any `json:"meta,omitempty"`
}

type slackEvent struct {
	Type        string `json:"type"`
	Subtype     string `json:"subtype"`
	BotID       string `json:"bot_id"`
	User        string `json:"user"`
	Text        string `json:"text"`
	Channel     string `json:"channel"`
	ChannelType string `json:"channel_type"`
	TS          string `json:"ts"`
	ThreadTS    string `json:"thread_ts"`
}

type bridge struct {
	busURL, busToken               string
	slackToken, signingSecret, api string
	cfg                            Config
	self                           string // our agent name on the bus
	client                         *http.Client

	seenMu sync.Mutex
	seen   map[string]time.Time // Slack event_id dedup (Slack retries deliveries)
}

// --- bus client ---

func (b *bridge) busJSON(method, path string, body, out any) error {
	var rdr io.Reader
	if body != nil {
		bts, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rdr = bytes.NewReader(bts)
	}
	req, err := http.NewRequest(method, b.busURL+path, rdr)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+b.busToken)
	resp, err := b.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		return fmt.Errorf("bus %s %s: %s: %s", method, path, resp.Status, strings.TrimSpace(string(data)))
	}
	if out != nil {
		return json.Unmarshal(data, out)
	}
	return nil
}

func (b *bridge) busAgents() []string {
	var out struct {
		Agents []string `json:"agents"`
	}
	if err := b.busJSON("GET", "/agents", nil, &out); err != nil {
		log.Printf("listing agents: %v", err)
	}
	return out.Agents
}

// --- Slack client ---

func (b *bridge) postMessage(channel, threadTS, text string) error {
	payload := map[string]any{"channel": channel, "text": text}
	if threadTS != "" {
		payload["thread_ts"] = threadTS
	}
	bts, _ := json.Marshal(payload)
	req, err := http.NewRequest("POST", b.api+"/chat.postMessage", bytes.NewReader(bts))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	req.Header.Set("Authorization", "Bearer "+b.slackToken)
	resp, err := b.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	var out struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return fmt.Errorf("slack chat.postMessage: decoding response: %w", err)
	}
	if !out.OK {
		return fmt.Errorf("slack chat.postMessage: %s", out.Error)
	}
	return nil
}

// --- Slack -> bus ---

func (b *bridge) verifySlackSig(r *http.Request, body []byte) bool {
	if b.signingSecret == "" {
		return true // dev mode, warned loudly at startup
	}
	ts := r.Header.Get("X-Slack-Request-Timestamp")
	tsi, err := strconv.ParseInt(ts, 10, 64)
	if err != nil {
		return false
	}
	age := time.Since(time.Unix(tsi, 0))
	if age > 5*time.Minute || age < -5*time.Minute {
		return false
	}
	mac := hmac.New(sha256.New, []byte(b.signingSecret))
	fmt.Fprintf(mac, "v0:%s:%s", ts, body)
	expected := "v0=" + hex.EncodeToString(mac.Sum(nil))
	return hmac.Equal([]byte(expected), []byte(r.Header.Get("X-Slack-Signature")))
}

func (b *bridge) dedup(id string) bool {
	if id == "" {
		return false
	}
	b.seenMu.Lock()
	defer b.seenMu.Unlock()
	nowT := time.Now()
	for k, t := range b.seen {
		if nowT.Sub(t) > 10*time.Minute {
			delete(b.seen, k)
		}
	}
	if _, ok := b.seen[id]; ok {
		return true
	}
	b.seen[id] = nowT
	return false
}

func (b *bridge) handleEvents(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		http.Error(w, "read error", http.StatusBadRequest)
		return
	}
	if !b.verifySlackSig(r, body) {
		http.Error(w, "bad signature", http.StatusUnauthorized)
		return
	}
	var outer struct {
		Type      string     `json:"type"`
		Challenge string     `json:"challenge"`
		EventID   string     `json:"event_id"`
		Event     slackEvent `json:"event"`
	}
	if err := json.Unmarshal(body, &outer); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	switch outer.Type {
	case "url_verification":
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"challenge": outer.Challenge})
	case "event_callback":
		// Ack immediately (Slack retries after 3s), process async.
		w.WriteHeader(http.StatusOK)
		if !b.dedup(outer.EventID) {
			go b.handleEvent(outer.Event)
		}
	default:
		w.WriteHeader(http.StatusOK)
	}
}

func (b *bridge) handleEvent(ev slackEvent) {
	if ev.Type != "message" {
		return
	}
	if ev.BotID != "" || ev.Subtype != "" {
		return // ignore bot messages (incl. our own) and edits/joins/etc
	}
	text := strings.TrimSpace(ev.Text)
	if text == "" {
		return
	}
	if topic, ok := b.cfg.Channels[ev.Channel]; ok {
		err := b.busJSON("POST", "/topics/"+topic, map[string]any{
			"body": text,
			"meta": map[string]any{"slack_user": ev.User, "slack_channel": ev.Channel, "slack_ts": ev.TS},
		}, nil)
		if err != nil {
			log.Printf("publishing %s -> %s: %v", ev.Channel, topic, err)
		}
		return
	}
	if ev.ChannelType == "im" {
		b.handleDM(ev, text)
	}
}

// parseTarget splits "venus: message" / "@venus message" into (venus, message).
func parseTarget(text string) (string, string) {
	t := strings.TrimPrefix(text, "@")
	for i, r := range t {
		if r == ':' || r == ' ' {
			return strings.TrimSpace(t[:i]), strings.TrimSpace(t[i+1:])
		}
	}
	return "", text
}

func (b *bridge) handleDM(ev slackEvent, text string) {
	target, rest := parseTarget(text)
	agents := b.busAgents()
	valid := false
	for _, a := range agents {
		if a == target {
			valid = true
			break
		}
	}
	if !valid || rest == "" {
		b.postMessage(ev.Channel, "",
			"Address an agent like:  venus: your message\nAgents: "+strings.Join(agents, ", "))
		return
	}
	thread := ev.ThreadTS
	if thread == "" {
		thread = ev.TS
	}
	threadRef := ev.Channel + ":" + thread
	body := rest + "\n\n(Received from Slack via agent '" + b.self +
		"'. To reply in the Slack thread, DM agent '" + b.self +
		"' and include meta {\"thread\": \"" + threadRef + "\"}.)"
	err := b.busJSON("POST", "/agents/"+target+"/inbox", map[string]any{
		"body": body,
		"meta": map[string]any{"thread": threadRef, "slack_user": ev.User},
	}, nil)
	if err != nil {
		log.Printf("delivering DM to %s: %v", target, err)
		b.postMessage(ev.Channel, thread, "Delivery to "+target+" failed: "+err.Error())
		return
	}
	b.postMessage(ev.Channel, thread, "→ delivered to *"+target+"*")
}

// --- bus -> Slack ---

// inboxLoop delivers DMs sent to the bridge agent into Slack. Messages with
// meta.thread ("<channel>:<ts>") reply in that thread; anything else goes to
// the default channel. Only acked after Slack accepts the post.
func (b *bridge) inboxLoop() {
	for {
		var out struct {
			Messages []BusMessage `json:"messages"`
		}
		if err := b.busJSON("GET", "/inbox?wait=120", nil, &out); err != nil {
			log.Printf("inbox poll: %v", err)
			time.Sleep(10 * time.Second)
			continue
		}
		for _, m := range out.Messages {
			channel, threadTS := b.cfg.DefaultChannel, ""
			if th, ok := m.Meta["thread"].(string); ok {
				if c, t, found := strings.Cut(th, ":"); found {
					channel, threadTS = c, t
				}
			}
			if channel == "" {
				log.Printf("message %s from %s has no thread meta and no default_channel is set; acking without delivery (it remains in bus history)", m.ID, m.From)
				b.busJSON("DELETE", "/inbox/"+m.ID, nil, nil)
				continue
			}
			if err := b.postMessage(channel, threadTS, fmt.Sprintf("*%s*: %s", m.From, m.Body)); err != nil {
				log.Printf("posting to Slack: %v (will retry)", err)
				time.Sleep(10 * time.Second)
				break // leave unacked; re-fetched next poll
			}
			b.busJSON("DELETE", "/inbox/"+m.ID, nil, nil)
		}
	}
}

// watchTopic mirrors a bus topic into a Slack channel via the bus SSE stream.
func (b *bridge) watchTopic(topic, channel string) {
	for {
		if err := b.streamTopic(topic, channel); err != nil {
			log.Printf("watch %s: %v; reconnecting in 5s", topic, err)
		}
		time.Sleep(5 * time.Second)
	}
}

func (b *bridge) streamTopic(topic, channel string) error {
	req, err := http.NewRequest("GET", b.busURL+"/topics/"+topic+"/watch", nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+b.busToken)
	resp, err := b.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("%s: %s", resp.Status, strings.TrimSpace(string(data)))
	}
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 2<<20)
	for scanner.Scan() {
		data, ok := strings.CutPrefix(scanner.Text(), "data: ")
		if !ok {
			continue
		}
		var m BusMessage
		if err := json.Unmarshal([]byte(data), &m); err != nil {
			continue
		}
		if m.From == b.self {
			continue // we published this from Slack; don't echo it back
		}
		if err := b.postMessage(channel, "", fmt.Sprintf("[%s] *%s*: %s", topic, m.From, m.Body)); err != nil {
			log.Printf("mirroring %s to Slack: %v", topic, err)
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	return fmt.Errorf("stream closed")
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func requireEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		log.Fatalf("%s is required", key)
	}
	return v
}

func main() {
	b := &bridge{
		busURL:        strings.TrimRight(requireEnv("AGENT_BUS_URL"), "/"),
		busToken:      requireEnv("AGENT_BUS_TOKEN"),
		slackToken:    requireEnv("SLACK_BOT_TOKEN"),
		signingSecret: os.Getenv("SLACK_SIGNING_SECRET"),
		api:           strings.TrimRight(envOr("SLACK_API_BASE", "https://slack.com/api"), "/"),
		client:        &http.Client{}, // no timeout: inbox long-poll + SSE
		seen:          map[string]time.Time{},
	}
	if b.signingSecret == "" {
		log.Printf("WARNING: SLACK_SIGNING_SECRET not set — event signature verification is DISABLED")
	}

	cfgPath := envOr("BRIDGE_CONFIG", "/config.json")
	if data, err := os.ReadFile(cfgPath); err != nil {
		log.Printf("no config at %s (%v): no channel<->topic mirroring, DMs only", cfgPath, err)
	} else if err := json.Unmarshal(data, &b.cfg); err != nil {
		log.Fatalf("parsing %s: %v", cfgPath, err)
	}

	// Learn our agent name; retry so start order vs the bus doesn't matter.
	for {
		var who struct {
			Agent string `json:"agent"`
		}
		if err := b.busJSON("GET", "/whoami", nil, &who); err == nil {
			b.self = who.Agent
			break
		} else {
			log.Printf("waiting for bus: %v", err)
			time.Sleep(5 * time.Second)
		}
	}
	log.Printf("connected to bus as agent %q; %d mirrored channel(s)", b.self, len(b.cfg.Channels))

	for channel, topic := range b.cfg.Channels {
		go b.watchTopic(topic, channel)
	}
	go b.inboxLoop()

	mux := http.NewServeMux()
	mux.HandleFunc("POST /slack/events", b.handleEvents)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte("ok\n"))
	})
	listen := envOr("BRIDGE_LISTEN", ":8100")
	srv := &http.Server{Addr: listen, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	log.Printf("slack-bridge listening on %s", listen)
	log.Fatal(srv.ListenAndServe())
}
