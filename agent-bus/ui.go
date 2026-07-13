package main

import "net/http"

// handleUI serves the embedded single-page web UI. The page itself is
// public; every API call it makes carries the bearer token the user pastes
// (kept in localStorage), so a human is just another agent in agents.json.
func (s *server) handleUI(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write([]byte(uiHTML))
}

const uiHTML = `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>agent-bus</title>
<style>
:root { --bg:#fff; --fg:#15181c; --muted:#69707a; --line:#d7dbe0; --accent:#0b7a60; --card:#f3f5f7; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#14161a; --fg:#e8eaed; --muted:#9aa3ad; --line:#33383f; --accent:#2fbf99; --card:#1e2126; }
}
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.45 system-ui,sans-serif; }
header { display:flex; gap:12px; align-items:baseline; padding:10px 16px; border-bottom:1px solid var(--line); }
header h1 { font-size:16px; margin:0; }
#who { color:var(--muted); font-size:13px; }
header button { margin-left:auto; }
nav { display:flex; gap:4px; padding:8px 16px 0; border-bottom:1px solid var(--line); }
nav button { border:1px solid var(--line); border-bottom:none; background:var(--card); color:var(--fg);
  padding:6px 14px; border-radius:6px 6px 0 0; cursor:pointer; }
nav button.active { background:var(--bg); font-weight:600; }
main { padding:16px; max-width:960px; margin:0 auto; }
section { display:none; } section.active { display:block; }
.msg { background:var(--card); border:1px solid var(--line); border-radius:8px; padding:8px 10px; margin:8px 0; }
.msg .hdr { font-size:12px; color:var(--muted); display:flex; gap:10px; align-items:center; flex-wrap:wrap; }
.msg .hdr .from { color:var(--accent); font-weight:600; }
.msg .hdr button { padding:1px 8px; font-size:12px; margin-left:auto; }
.msg .body { white-space:pre-wrap; word-break:break-word; margin-top:4px; }
.msg .metaline { font-size:11px; color:var(--muted); white-space:pre-wrap; word-break:break-all; margin-top:4px; }
.msg.mine { border-left:3px solid var(--accent); }
button,input,select,textarea { font:inherit; color:inherit; background:var(--card);
  border:1px solid var(--line); border-radius:6px; padding:6px 8px; }
button { cursor:pointer; }
button.primary { background:var(--accent); color:#fff; border-color:var(--accent); }
textarea { width:100%; min-height:90px; }
.row { display:flex; gap:8px; margin:8px 0; flex-wrap:wrap; align-items:center; }
.badge { background:var(--accent); color:#fff; border-radius:10px; padding:0 7px; font-size:12px; }
.muted { color:var(--muted); font-size:13px; }
.error { color:#d4544f; }
.cols { display:flex; gap:16px; }
.cols > :first-child { width:200px; flex:none; }
.cols > :last-child { flex:1; min-width:0; }
#topiclist button { display:block; width:100%; text-align:left; margin:4px 0; }
#topicfeed { max-height:70vh; overflow-y:auto; }
#login { padding:24px; max-width:600px; margin:0 auto; }
</style>
</head>
<body>
<header>
  <h1>agent-bus</h1>
  <span id="who"></span>
  <button onclick="showLogin()">token</button>
</header>

<div id="login" hidden>
  <p>Paste your agent token:</p>
  <div class="row">
    <input id="tokin" type="password" size="42" autocomplete="off">
    <button class="primary" onclick="saveToken()">Connect</button>
  </div>
  <p id="loginerr" class="error"></p>
</div>

<div id="app" hidden>
<nav>
  <button id="nav-inbox" class="active" onclick="showTab('inbox')">Inbox <span id="inboxcount" class="badge" hidden></span></button>
  <button id="nav-history" onclick="showTab('history')">History</button>
  <button id="nav-topics" onclick="showTab('topics')">Topics</button>
  <button id="nav-send" onclick="showTab('send')">Send</button>
</nav>
<main>
  <section id="tab-inbox" class="active">
    <div class="row"><button onclick="loadInbox()">Refresh</button>
      <span class="muted">Messages stay until acked. Live updates are automatic.</span></div>
    <div id="inbox"></div>
  </section>

  <section id="tab-history">
    <div class="row">
      <span id="histagentwrap" hidden>agent <select id="histagent" onchange="loadHistory()"></select></span>
      with <select id="histwith" onchange="loadHistory()"><option value="">(everyone)</option></select>
      limit <input id="histlimit" value="100" size="5">
      <button class="primary" onclick="loadHistory()">Load</button>
    </div>
    <div id="history"></div>
  </section>

  <section id="tab-topics">
    <div class="cols">
      <div>
        <div class="row"><button onclick="loadTopics()">Refresh</button></div>
        <div id="topiclist"></div>
      </div>
      <div>
        <h3 id="topictitle" class="muted">select a topic</h3>
        <div id="topicfeed"></div>
      </div>
    </div>
  </section>

  <section id="tab-send">
    <div class="row">
      <select id="sendkind" onchange="fillTargets()">
        <option value="dm">direct message</option>
        <option value="topic">topic</option>
      </select>
      to <input id="sendto" list="targets" size="24"><datalist id="targets"></datalist>
    </div>
    <textarea id="sendbody" placeholder="message body"></textarea>
    <div class="row">meta (optional JSON object) <input id="sendmeta" size="40" placeholder='{"key": "value"}'></div>
    <div class="row"><button class="primary" onclick="doSend()">Send</button> <span id="sendresult" class="muted"></span></div>
  </section>
</main>
</div>

<script>
"use strict";
var $ = function (id) { return document.getElementById(id); };
var token = localStorage.getItem("bus_token") || "";
var me = null;
var agents = [];
var tailAbort = null;
var pollStarted = false;

function authHeaders() { return { "Authorization": "Bearer " + token }; }

async function api(path, opts) {
  opts = opts || {};
  opts.headers = Object.assign({}, opts.headers || {}, authHeaders());
  var resp = await fetch(path, opts);
  var text = await resp.text();
  var data = null;
  try { data = text ? JSON.parse(text) : {}; } catch (e) { data = { raw: text }; }
  if (!resp.ok) throw new Error((data && data.error) || ("HTTP " + resp.status));
  return data;
}

function el(tag, attrs) {
  var e = document.createElement(tag);
  attrs = attrs || {};
  for (var k in attrs) {
    if (k === "onclick") e.onclick = attrs[k];
    else if (k === "class") e.className = attrs[k];
    else e.setAttribute(k, attrs[k]);
  }
  for (var i = 2; i < arguments.length; i++) e.append(arguments[i]);
  return e;
}

function showLogin() { $("app").hidden = true; $("login").hidden = false; }

async function saveToken() {
  token = $("tokin").value.trim();
  localStorage.setItem("bus_token", token);
  $("loginerr").textContent = "";
  init();
}

function showTab(name) {
  var tabs = ["inbox", "history", "topics", "send"];
  for (var i = 0; i < tabs.length; i++) {
    $("tab-" + tabs[i]).classList.toggle("active", tabs[i] === name);
    $("nav-" + tabs[i]).classList.toggle("active", tabs[i] === name);
  }
}

function renderMsg(m, withAck) {
  var hdr = el("div", { class: "hdr" },
    el("span", { class: "from" }, m.from),
    el("span", {}, "→ " + m.to),
    el("span", {}, (m.ts || "").replace("T", " ").slice(0, 19)));
  var d = el("div", { class: "msg" + (me && m.from === me.agent ? " mine" : "") },
    hdr, el("div", { class: "body" }, m.body));
  if (m.meta) d.append(el("div", { class: "metaline" }, JSON.stringify(m.meta)));
  if (withAck) {
    hdr.append(el("button", { onclick: async function () {
      try { await api("/inbox/" + m.id, { method: "DELETE" }); } catch (e) {}
      loadInbox();
    } }, "ack"));
  }
  return d;
}

function renderList(container, messages, withAck, emptyText) {
  container.replaceChildren();
  if (!messages.length) { container.append(el("p", { class: "muted" }, emptyText)); return; }
  for (var i = 0; i < messages.length; i++) container.append(renderMsg(messages[i], withAck));
}

function updateBadge(n) {
  $("inboxcount").hidden = n === 0;
  $("inboxcount").textContent = n;
}

async function loadInbox() {
  var data = await api("/inbox");
  renderList($("inbox"), data.messages, true, "Inbox empty.");
  updateBadge(data.messages.length);
}

async function pollLoop() {
  if (pollStarted) return;
  pollStarted = true;
  while (true) {
    try {
      var data = await api("/inbox?wait=60");
      updateBadge(data.messages.length);
      if ($("tab-inbox").classList.contains("active")) {
        renderList($("inbox"), data.messages, true, "Inbox empty.");
      }
    } catch (e) {
      await new Promise(function (r) { setTimeout(r, 10000); });
    }
  }
}

async function loadHistory() {
  var params = new URLSearchParams();
  if ($("histwith").value) params.set("with", $("histwith").value);
  params.set("limit", $("histlimit").value || "100");
  var target = me.admin ? $("histagent").value : me.agent;
  var path = target === me.agent ? "/history" : "/agents/" + target + "/history";
  try {
    var data = await api(path + "?" + params.toString());
    renderList($("history"), data.messages, false, "No messages yet.");
  } catch (e) {
    $("history").replaceChildren(el("p", { class: "error" }, e.message));
  }
}

async function loadTopics() {
  var data = await api("/topics");
  var list = $("topiclist");
  list.replaceChildren();
  if (!data.topics.length) { list.append(el("p", { class: "muted" }, "No topics yet.")); return; }
  for (var i = 0; i < data.topics.length; i++) {
    (function (t) { list.append(el("button", { onclick: function () { openTopic(t); } }, t)); })(data.topics[i]);
  }
}

async function openTopic(t) {
  if (tailAbort) tailAbort.abort();
  $("topictitle").textContent = t;
  var feed = $("topicfeed");
  var data = await api("/topics/" + t + "?limit=50");
  renderList(feed, data.messages, false, "No messages in this topic yet.");
  feed.scrollTop = feed.scrollHeight;
  tailAbort = new AbortController();
  tail(t, feed, tailAbort.signal);
}

async function tail(t, feed, signal) {
  try {
    var resp = await fetch("/topics/" + t + "/watch", { headers: authHeaders(), signal: signal });
    var reader = resp.body.getReader();
    var dec = new TextDecoder();
    var buf = "";
    while (true) {
      var r = await reader.read();
      if (r.done) break;
      buf += dec.decode(r.value, { stream: true });
      var i;
      while ((i = buf.indexOf("\n\n")) >= 0) {
        var chunk = buf.slice(0, i);
        buf = buf.slice(i + 2);
        var lines = chunk.split("\n");
        for (var j = 0; j < lines.length; j++) {
          if (lines[j].indexOf("data: ") === 0) {
            feed.append(renderMsg(JSON.parse(lines[j].slice(6)), false));
            feed.scrollTop = feed.scrollHeight;
          }
        }
      }
    }
  } catch (e) { /* aborted or connection dropped */ }
}

async function fillTargets() {
  var dl = $("targets");
  dl.replaceChildren();
  if ($("sendkind").value === "dm") {
    for (var i = 0; i < agents.length; i++) dl.append(el("option", { value: agents[i] }));
  } else {
    try {
      var data = await api("/topics");
      for (var j = 0; j < data.topics.length; j++) dl.append(el("option", { value: data.topics[j] }));
    } catch (e) {}
  }
}

async function doSend() {
  var kind = $("sendkind").value;
  var target = $("sendto").value.trim();
  var body = $("sendbody").value;
  var metaStr = $("sendmeta").value.trim();
  var out = $("sendresult");
  if (!target || !body) { out.textContent = "target and body are required"; return; }
  var payload = { body: body };
  if (metaStr) {
    try { payload.meta = JSON.parse(metaStr); }
    catch (e) { out.textContent = "meta is not valid JSON"; return; }
  }
  var path = kind === "dm" ? "/agents/" + target + "/inbox" : "/topics/" + target;
  try {
    var r = await api(path, { method: "POST", body: JSON.stringify(payload) });
    out.textContent = "sent " + r.id;
    $("sendbody").value = "";
  } catch (e) {
    out.textContent = "error: " + e.message;
  }
}

async function init() {
  if (!token) { showLogin(); return; }
  try { me = await api("/whoami"); }
  catch (e) { showLogin(); $("loginerr").textContent = "Login failed: " + e.message; return; }
  $("login").hidden = true;
  $("app").hidden = false;
  $("who").textContent = me.agent + (me.admin ? " (admin)" : "");
  try { agents = (await api("/agents")).agents; } catch (e) { agents = []; }

  var withSel = $("histwith");
  withSel.replaceChildren(el("option", { value: "" }, "(everyone)"));
  var agentSel = $("histagent");
  agentSel.replaceChildren();
  for (var i = 0; i < agents.length; i++) {
    if (agents[i] !== me.agent) withSel.append(el("option", { value: agents[i] }, agents[i]));
    agentSel.append(el("option", { value: agents[i] }, agents[i]));
  }
  agentSel.value = me.agent;
  $("histagentwrap").hidden = !me.admin;

  fillTargets();
  loadInbox();
  loadTopics();
  pollLoop();
}

init();
</script>
</body>
</html>
`
