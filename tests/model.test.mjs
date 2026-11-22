// Run: node --test tests/*.test.mjs
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../Model.js", import.meta.url), "utf8").replace(/^\.pragma library\s*$/m, "")
const M = {}
// QML's V4 engine lacks some newer built-ins; remove them so tests catch their use.
const V4_MISSING = "delete String.prototype.trimEnd; delete String.prototype.trimStart; delete Array.prototype.at; delete Object.hasOwn;\n"
vm.runInNewContext(V4_MISSING + source + "\n;Object.assign(__out, { cleanText, plain, truncate, formatTime, parseLine, parseSession, clampIndex, mpvCommand, GLYPH, normalizeRepeat, nextRepeat, repeatFromMpv, repeatCommands, coverUrl, OBSERVED, SUPERMIX_ID, isMix, radioListId, autoplaySeed, isLoading, addTargets, likedSet, withLiked, playbackFailure, seconds, stepChoice, recentReport, mirrorOffer, parseUpdate, exploreRows, DOWNLOAD_FORMATS, trackCover })", { __out: M })

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
    { id: "BBBBBBBBBBB", title: "mix entry", duration: 0 },
  ] }))
  assert.equal(msg.items.length, 3)
  assert.equal(msg.items[2].duration, null)
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

test("isLoading follows mpv while a track opens, seeks, or rebuffers", () => {
  const playing = { connected: true, seeking: false, pausedForCache: false }
  assert.equal(M.isLoading(playing), false)
  // seeking is unavailable from start-file until playback starts
  assert.equal(M.isLoading({ ...playing, seeking: undefined }), true)
  assert.equal(M.isLoading({ ...playing, seeking: null }), true)
  assert.equal(M.isLoading({ ...playing, seeking: true }), true)
  assert.equal(M.isLoading({ ...playing, pausedForCache: true }), true)
  // nothing to load without a player, unless the helper is launching one
  assert.equal(M.isLoading({ connected: false, seeking: undefined }), false)
  assert.equal(M.isLoading({ connected: false, starting: true }), true)
  assert.equal(M.isLoading(null), false)
})

test("mpv loading properties are observed", () => {
  assert.ok(M.OBSERVED.includes("seeking") && M.OBSERVED.includes("paused-for-cache"))
})

test("addTargets offers only the user's playlists", () => {
  const lists = [{ id: "LM" }, { id: M.SUPERMIX_ID }, { id: "RDAMVMdQw4w9WgXcQ" }, { id: "PLmine1" }, { id: "PLmine2" }]
  assert.deepEqual(Array.from(M.addTargets(lists), p => p.id), ["PLmine1", "PLmine2"])
  assert.equal(M.addTargets(null).length, 0)
})

test("liked set: build, toggle, and ignore junk ids", () => {
  const set = M.likedSet(["dQw4w9WgXcQ", "bad", "<x>"])
  assert.deepEqual(Object.keys(set), ["dQw4w9WgXcQ"])
  const on = M.withLiked(set, "AAAAAAAAAAA", true)
  assert.ok(on["AAAAAAAAAAA"] && on["dQw4w9WgXcQ"])
  assert.ok(!set["AAAAAAAAAAA"], "original is not mutated")
  const off = M.withLiked(on, "dQw4w9WgXcQ", false)
  assert.deepEqual(Object.keys(off), ["AAAAAAAAAAA"])
  assert.deepEqual(Object.keys(M.withLiked(set, "../x", true)), ["dQw4w9WgXcQ"])
})

test("parseLine validates like / add / likedIds results", () => {
  assert.equal(M.parseLine(JSON.stringify({ type: "liked", id: "dQw4w9WgXcQ", liked: true })).liked, true)
  assert.equal(M.parseLine(JSON.stringify({ type: "liked", id: "nope" })), null)
  assert.equal(M.parseLine(JSON.stringify({ type: "added", id: "dQw4w9WgXcQ", playlistId: "PLx1" })).playlistId, "PLx1")
  assert.equal(M.parseLine(JSON.stringify({ type: "added", id: "dQw4w9WgXcQ", playlistId: "../x" })), null)
  const ids = M.parseLine(JSON.stringify({ type: "likedIds", known: true, ids: ["dQw4w9WgXcQ", "bad", 5] }))
  assert.equal(ids.ids.length, 1)
  assert.equal(ids.known, true)
})

test("targets: only editable playlists, already-there marked, junk dropped", () => {
  const msg = M.parseLine(JSON.stringify({ type: "targets", videoId: "dQw4w9WgXcQ", items: [
    { id: "PLmine1", title: "Road trip", contains: false },
    { id: "PLmine2", title: "<b>Gym</b>", contains: true },
    { id: "LM", title: "Liked" },
    { id: M.SUPERMIX_ID, title: "Mix" },
    { id: "PLmine1", title: "dupe" },
    { id: "bad id", title: "x" },
  ] }))
  assert.equal(JSON.stringify(Array.from(msg.items, p => [p.id, p.contains])), JSON.stringify([["PLmine1", false], ["PLmine2", true]]))
  assert.equal(msg.items[1].title, "<b>Gym</b>")   // rendered as plain text
  assert.equal(msg.items[0].count, null)
  assert.equal(M.parseLine(JSON.stringify({ type: "targets", videoId: "x", items: [] })), null)
})

test("errors carry the sign-in flag only when the helper sets it", () => {
  assert.equal(M.parseLine(JSON.stringify({ type: "error", message: "m", auth: true })).auth, true)
  assert.equal(M.parseLine(JSON.stringify({ type: "error", message: "m" })).auth, false)
  assert.equal(M.parseLine(JSON.stringify({ type: "error", message: "m", auth: "yes" })).auth, false)
})

test("playbackFailure reads yt-dlp's reason from the ytdl hook's error line", () => {
  const f = M.playbackFailure("ERROR: [youtube] Uh6Lcxacqgk: This video is available to this channel's members on level: Hero of the Skaldic Guard (or any higher level). Join this channel to get access to members-only content and other exclusive perks.\n")
  assert.equal(f.id, "Uh6Lcxacqgk")
  assert.ok(f.reason.startsWith("This video is available to this channel's members"))
  assert.ok(f.reason.endsWith("level).") && !f.reason.includes("Join this channel"))
  assert.equal(f.account, true)

  const gone = M.playbackFailure("ERROR: [youtube] abcdefghijk: Video unavailable. This video has been removed by the uploader")
  assert.deepEqual([gone.id, gone.reason, gone.account], ["abcdefghijk", "Video unavailable.", false])
  assert.equal(M.playbackFailure("ERROR: [youtube] abcdefghijk: This video is not available on this page").account, false)
  assert.equal(M.playbackFailure("ERROR: [youtube] abcdefghijk: Sign in to confirm your age").account, true)

  assert.equal(M.playbackFailure(""), null)
  assert.equal(M.playbackFailure(null), null)
  assert.equal(M.playbackFailure("youtube-dl failed: unexpected error occurred"), null)
  assert.equal(M.playbackFailure("ERROR: [youtube] bad id: nope"), null)
  // Control characters and markup from YouTube stay inert text.
  const odd = M.playbackFailure("ERROR: [youtube] abcdefghijk: <b>x</b>\u0007y")
  assert.ok(!/[\u0000-\u001f]/.test(odd.reason))
})

test("parseLine accepts the cookies sync reply", () => {
  const m = M.parseLine('{"type":"cookies","state":"applied"}')
  assert.deepEqual([m.type, m.state], ["cookies", "applied"])
  assert.equal(M.parseLine('{"type":"cookies","state":"bogus"}'), null)
})

test("seconds() reads a setting within bounds", () => {
  assert.equal(M.seconds(3, 0, 30, 0), 3)
  assert.equal(M.seconds("5", 0, 30, 0), 5)
  assert.equal(M.seconds(99, 0, 30, 0), 30)
  assert.equal(M.seconds("x", 2, 16, 6), 6)
  assert.equal(M.seconds(null, 2, 16, 6), 6)
  assert.equal(M.seconds("", 0, 30, 0), 0)
})

test("stepChoice moves within the options and stops at the ends", () => {
  const o = [0, 1, 2, 3, 5, 8]
  assert.equal(M.stepChoice(o, 2, 1), 3)
  assert.equal(M.stepChoice(o, 2, -1), 1)
  assert.equal(M.stepChoice(o, 8, 1), 8)
  assert.equal(M.stepChoice(o, 0, -1), 0)
  assert.equal(M.stepChoice(o, 4, 1), 0)
})

test("recentReport ignores old reports replayed on reconnect", () => {
  assert.equal(M.recentReport({ id: "x", at: 1000 }, 1005).id, "x")
  assert.equal(M.recentReport({ id: "x", at: 1000 }, 1100), null)
  assert.equal(M.recentReport({ id: "x" }, 1000), null)
  assert.equal(M.recentReport(null, 1000), null)
})

test("mirrorOffer only when mirrors are off and could help", () => {
  const report = { id: "dQw4w9WgXcQ", reason: "[youtube] dQw4w9WgXcQ: Sign in to confirm you're not a bot. Use --cookies", mirrors: "off", hopeless: false }
  const o = M.mirrorOffer(report, false)
  assert.equal(o.id, "dQw4w9WgXcQ")
  assert.equal(o.reason, "Sign in to confirm you're not a bot.")
  assert.equal(M.mirrorOffer(report, true), null)                                   // already on
  assert.equal(M.mirrorOffer({ ...report, mirrors: "tried" }, false), null)         // tried, didn't help
  assert.equal(M.mirrorOffer({ ...report, hopeless: true, mirrors: "skipped" }, false), null)
  assert.equal(M.mirrorOffer({ ...report, id: "bad" }, false), null)
  assert.equal(M.mirrorOffer(null, false), null)
})

test("parseUpdate reads the helper's update check", () => {
  const u = M.parseUpdate('{"type":"update","state":"available","version":"0.5.1","current":"0.5.0","notes":["Fix playback\\nafter YouTube change"]}')
  assert.deepEqual([u.state, u.version, u.current, u.notes.length], ["available", "0.5.1", "0.5.0", 1])
  assert.ok(!u.notes[0].includes("\n"))
  assert.equal(M.parseUpdate('{"type":"update","state":"weird"}'), null)
  assert.equal(M.parseUpdate('{"type":"other"}'), null)
  assert.equal(M.parseUpdate("nope"), null)
})

test("explore lines are sanitized and flatten into sectioned rows", () => {
  const line = JSON.stringify({ type: "explore", stale: false, sections: [
    { title: "Trending", items: [
      { kind: "song", id: "dQw4w9WgXcQ", title: "Song", artist: "Artist", duration: 213 },
      { kind: "song", id: "not-a-video-id", title: "Bad" },
      { kind: "list", id: "OLAK5uy_abc", title: "<b>Album</b>\u0007" },
      { kind: "mood", id: "ggMPOg1uX1JOQWZFeDBy", title: "Chill" },
      { kind: "artist", id: "UCxyz", title: "Unknown kind" } ] },
    { title: "Empty", items: [] } ] })
  const msg = M.parseLine(line)
  assert.equal(msg.sections.length, 1)
  const rows = M.exploreRows(msg.sections)
  assert.deepEqual(Array.from(rows, r => r.kind), ["song", "list", "mood"])
  assert.equal(rows[0].section, "Trending")
  assert.ok(!/[\u0000-\u001f]/.test(rows[1].title))
  const search = M.parseLine(JSON.stringify({ type: "search", query: "q", items: [{ kind: "song", id: "dQw4w9WgXcQ", title: "S" }] }))
  assert.equal(search.items.length, 1)
})

test("download lines need a valid id and an absolute path", () => {
  assert.equal(M.parseLine('{"type":"downloaded","id":"dQw4w9WgXcQ","path":"/home/u/Music/a.mp3","folder":"/home/u/Music"}').path, "/home/u/Music/a.mp3")
  assert.equal(M.parseLine('{"type":"downloaded","id":"dQw4w9WgXcQ","path":"relative.mp3"}'), null)
  assert.equal(M.parseLine('{"type":"downloading","id":"dQw4w9WgXcQ","stage":"convert"}').stage, "convert")
  assert.deepEqual(Array.from(M.DOWNLOAD_FORMATS), ["mp3", "m4a", "opus", "flac", "wav"])
})

test("downloaded songs keep their file and their own cover", () => {
  const msg = M.parseLine(JSON.stringify({ type: "tracks", playlistId: "DOWNLOADS", items: [
    { id: "dQw4w9WgXcQ", title: "A", path: "/home/u/Music/A.mp3", cover: "/home/u/.cache/x/covers/dQw4w9WgXcQ.jpg" },
    { id: "kJQP7kiw5Fk", title: "B", path: "/home/u/Music/B.opus", cover: null },
    { id: "kJQP7kiw5Fk", title: "C", path: "relative.mp3", cover: "/etc/passwd" } ] }))
  const [a, b, c] = msg.items
  assert.equal(M.trackCover(a, "small"), "file:///home/u/.cache/x/covers/dQw4w9WgXcQ.jpg")
  assert.equal(M.trackCover(b, "small"), "")                       // saved without a cover
  assert.equal(c.path, undefined)
  assert.ok(M.trackCover(c, "small").startsWith("https://i.ytimg.com/vi/kJQP7kiw5Fk/"))
})
