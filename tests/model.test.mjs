// Run: node --test tests/
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../Model.js", import.meta.url), "utf8").replace(/^\.pragma library\s*$/m, "")
const M = {}
// QML's V4 engine lacks some newer built-ins; remove them so tests catch their use.
const V4_MISSING = "delete String.prototype.trimEnd; delete String.prototype.trimStart; delete Array.prototype.at; delete Object.hasOwn;\n"
vm.runInNewContext(V4_MISSING + source + "\n;Object.assign(__out, { cleanText, plain, truncate, formatTime, parseLine, parseSession, clampIndex, mpvCommand, GLYPH })", { __out: M })

const MARKUP = '<img src="https://example.invalid/tracker">Song'

test("plain() neutralizes markup-shaped titles for the shared tooltip", () => {
  const out = M.plain(MARKUP)
  assert.ok(!out.includes("<") && !out.includes(">"))
  assert.ok(out.endsWith("Song"))
})

test("cleanText strips control characters and clamps length", () => {
  assert.equal(M.cleanText("a\nb\u0000c"), "a b c")
  assert.equal(M.cleanText("x".repeat(1000)).length, 300)
  assert.equal(M.cleanText(null), "")
})

test("truncate adds an ellipsis only when needed", () => {
  assert.equal(M.truncate("short", 10), "short")
  assert.equal(M.truncate("abcdefghijkl", 5), "abcd…")
})

test("formatTime", () => {
  assert.equal(M.formatTime(0), "0:00")
  assert.equal(M.formatTime(75), "1:15")
  assert.equal(M.formatTime(3725), "1:02:05")
  assert.equal(M.formatTime(-4), "0:00")
  assert.equal(M.formatTime("nope"), "0:00")
})

test("parseLine sanitizes playlists and drops bad ids", () => {
  const line = JSON.stringify({ type: "playlists", stale: false, items: [
    { id: "LM", title: "Liked Music", count: null },
    { id: "PL123abc", title: MARKUP, count: 12 },
    { id: "bad id; rm -rf", title: "x" },
    { id: "PL123abc", title: "dupe" },
    { id: "PLother", title: "", count: -3 },
  ] })
  const msg = M.parseLine(line)
  assert.equal(msg.type, "playlists")
  assert.deepEqual(Array.from(msg.items, p => p.id), ["LM", "PL123abc", "PLother"])
  assert.equal(msg.items[2].title, "PLother")
  assert.equal(msg.items[2].count, null)
  assert.equal(msg.items[1].count, 12)
})

test("parseLine sanitizes tracks", () => {
  const msg = M.parseLine(JSON.stringify({ type: "tracks", playlistId: "PLabc", items: [
    { id: "dQw4w9WgXcQ", title: "Song", artist: "Band", duration: 212.7 },
    { id: "short", title: "bad" },
    { id: "AAAAAAAAAAA", title: "x", duration: 1e9 },
  ] }))
  assert.equal(msg.items.length, 2)
  assert.equal(msg.items[0].duration, 212)
  assert.equal(msg.items[1].duration, null)
})

test("parseLine rejects tracks for an invalid playlist id and junk", () => {
  assert.equal(M.parseLine(JSON.stringify({ type: "tracks", playlistId: "../../etc", items: [] })), null)
  assert.equal(M.parseLine("not json"), null)
  assert.equal(M.parseLine(JSON.stringify({ type: "unknown" })), null)
})

test("parseLine caps list sizes", () => {
  const items = Array.from({ length: 6000 }, (_, i) => ({ id: "A".repeat(10) + String(i % 10), title: "t" }))
  assert.equal(M.parseLine(JSON.stringify({ type: "tracks", playlistId: "PLx1", items })).items.length, 5000)
})

test("parseSession", () => {
  const s = M.parseSession(JSON.stringify({ playlistId: "PLabc", playlistTitle: "Mix", shuffle: true, tracks: [{ id: "dQw4w9WgXcQ", title: "Song" }] }))
  assert.equal(s.tracks.length, 1)
  assert.equal(s.shuffle, true)
  assert.equal(M.parseSession("{}"), null)
})

test("clampIndex", () => {
  assert.equal(M.clampIndex(-1, 1, 5), 0)
  assert.equal(M.clampIndex(-1, -1, 5), 4)
  assert.equal(M.clampIndex(4, 1, 5), 4)
  assert.equal(M.clampIndex(0, -1, 5), 0)
  assert.equal(M.clampIndex(0, 1, 0), -1)
})

test("mpvCommand is newline-terminated JSON", () => {
  assert.equal(M.mpvCommand(["cycle", "pause"]), '{"command":["cycle","pause"]}\n')
  assert.equal(M.mpvCommand(["get_property", "time-pos"], 9), '{"command":["get_property","time-pos"],"request_id":9}\n')
})
