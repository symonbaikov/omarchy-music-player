.pragma library

// Pure helpers for the YouTube Music (mpv) widget. Everything here is free of
// QML types so tests/model.test.mjs can run it under node.

var MAX_PLAYLISTS = 500
var MAX_TRACKS = 5000
var MAX_TEXT = 300

var PLAYLIST_ID_RE = /^[A-Za-z0-9_-]{2,80}$/
var VIDEO_ID_RE = /^[A-Za-z0-9_-]{11}$/

// Nerd Font glyphs (Material Design range).
var GLYPH = {
  music: String.fromCodePoint(0xF075A),
  play: String.fromCodePoint(0xF040A),
  pause: String.fromCodePoint(0xF03E4),
  next: String.fromCodePoint(0xF04AD),
  previous: String.fromCodePoint(0xF04AE),
  stop: String.fromCodePoint(0xF04DB),
  shuffle: String.fromCodePoint(0xF049D),
  refresh: String.fromCodePoint(0xF0450),
  back: String.fromCodePoint(0xF004D),
  forward: String.fromCodePoint(0xF0054),
  playlist: String.fromCodePoint(0xF0CB8),
  heart: String.fromCodePoint(0xF02D1),
  volume: String.fromCodePoint(0xF057E),
  volumeOff: String.fromCodePoint(0xF0581),
  repeat: String.fromCodePoint(0xF0456),
  repeatOne: String.fromCodePoint(0xF0458),
  radio: String.fromCodePoint(0xF043B),
  supermix: String.fromCodePoint(0xF0AE2),
  autoplay: String.fromCodePoint(0xF06E4)
}

// ---- recommendations ---------------------------------------------------------

// YouTube Music's "My Supermix": a fixed list id that YouTube fills from the
// signed-in account's listening.
var SUPERMIX_ID = "RDTMAK5uy_kset8DisdE7LSD4TNjEVvrKRTmG7a56sY"

// "RD..." lists are YouTube's generated mixes (song radio, Supermix).
function isMix(listId) {
  return String(listId || "").indexOf("RD") === 0
}

// The radio YouTube Music builds for a song.
function radioListId(videoId) {
  var id = String(videoId || "")
  return VIDEO_ID_RE.test(id) ? "RDAMVM" + id : ""
}

// Autoplay, like YouTube Music: once the last queued song starts, with repeat
// off, extend the queue with that song's radio. Returns the seed video id to
// extend from, or "" when nothing should happen. `requested` is the seed
// already asked for, so each song triggers it once.
function autoplaySeed(s) {
  if (!s || !s.enabled || !s.connected || s.repeat !== "off") return ""
  if (!(s.count > 0) || s.pos !== s.count - 1) return ""
  var id = String(s.trackId || "")
  if (!VIDEO_ID_RE.test(id) || id === s.requested) return ""
  return id
}

// ---- repeat (Apple Music style: off -> all -> one -> off) -------------------

var REPEAT_MODES = ["off", "all", "one"]

function normalizeRepeat(mode) {
  return REPEAT_MODES.indexOf(mode) >= 0 ? mode : "off"
}

function nextRepeat(mode) {
  return REPEAT_MODES[(REPEAT_MODES.indexOf(normalizeRepeat(mode)) + 1) % REPEAT_MODES.length]
}

// mpv reports loop-file / loop-playlist as false ("no"), "inf", "force", or a
// remaining count.
function loopOn(value) {
  return value === true || value === "inf" || value === "force" || (typeof value === "number" && value > 0)
}

function repeatFromMpv(loopFile, loopPlaylist) {
  if (loopOn(loopFile)) return "one"
  if (loopOn(loopPlaylist)) return "all"
  return "off"
}

// The two mpv property writes that put the player in `mode`.
function repeatCommands(mode) {
  var m = normalizeRepeat(mode)
  return [
    ["set_property", "loop-file", m === "one" ? "inf" : "no"],
    ["set_property", "loop-playlist", m === "all" ? "inf" : "no"]
  ]
}

// ---- cover art ---------------------------------------------------------------

// YouTube's own thumbnail for a track, built only from a validated video id
// on a fixed HTTPS host. Both sizes are 16:9; YouTube Music "art tracks" put
// the square album art in the middle, so a centre-square crop shows exactly
// the cover, and for a music video it shows the middle of the frame.
// "large" = maxresdefault (1280x720, missing for some uploads: fall back to
// "small"); "small" = mqdefault (320x180, always present, ~10 KB).
function coverUrl(videoId, size) {
  var id = String(videoId || "")
  if (!VIDEO_ID_RE.test(id)) return ""
  return "https://i.ytimg.com/vi/" + id + "/" + (size === "large" ? "maxresdefault" : "mqdefault") + ".jpg"
}

// Strip control characters and clamp length. Used for every string that
// came from YouTube, yt-dlp, or mpv before it is displayed.
function cleanText(value, limit) {
  if (value === undefined || value === null) return ""
  var max = limit || MAX_TEXT
  var text = String(value).replace(/[\u0000-\u001f\u007f]+/g, " ").trim()
  return text.length > max ? text.slice(0, max) : text
}

// For sinks whose text format the plugin cannot set (the shared bar
// tooltip): swap the angle brackets that would let Qt's AutoText detection
// treat the string as rich text for look-alike guillemets.
function plain(value, limit) {
  return cleanText(value, limit).replace(/</g, "‹").replace(/>/g, "›")
}

function truncate(value, maxChars) {
  var text = cleanText(value)
  var max = Math.max(1, maxChars | 0)
  var chars = Array.from(text)
  return chars.length > max ? chars.slice(0, max - 1).join("").replace(/\s+$/, "") +"…" : text
}

function pad2(n, formatNumber) {
  return n < 10 ? formatNumber(0) + formatNumber(n) : formatNumber(n)
}

// 75 -> "1:15", 3725 -> "1:02:05". formatNumber localizes the digits.
function formatTime(seconds, formatNumber) {
  var fmt = formatNumber || function(n) { return String(n) }
  var total = Math.max(0, Math.floor(Number(seconds) || 0))
  var h = Math.floor(total / 3600)
  var m = Math.floor((total % 3600) / 60)
  var s = total % 60
  if (h > 0) return fmt(h) + ":" + pad2(m, fmt) + ":" + pad2(s, fmt)
  return fmt(m) + ":" + pad2(s, fmt)
}

function validCount(value) {
  return typeof value === "number" && isFinite(value) && value >= 0 && value < 1000000 ? Math.floor(value) : null
}

function sanitizePlaylists(items) {
  var out = []
  var seen = {}
  if (!Array.isArray(items)) return out
  for (var i = 0; i < items.length && out.length < MAX_PLAYLISTS; i++) {
    var p = items[i]
    if (!p || typeof p !== "object") continue
    var id = String(p.id || "")
    if (!PLAYLIST_ID_RE.test(id) || seen[id]) continue
    seen[id] = true
    out.push({ id: id, title: cleanText(p.title) || id, count: validCount(p.count) })
  }
  return out
}

function sanitizeTracks(items) {
  var out = []
  if (!Array.isArray(items)) return out
  for (var i = 0; i < items.length && out.length < MAX_TRACKS; i++) {
    var t = items[i]
    if (!t || typeof t !== "object") continue
    var id = String(t.id || "")
    if (!VIDEO_ID_RE.test(id)) continue
    var d = Number(t.duration)
    out.push({
      id: id,
      title: cleanText(t.title) || id,
      artist: cleanText(t.artist),
      duration: isFinite(d) && d >= 0 && d < 86400 ? Math.floor(d) : null
    })
  }
  return out
}

// One line of helper output -> a sanitized message, or null if unusable.
function parseLine(line) {
  var msg
  try { msg = JSON.parse(String(line || "")) } catch (e) { return null }
  if (!msg || typeof msg !== "object") return null
  switch (msg.type) {
  case "playlists":
    return { type: "playlists", stale: msg.stale === true, items: sanitizePlaylists(msg.items) }
  case "tracks":
    if (!PLAYLIST_ID_RE.test(String(msg.playlistId || ""))) return null
    return {
      type: "tracks",
      stale: msg.stale === true,
      playlistId: String(msg.playlistId),
      title: cleanText(msg.title),
      items: sanitizeTracks(msg.items)
    }
  case "playing":
    return { type: "playing", index: validCount(msg.index) || 0, count: validCount(msg.count) || 0 }
  case "stopped":
    return { type: "stopped" }
  case "radio":
    return { type: "radio", mode: String(msg.mode || ""), added: validCount(msg.added) || 0 }
  case "error":
    return { type: "error", message: cleanText(msg.message) }
  default:
    return null
  }
}

// The session file the helper writes when playback starts.
function parseSession(text) {
  var data
  try { data = JSON.parse(String(text || "")) } catch (e) { return null }
  if (!data || typeof data !== "object") return null
  var id = String(data.playlistId || "")
  if (!PLAYLIST_ID_RE.test(id)) return null
  return {
    playlistId: id,
    playlistTitle: cleanText(data.playlistTitle),
    shuffle: data.shuffle === true,
    autoplay: data.autoplay === true,
    tracks: sanitizeTracks(data.tracks)
  }
}

function clampIndex(index, delta, count) {
  if (count <= 0) return -1
  if (index < 0) return delta < 0 ? count - 1 : 0
  return Math.max(0, Math.min(count - 1, index + delta))
}

// mpv JSON IPC: one event or reply per line.
function parseMpvLine(line) {
  var msg
  try { msg = JSON.parse(String(line || "")) } catch (e) { return null }
  return msg && typeof msg === "object" ? msg : null
}

function mpvCommand(args, requestId) {
  var msg = { command: args }
  if (requestId !== undefined) msg.request_id = requestId
  return JSON.stringify(msg) + "\n"
}

// Properties the widget follows; the index is the observe id.
var OBSERVED = ["pause", "media-title", "duration", "playlist-pos", "playlist-count", "volume", "idle-active",
  "loop-file", "loop-playlist"]
