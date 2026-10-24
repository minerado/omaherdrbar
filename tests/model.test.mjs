// Run: node tests/model.test.mjs
import { readFileSync } from "node:fs"
import assert from "node:assert/strict"

const src = readFileSync(new URL("../Model.js", import.meta.url), "utf8").replace(/^\.pragma library\s*/, "")
const M = new Function(src + "; return { build, tooltip, statusText, rows, parseColors, ago, nextTicker, signature, barAgents, OPTIONS }")()

const agent = (over) => ({
  agent: "claude", agent_status: "idle", pane_id: "p1", workspace_id: "wF",
  terminal_title_stripped: "Fix login bug", cwd: "/home/me/Work",
  focused: false, completion_seq: 5, state_change_seq: 5, ...over,
})
const snap = (...agents) => ({
  agents,
  workspaces: [{ workspace_id: "wF", label: "Main" }, { workspace_id: "wD", label: "Billing" }, { workspace_id: "wE", label: "Empty" }],
})

let t = 1000

// Calm: everything idle.
let r = M.build(snap(agent()), {}, t)
assert.equal(r.mood, "calm")
assert.equal(r.headline, "")
assert.equal(r.agents[0].since, null, "no duration until we see a state start")

// herdr's `done` is our "ready".
r = M.build(snap(agent({ agent_status: "working", state_change_seq: 6 })), r.memory, (t += 1000))
assert.equal(r.mood, "busy")
assert.equal(r.agents[0].since, t)
r = M.build(snap(agent({ agent_status: "done", state_change_seq: 7 })), r.memory, (t += 90_000))
assert.equal(r.agents[0].status, "ready")
assert.equal(r.headline, "1 done")
assert.equal(r.mood, "attention")
assert.equal(M.statusText(r.agents[0], t + 120_000), "done 2m")

// Blocked: headline names the workspace; group order puts it first.
r = M.build(snap(
  agent({ agent_status: "done" }),
  agent({ pane_id: "p2", agent_status: "working" }),
  agent({ pane_id: "p3", workspace_id: "wD", agent_status: "blocked", terminal_title_stripped: "Claude Code", cwd: "/x/Billing" }),
), r.memory, (t += 1000))
assert.equal(r.mood, "urgent")
assert.equal(r.headline, "Billing")
assert.deepEqual(r.groups.map((g) => g.label), ["Billing", "Main"], "urgent group first, empty workspace hidden")
assert.equal(r.groups[0].summary, "1 needs you")
assert.equal(r.groups[0].agents[0].title, "Billing", "generic title falls back to folder")
assert.equal(r.groups[1].summary, "1 done")
assert.equal(r.groups[1].size, "2 agents")
assert.deepEqual(r.groups[1].agents.map((a) => a.status), ["ready", "working"], "rows most urgent first")
assert.deepEqual(M.rows(r).map((a) => a.key), ["p3", "p1", "p2"])
assert.match(M.tooltip(r).split("\n")[0], /^◆  Billing — 1 needs you \(1 agent\)/)

// Long session titles are capped in the bar headline.
r = M.build(snap(agent({ agent_status: "blocked", terminal_title_stripped: "Refactor the payment retry logic for checkout" })), {}, t)
assert.equal(r.headline, "Refactor the payment ret…")
assert.equal(r.headline.length, 25)
assert.equal(r.agents[0].title, "Refactor the payment retry logic for checkout", "panel keeps the full title")

// Several blocked: count instead of a name.
r = M.build(snap(agent({ agent_status: "blocked" }), agent({ pane_id: "p2", agent_status: "blocked" })), {}, t)
assert.equal(r.headline, "2 need you")

// Events: first sighting is silent; working -> done and -> blocked speak;
// done -> idle and idle -> working don't.
r = M.build(snap(agent({ agent_status: "working" }), agent({ pane_id: "p2", agent_status: "idle" })), {}, t)
assert.deepEqual(r.events, [])
r = M.build(snap(agent({ agent_status: "done" }), agent({ pane_id: "p2", agent_status: "blocked", terminal_title_stripped: "Migrate the users table to Postgres" })), r.memory, (t += 1000))
assert.deepEqual(r.events.map((e) => e.text), [
  "◆ Migrate the users table to… — needs you",
  "◉ Fix login bug — done",
], "most urgent event first")
r = M.build(snap(agent({ agent_status: "done" }), agent({ pane_id: "p2", agent_status: "blocked" })), r.memory, (t += 1000))
assert.deepEqual(r.events, [], "no repeat while the state holds")
r = M.build(snap(agent({ agent_status: "idle" }), agent({ pane_id: "p2", agent_status: "working" })), r.memory, (t += 1000))
assert.deepEqual(r.events, [])

// A session that appears after the first poll already blocked still speaks;
// one that's there on the first poll doesn't.
r = M.build(snap(agent()), {}, t)
r = M.build(snap(agent(), agent({ pane_id: "p9", agent_status: "blocked", terminal_title_stripped: "New session" })), r.memory, (t += 1000), true)
assert.deepEqual(r.events.map((e) => e.text), ["◆ New session — needs you"])
assert.equal(r.agents[1].since, t, "new session's state started now")
r = M.build(snap(agent({ agent_status: "blocked" })), {}, t, false)
assert.deepEqual(r.events, [])

// Ticker: dropped once its agent moves on; not cut short by a lesser event.
const blockedEvent = { key: "p2", status: "blocked", rank: 0, text: "◆ B — needs you" }
const doneEvent = { key: "p1", status: "ready", rank: 1, text: "◉ T — done" }
const live = (p1, p2) => [{ key: "p1", status: p1 }, { key: "p2", status: p2 }]
assert.deepEqual(M.nextTicker(null, [blockedEvent], live("idle", "blocked")), { ticker: blockedEvent, fresh: true })
assert.deepEqual(M.nextTicker(blockedEvent, [], live("idle", "working")), { ticker: null, fresh: false }, "approved elsewhere")
assert.deepEqual(M.nextTicker(blockedEvent, [doneEvent], live("ready", "blocked")), { ticker: blockedEvent, fresh: false }, "urgent one keeps the bar")
assert.deepEqual(M.nextTicker(doneEvent, [blockedEvent], live("ready", "blocked")), { ticker: blockedEvent, fresh: true }, "more urgent replaces")
assert.deepEqual(M.nextTicker(blockedEvent, [], live("idle", "blocked")), { ticker: blockedEvent, fresh: false }, "timer keeps running")

// The UI model only changes when something drawn changes, not every poll.
const a1 = M.build(snap(agent({ agent_status: "working" })), {}, t)
const a2 = M.build(snap(agent({ agent_status: "working" })), a1.memory, t + 2000)
assert.equal(M.signature(a1), M.signature(a2))
const a3 = M.build(snap(agent({ agent_status: "done", state_change_seq: 9 })), a2.memory, t + 4000)
assert.notEqual(M.signature(a2), M.signature(a3))

// Per-agent folder, hidden when the title already is the folder.
r = M.build(snap(agent(), agent({ pane_id: "p2", terminal_title_stripped: "Claude Code", cwd: "/x/Billing" })), {}, t)
assert.deepEqual(r.agents.map((a) => a.folderLabel), ["Work", ""])

// Options: duration off, idle hidden from the bar.
assert.equal(M.statusText({ status: "ready", since: t }, t + 120_000, false), "done")
assert.equal(M.statusText({ status: "ready", since: t }, t + 120_000), "done 2m")
r = M.build(snap(agent(), agent({ pane_id: "p2", agent_status: "working" }), agent({ pane_id: "p3", agent_status: "blocked" })), {}, t)
assert.deepEqual(M.barAgents(r.agents, false).map((a) => a.key), ["p2", "p3"])
assert.equal(M.barAgents(r.agents, true).length, 3)
r = M.build(snap(agent(), agent({ pane_id: "p2" })), {}, t)
assert.deepEqual(M.barAgents(r.agents, false).map((a) => a.status), ["idle"], "all quiet keeps one faint mark")
assert.deepEqual(M.barAgents([], true).map((a) => a.status), ["idle"], "no agents yet keeps one faint mark")
assert.deepEqual(M.OPTIONS.map((o) => o.key), ["showFolder", "showDuration", "showIdleInBar", "showHeadline"])

// Agents in an unlisted workspace land in "Other".
r = M.build(snap(agent({ workspace_id: "wZ" })), {}, t)
assert.deepEqual(r.groups.map((g) => g.label), ["Other"])

// Theme colours.
const colors = M.parseColors('accent = "#ff44ca"\nred = "#ff3965"\n# comment\nhyprland_active_border = "rgba(1fe4f6ee)"\n')
assert.deepEqual(colors, { accent: "#ff44ca", red: "#ff3965" })

console.log("model tests: ok")
