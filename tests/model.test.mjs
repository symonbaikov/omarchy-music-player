// Run: node --test tests/
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../Model.js", import.meta.url), "utf8").replace(/^\.pragma library\s*$/m, "")
const M = {}
// QML's V4 engine lacks some newer built-ins; remove them so tests catch their use.
const V4_MISSING = "delete String.prototype.trimEnd; delete String.prototype.trimStart; delete Array.prototype.at; delete Object.hasOwn;\n"
vm.runInNewContext(V4_MISSING + source + "\n;Object.assign(__out, { cleanText, plain, truncate, formatTime, parseLine, parseSession, clampIndex, mpvCommand, GLYPH, normalizeRepeat, nextRepeat, repeatFromMpv, repeatCommands, coverUrl, OBSERVED, SUPERMIX_ID, isMix, radioListId, autoplaySeed })", { __out: M })

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

test("repeat cycles off -> all -> one -> off like Apple Music", () => {
  assert.equal(M.nextRepeat("off"), "all")
  assert.equal(M.nextRepeat("all"), "one")
  assert.equal(M.nextRepeat("one"), "off")
  assert.equal(M.nextRepeat("bogus"), "all")
  assert.equal(M.normalizeRepeat("<b>"), "off")
})

test("repeatFromMpv reads mpv's loop properties", () => {
  assert.equal(M.repeatFromMpv(false, false), "off")
  assert.equal(M.repeatFromMpv(false, "inf"), "all")
  assert.equal(M.repeatFromMpv("inf", false), "one")
  assert.equal(M.repeatFromMpv("inf", "inf"), "one")
  assert.equal(M.repeatFromMpv(3, false), "one")
  assert.equal(M.repeatFromMpv(false, "force"), "all")
  assert.equal(M.repeatFromMpv("no", "no"), "off")
})

test("repeatCommands sets both loop properties", () => {
  assert.equal(JSON.stringify(M.repeatCommands("one")), JSON.stringify([["set_property", "loop-file", "inf"], ["set_property", "loop-playlist", "no"]]))
  assert.equal(JSON.stringify(M.repeatCommands("all")), JSON.stringify([["set_property", "loop-file", "no"], ["set_property", "loop-playlist", "inf"]]))
  assert.equal(JSON.stringify(M.repeatCommands("x")), JSON.stringify([["set_property", "loop-file", "no"], ["set_property", "loop-playlist", "no"]]))
})

test("mpv loop properties are observed", () => {
  assert.ok(M.OBSERVED.includes("loop-file") && M.OBSERVED.includes("loop-playlist"))
})

test("coverUrl only builds fixed-host URLs from valid video ids", () => {
  assert.equal(M.coverUrl("dQw4w9WgXcQ", "large"), "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg")
  assert.equal(M.coverUrl("dQw4w9WgXcQ"), "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg")
  assert.equal(M.coverUrl("../../evil/x"), "")
  assert.equal(M.coverUrl("dQw4w9WgXcQ?x=1"), "")
  assert.equal(M.coverUrl(""), "")
  assert.equal(M.coverUrl(null), "")
})

test("radioListId builds YouTube Music's song radio id from a valid video id only", () => {
  assert.equal(M.radioListId("dQw4w9WgXcQ"), "RDAMVMdQw4w9WgXcQ")
  assert.equal(M.radioListId("bad"), "")
  assert.equal(M.radioListId("dQw4w9WgXcQ&x"), "")
})

test("isMix recognizes generated mixes", () => {
  assert.ok(M.isMix("RDAMVMdQw4w9WgXcQ"))
  assert.ok(M.isMix(M.SUPERMIX_ID))
  assert.ok(!M.isMix("PL123abc"))
  assert.ok(!M.isMix("LM"))
})

test("autoplaySeed fires once, on the last song, only with repeat off", () => {
  const base = { enabled: true, connected: true, repeat: "off", pos: 9, count: 10, trackId: "dQw4w9WgXcQ", requested: "" }
  assert.equal(M.autoplaySeed(base), "dQw4w9WgXcQ")
  assert.equal(M.autoplaySeed({ ...base, requested: "dQw4w9WgXcQ" }), "")
  assert.equal(M.autoplaySeed({ ...base, pos: 8 }), "")
  assert.equal(M.autoplaySeed({ ...base, repeat: "all" }), "")
  assert.equal(M.autoplaySeed({ ...base, repeat: "one" }), "")
  assert.equal(M.autoplaySeed({ ...base, enabled: false }), "")
  assert.equal(M.autoplaySeed({ ...base, connected: false }), "")
  assert.equal(M.autoplaySeed({ ...base, count: 0, pos: -1 }), "")
  assert.equal(M.autoplaySeed({ ...base, trackId: "<b>x</b>" }), "")
  assert.equal(M.autoplaySeed({ ...base, count: 1, pos: 0 }), "dQw4w9WgXcQ")
  assert.equal(M.autoplaySeed(null), "")
})

test("parseLine accepts radio results and parseSession keeps autoplay", () => {
  const r = M.parseLine(JSON.stringify({ type: "radio", mode: "append", added: 25 }))
  assert.equal(r.type, "radio")
  assert.equal(r.added, 25)
  const s = M.parseSession(JSON.stringify({ playlistId: "RDAMVMdQw4w9WgXcQ", autoplay: true, tracks: [] }))
  assert.equal(s.autoplay, true)
})
