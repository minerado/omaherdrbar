.pragma library

// Pure model for the herdr status widget. No QML here, so it can be tested
// with node (see tests/model.test.mjs).
//
// Inputs:
//   snapshot - `herdr api snapshot` .result.snapshot
//   memory   - per-agent state kept between polls: { [key]: { status, stateSeq, since } }
//   now      - ms timestamp
//
// Returns { agents, groups, memory, counts, headline, mood, events }.
//
// "ready" is herdr's own `done`: finished and not yet looked at in herdr.
// herdr flips it back to idle once you view the pane, so we don't track
// "seen" ourselves.

// Lower rank = needs you more. Drives sort order and the bar headline.
var RANK = { blocked: 0, ready: 1, working: 2, idle: 3, unknown: 4 }

var VERB = { blocked: "needs you", ready: "done", working: "working", idle: "idle", unknown: "unknown" }

// Same-size shapes so the bar strip stays even; shape alone tells states apart.
var GLYPH = { blocked: "◆", ready: "◉", working: "●", idle: "○", unknown: "·" }

function agentKey(agent) {
  return agent.pane_id || agent.terminal_id || ""
}

function normalStatus(raw) {
  if (raw === "done") return "ready"
  return RANK[raw] === undefined ? "unknown" : raw
}

function basename(path) {
  var parts = String(path || "").split("/").filter(function(p) { return p !== "" })
  return parts.length ? parts[parts.length - 1] : ""
}

// Session titles are the useful label ("Fix login bug"); generic
// ones like "Claude Code" fall back to the folder name.
function displayTitle(agent) {
  var title = (agent.terminal_title_stripped || agent.terminal_title || "").trim()
  if (title && title !== "Claude Code" && title !== agent.agent) return title
  return basename(agent.cwd) || agent.agent || "agent"
}

// Stable sort by rank, keeping herdr's order for ties.
function byRank(items) {
  return items
    .map(function(item, i) { return { item: item, i: i } })
    .sort(function(a, b) { return (a.item.rank - b.item.rank) || (a.i - b.i) })
    .map(function(x) { return x.item })
}

function emptyCounts() {
  return { blocked: 0, ready: 0, working: 0, idle: 0, unknown: 0 }
}

// primed: false on the widget's first poll. Agents first seen then are
// already running, so they stay silent and get no duration; agents first
// seen later are new sessions and count like any other transition.
function build(snapshot, memory, now, primed) {
  var raw = snapshot.agents || []
  var nextMemory = {}
  var agents = []
  var events = []
  var counts = emptyCounts()

  for (var i = 0; i < raw.length; i++) {
    var a = raw[i]
    var key = agentKey(a)
    var prev = memory[key]
    var status = normalStatus(a.agent_status)
    var stateSeq = typeof a.state_change_seq === "number" ? a.state_change_seq : 0
    // Unknown on the first poll: we only know how long a state lasted if we
    // saw it start.
    var since = prev && prev.status === status && prev.stateSeq === stateSeq ? prev.since : (prev || primed ? now : null)

    nextMemory[key] = { status: status, stateSeq: stateSeq, since: since }
    counts[status]++
    var title = displayTitle(a)
    var folder = basename(a.cwd)
    var item = {
      key: key,
      agent: a.agent || "agent",
      title: title,
      folder: folder,
      // What the panel row shows; empty when the title already is the folder.
      folderLabel: folder !== title ? folder : "",
      workspaceId: a.workspace_id || "",
      status: status,
      rank: RANK[status],
      focused: !!a.focused,
      since: since
    }
    agents.push(item)
    // Only transitions worth interrupting for; agents seen on the first poll
    // never count.
    var changed = prev ? prev.status !== status : !!primed
    if (changed && EVENT_STATES.indexOf(status) !== -1) events.push(makeEvent(item))
  }

  return {
    agents: agents,
    groups: groups(snapshot, agents),
    memory: nextMemory,
    counts: counts,
    headline: headline(byRank(agents), counts, snapshot),
    mood: mood(counts),
    events: byRank(events)
  }
}

var EVENT_STATES = ["blocked", "ready"]
var TICKER_TITLE_MAX = 28

// { key, status, rank, text } — what the bar ticker says, e.g.
// "◆ Billing planning — needs you".
function makeEvent(agent) {
  return {
    key: agent.key,
    status: agent.status,
    rank: agent.rank,
    title: agent.title,
    text: GLYPH[agent.status] + " " + truncate(agent.title, TICKER_TITLE_MAX) + " — " + VERB[agent.status]
  }
}

// Decides what the bar ticker shows after a poll. Returns { ticker, fresh };
// fresh means a new message, so the display timer should restart.
//   - A ticker whose agent has moved on (approved elsewhere, gone) is dropped,
//     so the bar never says "needs you" next to a working mark.
//   - A less urgent event doesn't cut a more urgent one short.
function nextTicker(current, events, agents) {
  if (current && !agents.some(function(a) { return a.key === current.key && a.status === current.status }))
    current = null
  if (events.length && (!current || events[0].rank <= current.rank)) return { ticker: events[0], fresh: true }
  return { ticker: current, fresh: false }
}

// Change signature of the parts the UI draws. Repeaters rebuild every
// delegate when their model array is replaced, which restarts the mark
// animations, so the QML only swaps the model when this changes.
function signature(model) {
  return JSON.stringify([model.agents, model.groups, model.headline, model.mood])
}

// One group per herdr workspace that has agents, most urgent group first,
// rows inside most urgent first.
function groups(snapshot, agents) {
  var workspaces = snapshot.workspaces || []
  var list = []
  for (var i = 0; i < workspaces.length; i++) {
    var w = workspaces[i]
    var id = w.workspace_id || w.id
    var rows = agents.filter(function(a) { return a.workspaceId === id })
    if (rows.length === 0) continue
    list.push(makeGroup(w.label || w.name || id, rows))
  }
  // Agents whose workspace isn't listed still need a home.
  var known = list.reduce(function(acc, g) { return acc + g.agents.length }, 0)
  if (known < agents.length) {
    var ids = workspaces.map(function(w) { return w.workspace_id || w.id })
    var orphans = agents.filter(function(a) { return ids.indexOf(a.workspaceId) === -1 })
    list.push(makeGroup("Other", orphans))
  }
  return byRank(list)
}

function makeGroup(label, rows) {
  var counts = emptyCounts()
  for (var i = 0; i < rows.length; i++) counts[rows[i].status]++
  var sorted = byRank(rows)
  return {
    label: label,
    agents: sorted,
    counts: counts,
    rank: sorted[0].rank,
    status: sorted[0].status,
    summary: groupSummary(counts),
    size: rows.length + (rows.length === 1 ? " agent" : " agents")
  }
}

// "1 needs you", "2 done", "1 working" or "" — the most urgent fact only.
function groupSummary(counts) {
  var order = ["blocked", "ready", "working"]
  for (var i = 0; i < order.length; i++) {
    if (counts[order[i]] > 0) return counts[order[i]] + " " + VERB[order[i]]
  }
  return ""
}

// "urgent" | "attention" | "busy" | "calm" — the bar's overall tone.
function mood(counts) {
  if (counts.blocked > 0) return "urgent"
  if (counts.ready > 0) return "attention"
  if (counts.working > 0) return "busy"
  return "calm"
}

// Session titles can be sentences; the panel shows them in full.
var HEADLINE_MAX = 25

function truncate(text, max) {
  return text.length > max ? text.slice(0, max - 1).replace(/\s+$/, "") + "…" : text
}

// Short text beside the bar dots; empty when there's nothing to act on.
function headline(ranked, counts, snapshot) {
  if (counts.blocked > 1) return counts.blocked + " need you"
  if (counts.blocked === 1) {
    var first = ranked[0]
    var label = workspaceLabel(snapshot, first.workspaceId)
    return truncate(label && label !== "Main" ? label : first.title, HEADLINE_MAX)
  }
  if (counts.ready > 0) return counts.ready + " done"
  return ""
}

function workspaceLabel(snapshot, id) {
  var workspaces = snapshot.workspaces || []
  for (var i = 0; i < workspaces.length; i++) {
    if ((workspaces[i].workspace_id || workspaces[i].id) === id) return workspaces[i].label || workspaces[i].name || ""
  }
  return ""
}

function ago(since, now) {
  if (!since) return ""
  var s = Math.max(0, Math.round((now - since) / 1000))
  if (s < 60) return s + "s"
  var m = Math.round(s / 60)
  if (m < 60) return m + "m"
  return Math.round(m / 60) + "h"
}

// "needs you 2m", "working", ... showDuration false drops the time.
function statusText(agent, now, showDuration) {
  var time = showDuration === false ? "" : ago(agent.since, now)
  return VERB[agent.status] + (time ? " " + time : "")
}

// User options, shown in the panel's settings view and stored in the
// widget's shell.json entry. All default to on.
var OPTIONS = [
  { key: "showFolder", label: "Folder on each agent" },
  { key: "showDuration", label: "Time in state (\"idle 3m\")" },
  { key: "showIdleInBar", label: "Idle agents in the bar" },
  { key: "showHeadline", label: "Headline next to the marks" }
]

// Marks for the bar strip. Without idle agents, an all-quiet herd keeps one
// faint mark so the widget stays visible and clickable.
function barAgents(agents, showIdle) {
  if (showIdle) return agents
  var active = agents.filter(function(a) { return a.rank <= RANK.working })
  if (active.length || agents.length === 0) return active
  return [{ key: "quiet", status: "idle", rank: RANK.idle }]
}

// Flat list of rows in panel order, for keyboard navigation.
function rows(model) {
  var out = []
  var gs = model.groups || []
  for (var i = 0; i < gs.length; i++) out = out.concat(gs[i].agents)
  return out
}

// Bar tooltip: the group headers only; the panel has the detail.
function tooltip(model) {
  var gs = model.groups || []
  if (gs.length === 0) return "herdr: no agents"
  return gs.map(function(g) {
    return GLYPH[g.status] + "  " + g.label + (g.summary ? " — " + g.summary : "") + " (" + g.size + ")"
  }).join("\n") + "\n\nClick for details · right-click to open herdr"
}

// Parses `key = "#rrggbb"` lines from an Omarchy colors.toml.
function parseColors(text) {
  var colors = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^\s*([a-z_]+)\s*=\s*"(#[0-9a-fA-F]{6,8})"/)
    if (m) colors[m[1]] = m[2]
  }
  return colors
}
