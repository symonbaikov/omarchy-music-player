.pragma library

// Pure helpers for the YouTube Music (mpv) widget. Everything here is free of
// QML types so tests/model.test.mjs can run it under node.

var MAX_PLAYLISTS = 500
var MAX_TRACKS = 5000
var MAX_TEXT = 300

// A list: a YouTube playlist id, or one of the other services' lists
// (sc:… SoundCloud, sp:… Spotify, mix:… your mixes, cl:… your cloud storage:
// a source, or one folder in it).
var PLAYLIST_ID_RE = /^(?:[A-Za-z0-9_-]{2,80}|sc:(?:likes|sets):[A-Za-z0-9_-]{1,100}|sc:set:[A-Za-z0-9_-]{1,100}\/[A-Za-z0-9_-]{1,200}|sc:search|sp:liked|sp:pl:[A-Za-z0-9]{22}|mix:all|mix:[a-f0-9]{8}|cl:[a-f0-9]{8}(?::[a-f0-9]{16})?)$/
var VIDEO_ID_RE = /^[A-Za-z0-9_-]{11}$/
// A track from any service: a YouTube video id, sc:…, sp:… or cl:….
var TRACK_KEY_RE = /^(?:[A-Za-z0-9_-]{11}|sc:(?:[0-9]{1,20}|[A-Za-z0-9_-]{1,100}\/[A-Za-z0-9_-]{1,200})|sp:[A-Za-z0-9]{22}|cl:[a-f0-9]{8}\/[a-f0-9]{16})$/
var SERVICES = ["yt", "sp", "sc", "cl", "my"]
// Kinds of storage the "Connect storage" form offers (see the helper's
// CLOUD_KINDS), with the fields each asks for.
var CLOUD_KINDS = [
  { id: "drive", label: "Google Drive", oauth: true, fields: [] },
  { id: "dropbox", label: "Dropbox", oauth: true, fields: [] },
  { id: "onedrive", label: "OneDrive", oauth: true, fields: [] },
  { id: "s3", label: "S3", fields: ["endpoint", "region", "access_key_id", "secret_access_key"] },
  { id: "sftp", label: "SFTP", fields: ["host", "port", "user", "pass"] },
  { id: "smb", label: "SMB", fields: ["host", "user", "pass", "domain"] },
  { id: "webdav", label: "WebDAV", fields: ["url", "user", "pass"] },
  { id: "ftp", label: "FTP", fields: ["host", "port", "user", "pass"] },
  { id: "remote", label: "rclone", fields: [] }
]
var SECRET_FIELDS = ["pass", "secret_access_key"]

function serviceOf(key) {
  var k = String(key || "")
  return k.indexOf("sc:") === 0 ? "sc" : k.indexOf("sp:") === 0 ? "sp" : k.indexOf("cl:") === 0 ? "cl" : "yt"
}

// Liking, adding to a YouTube playlist and radio are YouTube Music's.
function isYouTube(key) {
  return VIDEO_ID_RE.test(String(key || ""))
}
var MOOD_ID_RE = /^[A-Za-z0-9_%=-]{1,400}$/
var DOWNLOAD_FORMATS = ["mp3", "m4a", "opus", "flac", "wav"]

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
  autoplay: String.fromCodePoint(0xF06E4),
  loading: String.fromCodePoint(0xF0772),
  heartOutline: String.fromCodePoint(0xF02D5),
  playlistAdd: String.fromCodePoint(0xF0412),
  check: String.fromCodePoint(0xF012C),
  login: String.fromCodePoint(0xF0342),
  settings: String.fromCodePoint(0xF0493),
  youtube: String.fromCodePoint(0xF05C3),
  spotify: String.fromCodePoint(0xF04C7),
  soundcloud: String.fromCodePoint(0xF04C0),
  alert: String.fromCodePoint(0xF0026),
  explore: String.fromCodePoint(0xF018B),
  search: String.fromCodePoint(0xF0349),
  download: String.fromCodePoint(0xF01DA),
  folder: String.fromCodePoint(0xF024B),
  mood: String.fromCodePoint(0xF0F72),
  album: String.fromCodePoint(0xF0025),
  cloud: String.fromCodePoint(0xF015F),
  fullscreen: String.fromCodePoint(0xF0293),
  fullscreenExit: String.fromCodePoint(0xF0294),
  home: String.fromCodePoint(0xF02DC),
  close: String.fromCodePoint(0xF0156),
  plus: String.fromCodePoint(0xF0415),
  queue: String.fromCodePoint(0xF0CB8),
  chevronDown: String.fromCodePoint(0xF0140),
  artist: String.fromCodePoint(0xF0803),
  lyrics: String.fromCodePoint(0xF1021),
  notes: String.fromCodePoint(0xF0387),
  guitar: String.fromCodePoint(0xF02A4),
  piano: String.fromCodePoint(0xF0747)
}

// A local cover the helper saved (downloads, cloud folders), or one of the
// services' own image hosts.
var LOCAL_COVER_RE = /^\/[^\0]*\/covers\/[A-Za-z0-9_-]{11,60}\.(?:jpg|png)$/

function validCover(value) {
  var c = String(value || "")
  return LOCAL_COVER_RE.test(c) || REMOTE_COVER_RE.test(c) ? c : ""
}

// ---- library edits (like, add to playlist) ---------------------------------------

// Playlists a song can be added to: not Liked Music (that's the heart) and
// not YouTube's generated mixes.
function addTargets(playlists) {
  var out = []
  if (!Array.isArray(playlists)) return out
  for (var i = 0; i < playlists.length; i++) {
    var p = playlists[i]
    if (p && p.id !== "LM" && !isMix(p.id)) out.push(p)
  }
  return out
}

// Playlists from YouTube Music's own add-to-playlist dialog: the ones you
// can edit, with `contains` when the song is already there.
function sanitizeTargets(items) {
  var out = []
  var seen = {}
  if (!Array.isArray(items)) return out
  for (var i = 0; i < items.length && out.length < MAX_PLAYLISTS; i++) {
    var p = items[i]
    if (!p || typeof p !== "object") continue
    var id = String(p.id || "")
    if (!PLAYLIST_ID_RE.test(id) || seen[id] || id === "LM" || isMix(id)) continue
    seen[id] = true
    out.push({ id: id, title: cleanText(p.title) || id, count: null, contains: p.contains === true })
  }
  return out
}

// Liked video ids as a lookup object.
function likedSet(ids) {
  var set = {}
  if (!Array.isArray(ids)) return set
  for (var i = 0; i < ids.length; i++) {
    if (VIDEO_ID_RE.test(String(ids[i]))) set[ids[i]] = true
  }
  return set
}

// A copy of `set` with `id` liked or not, so QML sees a new object.
function withLiked(set, id, liked) {
  var out = {}
  for (var k in set) if (set[k]) out[k] = true
  if (VIDEO_ID_RE.test(String(id))) {
    if (liked) out[id] = true
    else delete out[id]
  }
  return out
}

// ---- loading -------------------------------------------------------------------

// Whether playback is waiting on the network, from mpv's own properties:
// - `seeking` is unavailable (undefined/null) while a track is being opened,
//   from start-file until playback actually starts, and true during a seek
//   until the data at the new position arrives;
// - `paused-for-cache` is true when the buffer ran dry mid-track.
// `starting` covers the helper launching mpv before it is reachable at all.
function isLoading(s) {
  if (!s) return false
  if (s.starting) return true
  if (!s.connected) return false
  return s.seeking === undefined || s.seeking === null || s.seeking === true || s.pausedForCache === true
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
// The cover to show for a track: a downloaded song's own saved cover, none
// for a downloaded song saved without one, else YouTube's thumbnail.
// Spotify's album images and SoundCloud's artwork, the only remote covers
// besides YouTube's own thumbnails.
var REMOTE_COVER_RE = /^https:\/\/(?:i\.scdn\.co\/image\/[A-Za-z0-9]{1,100}|i[0-9]?\.sndcdn\.com\/[A-Za-z0-9_.\/-]{1,300}|(?:(?:lh3|yt3)\.googleusercontent\.com|yt3\.ggpht\.com|i[0-9]?\.ytimg\.com)\/[A-Za-z0-9_.\/=%~&?-]{1,500})$/

function trackCover(track, size) {
  if (!track) return ""
  if (track.cover) return REMOTE_COVER_RE.test(track.cover) ? track.cover : "file://" + track.cover
  if (track.path) return ""
  return coverUrl(track.id, size)
}

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
    if (!(PLAYLIST_ID_RE.test(id) || id === "DOWNLOADS") || seen[id]) continue
    seen[id] = true
    var list = { id: id, title: cleanText(p.title) || id, count: validCount(p.count) }
    if (p.subtitle) list.subtitle = cleanText(p.subtitle, 120)
    if (validCover(p.cover)) list.cover = validCover(p.cover)
    out.push(list)
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
    if (!TRACK_KEY_RE.test(id)) continue
    var d = Number(t.duration)
    var track = {
      id: id,
      title: cleanText(t.title) || id,
      artist: cleanText(t.artist),
      duration: isFinite(d) && d > 0 && d < 86400 ? Math.floor(d) : null
    }
    // A downloaded song: its file, and the cover saved with it (if any).
    if (typeof t.path === "string" && t.path.charAt(0) === "/") track.path = t.path
    if (validCover(t.cover)) track.cover = t.cover
    if (t.album) track.album = cleanText(t.album, 200)
    out.push(track)
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
    return { type: "playlists", stale: msg.stale === true, items: sanitizePlaylists(msg.items),
      service: SERVICES.indexOf(msg.service) >= 0 ? msg.service : "yt" }
  case "mixAdded":
    if (!/^mix:[a-f0-9]{8}$/.test(String(msg.id || ""))) return null
    return { type: "mixAdded", id: String(msg.id), title: cleanText(msg.title, 80), already: msg.already === true }
  case "spotify":
    return { type: "spotify", state: ["waiting", "connected", "disconnected"].indexOf(msg.state) >= 0 ? msg.state : "",
      user: cleanText(msg.user, 80) }
  case "tracks":
    if (!(PLAYLIST_ID_RE.test(String(msg.playlistId || "")) || msg.playlistId === "DOWNLOADS")) return null
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
  case "liked":
    if (!VIDEO_ID_RE.test(String(msg.id || ""))) return null
    return { type: "liked", id: String(msg.id), liked: msg.liked === true }
  case "added":
    if (!VIDEO_ID_RE.test(String(msg.id || "")) || !PLAYLIST_ID_RE.test(String(msg.playlistId || ""))) return null
    return { type: "added", id: String(msg.id), playlistId: String(msg.playlistId) }
  case "likedIds":
    return { type: "likedIds", known: msg.known === true,
      ids: Array.isArray(msg.ids) ? msg.ids.slice(0, MAX_TRACKS).filter(function(id) { return VIDEO_ID_RE.test(String(id)) }) : [] }
  case "error":
    // `auth`: a sign-in problem, so the panel offers a "Sign in" button.
    // `setup`: a service that needs connecting first (sp, sc).
    return { type: "error", message: cleanText(msg.message), auth: msg.auth === true,
      setup: ["sp", "sc", "cl", "rclone", "numpy"].indexOf(msg.setup) >= 0 ? msg.setup : "",
      service: SERVICES.indexOf(msg.service) >= 0 ? msg.service : "" }
  case "cloud":
    return sanitizeCloud(msg)
  case "lyrics":
    return sanitizeLyrics(msg)
  case "chords":
    return sanitizeChords(msg)
  case "chordsProgress":
    if (!TRACK_KEY_RE.test(String(msg.key || ""))) return null
    return { type: "chordsProgress", key: String(msg.key), stage: msg.stage === "listen" ? "listen" : "audio" }
  case "scores":
    return sanitizeScores(msg)
  case "targets":
    if (!VIDEO_ID_RE.test(String(msg.videoId || ""))) return null
    return { type: "targets", videoId: String(msg.videoId), items: sanitizeTargets(msg.items) }
  case "signin":
    return { type: "signin", browser: cleanText(msg.browser, 60) }
  case "explore":
    return { type: "explore", stale: msg.stale === true, mood: MOOD_ID_RE.test(String(msg.mood || "")) ? String(msg.mood) : "",
      sections: sanitizeSections(msg.sections) }
  case "search":
    return { type: "search", query: cleanText(msg.query, 150), items: sanitizeExploreItems(msg.items) }
  case "downloading":
    if (!TRACK_KEY_RE.test(String(msg.id || ""))) return null
    return { type: "downloading", id: String(msg.id), stage: msg.stage === "convert" ? "convert" : "fetch" }
  case "downloaded":
    if (!TRACK_KEY_RE.test(String(msg.id || "")) || typeof msg.path !== "string" || msg.path.charAt(0) !== "/") return null
    return { type: "downloaded", id: String(msg.id), path: cleanText(msg.path, 1000), folder: cleanText(msg.folder, 1000) }
  case "cookies":
    if (["idle", "applied"].indexOf(msg.state) < 0) return null
    return { type: "cookies", state: msg.state }
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

// A seconds setting from shell.json: a number within [lo, hi], or `fallback`.
function seconds(value, lo, hi, fallback) {
  var n = Number(value)
  if (value === null || value === "" || !isFinite(n)) return fallback
  return Math.max(lo, Math.min(hi, n))
}

// The option after (delta 1) or before (-1) `value` in `options`, stopping
// at the ends. An unknown value starts from the first option.
function stepChoice(options, value, delta) {
  var i = options.indexOf(value)
  if (i < 0) return options[0]
  return options[Math.max(0, Math.min(options.length - 1, i + delta))]
}

// A report from the player's script, if it is recent: observing a
// property also delivers its current (old) value on every reconnect.
function recentReport(data, nowSeconds) {
  if (!data || typeof data !== "object") return null
  var at = Number(data.at)
  if (!isFinite(at) || Math.abs(nowSeconds - at) > 20) return null
  return data
}

// A song no YouTube source could play, reported by the player's script:
// worth offering backup mirrors when they are off and could help (not for
// members-only, private or removed songs). Returns { id, reason } or null.
function mirrorOffer(report, mirrorsOn) {
  if (!report || mirrorsOn || report.hopeless === true || report.mirrors !== "off") return null
  var id = String(report.id || "")
  if (!VIDEO_ID_RE.test(id)) return null
  var reason = cleanText(report.reason, 300).replace(/^\[[^\]]*\] [A-Za-z0-9_-]{11}: /, "")
  var cut = reason.search(/\.\s/)
  if (cut > 0) reason = reason.slice(0, cut + 1)
  return { id: id, reason: truncate(reason, 160) }
}

// The helper's update-check line: { state, version, current, notes } or null.
function parseUpdate(line) {
  var msg
  try { msg = JSON.parse(String(line || "")) } catch (e) { return null }
  if (!msg || msg.type !== "update") return null
  var state = ["available", "current", "unmanaged", "error"].indexOf(msg.state) >= 0 ? msg.state : null
  if (!state) return null
  return {
    state: state,
    version: cleanText(msg.version, 20),
    current: cleanText(msg.current, 20),
    notes: Array.isArray(msg.notes) ? msg.notes.slice(0, 6).map(function(n) { return cleanText(n, 120) }) : []
  }
}

// Explore entries from the helper: songs play, lists open as playlists,
// moods open their playlists. Anything malformed is dropped.
function sanitizeExploreItems(items) {
  var out = []
  if (!Array.isArray(items)) return out
  for (var i = 0; i < items.length && out.length < 60; i++) {
    var it = items[i]
    if (!it || typeof it !== "object") continue
    var id = String(it.id || "")
    var ok = it.kind === "song" ? TRACK_KEY_RE.test(id) : it.kind === "list" ? PLAYLIST_ID_RE.test(id)
      : it.kind === "mood" ? MOOD_ID_RE.test(id) : false
    if (!ok) continue
    out.push({
      kind: it.kind, id: id, title: cleanText(it.title) || id,
      artist: cleanText(it.artist || it.subtitle, 120),
      duration: typeof it.duration === "number" && it.duration > 0 && it.duration < 86400 ? it.duration : null,
      cover: REMOTE_COVER_RE.test(String(it.cover || "")) ? String(it.cover) : undefined
    })
  }
  return out
}

function sanitizeSections(sections) {
  var out = []
  if (!Array.isArray(sections)) return out
  for (var i = 0; i < sections.length && out.length < 12; i++) {
    var s = sections[i]
    if (!s || typeof s !== "object") continue
    var items = sanitizeExploreItems(s.items)
    if (items.length > 0) out.push({ title: cleanText(s.title, 80), items: items })
  }
  return out
}

// Sections as one list of rows, each carrying its section's title (the
// list view draws the headers).
function exploreRows(sections) {
  var rows = []
  for (var i = 0; i < sections.length; i++) {
    for (var j = 0; j < sections[i].items.length; j++) {
      var it = sections[i].items[j]
      rows.push({ kind: it.kind, id: it.id, title: it.title, artist: it.artist, duration: it.duration,
        section: sections[i].title })
    }
  }
  return rows
}

function clampIndex(index, delta, count) {
  if (count <= 0) return -1
  if (index < 0) return delta < 0 ? count - 1 : 0
  return Math.max(0, Math.min(count - 1, index + delta))
}

// mpv JSON IPC: one event or reply per line.
// Why mpv skipped a track. mpv's ytdl hook logs yt-dlp's failure at error
// level as "ERROR: [youtube] <id>: <reason>"; the widget receives it over IPC
// (request_log_messages). Returns { id, reason, account } or null.
// `account` is true for reasons a signed-in account can get past
// (members-only, sign-in, age check, private).
var ACCOUNT_REASON_RE = /member|sign in|log ?in|confirm your age|age[- ]restrict|private|premium|cookies/i
function playbackFailure(text) {
  if (typeof text !== "string") return null
  var lines = text.split("\n")
  for (var i = lines.length - 1; i >= 0; i--) {
    var m = /^ERROR: \[[^\]]*\] ([A-Za-z0-9_-]{11}): (.+)$/.exec(lines[i].replace(/\s+$/, ""))
    if (!m) continue
    var reason = cleanText(m[2], 300)
    // YouTube's reasons run long; the first sentence says it.
    var cut = reason.search(/\.\s/)
    if (cut > 0) reason = reason.slice(0, cut + 1)
    return { id: m[1], reason: truncate(reason, 160), account: ACCOUNT_REASON_RE.test(reason) }
  }
  return null
}

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
// user-data/ytmusic/*: set by the player's own script (mpv/ytmusic.lua)
// when a song came from a backup source, and when songs keep failing.
var OBSERVED = ["user-data/ytmusic/fallback", "user-data/ytmusic/health", "user-data/ytmusic/unplayable",
  "pause", "media-title", "duration", "playlist-pos", "playlist-count", "volume", "idle-active",
  "loop-file", "loop-playlist", "seeking", "paused-for-cache"]

// ---- cloud storage ------------------------------------------------------------

// The helper's "cloud" messages: the connected sources and rclone's remotes
// (state "list"), or how connecting one is going.
function sanitizeCloud(msg) {
  var states = ["list", "waiting", "checking", "added", "removed", "stopped", "kept"]
  var state = states.indexOf(msg.state) >= 0 ? msg.state : ""
  if (!state) return null
  var out = { type: "cloud", state: state, rclone: msg.rclone !== false, sources: [], remotes: [],
    id: /^[a-f0-9]{8}$/.test(String(msg.id || "")) ? String(msg.id) : "", title: cleanText(msg.title, 80),
    kind: cleanText(msg.kind, 20) }
  var src = Array.isArray(msg.sources) ? msg.sources : []
  for (var i = 0; i < src.length && out.sources.length < 50; i++) {
    var s = src[i]
    if (!s || !/^[a-f0-9]{8}$/.test(String(s.id || ""))) continue
    out.sources.push({ id: String(s.id), title: cleanText(s.title, 80), kind: cleanText(s.kind, 20),
      remote: cleanText(s.remote, 64), path: cleanText(s.path, 300) })
  }
  var rem = Array.isArray(msg.remotes) ? msg.remotes : []
  for (var j = 0; j < rem.length && out.remotes.length < 100; j++) {
    var r = rem[j]
    if (!r || !/^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$/.test(String(r.name || ""))) continue
    out.remotes.push({ name: String(r.name), type: cleanText(r.type, 40) })
  }
  return out
}

// The JSON the "Connect storage" form sends to `cloud-add` on stdin: only
// the fields that kind of storage takes, trimmed.
function cloudForm(kind, values, remote, path, title) {
  var spec = null
  for (var i = 0; i < CLOUD_KINDS.length; i++) if (CLOUD_KINDS[i].id === kind) spec = CLOUD_KINDS[i]
  if (!spec) return null
  var fields = {}
  for (var j = 0; j < spec.fields.length; j++) {
    var v = String((values || {})[spec.fields[j]] || "").trim()
    if (v !== "") fields[spec.fields[j]] = v
  }
  var form = { kind: kind, path: String(path || "").trim(), title: String(title || "").trim(), fields: fields }
  if (kind === "remote") form.remote = String(remote || "")
  return JSON.stringify(form)
}

// A stable hue (0-1) for a list without a cover: the full-screen view's
// tiles, so each playlist keeps its color.
function tileHue(id) {
  var text = String(id || "")
  var hash = 0
  for (var i = 0; i < text.length; i++) hash = (hash * 31 + text.charCodeAt(i)) >>> 0
  return (hash % 360) / 360
}

// ---- lyrics ----------------------------------------------------------------

// The helper's lyrics for a song: timed lines ({ t, text }, in order) when
// `synced`, else the plain text's lines.
function sanitizeLyrics(msg) {
  if (!TRACK_KEY_RE.test(String(msg.key || ""))) return null
  var out = { type: "lyrics", key: String(msg.key), lines: [], synced: false,
    instrumental: msg.instrumental === true, none: msg.none === true, source: cleanText(msg.source, 80) }
  if (Array.isArray(msg.synced) && msg.synced.length > 0) {
    var last = -1
    for (var i = 0; i < msg.synced.length && out.lines.length < 600; i++) {
      var l = msg.synced[i]
      if (!Array.isArray(l) || typeof l[0] !== "number" || !isFinite(l[0]) || l[0] < 0 || l[0] > 86400 || l[0] < last) continue
      last = l[0]
      out.lines.push({ t: l[0], text: cleanText(l[1], 300) })
    }
    out.synced = out.lines.length > 0
  } else if (typeof msg.plain === "string") {
    var plain = msg.plain.split(/\r?\n/)
    for (var j = 0; j < plain.length && out.lines.length < 600; j++) out.lines.push({ t: -1, text: cleanText(plain[j], 300) })
  }
  return out
}

// The line playing at `seconds`: the last one that has started (-1 before
// the first).
function lyricIndex(lines, seconds) {
  var lo = 0, hi = (lines ? lines.length : 0) - 1, found = -1
  while (lo <= hi) {
    var mid = (lo + hi) >> 1
    if (lines[mid].t <= seconds) { found = mid; lo = mid + 1 } else hi = mid - 1
  }
  return found
}

// ---- notes: chords and scores ------------------------------------------------

var CHORD_RE = /^(?:[A-G]#?m?|N)$/
var NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

// The helper's chords for a song: segments { start, end, name } in order,
// and its key ("A minor").
function sanitizeChords(msg) {
  if (!TRACK_KEY_RE.test(String(msg.key || ""))) return null
  var out = { type: "chords", key: String(msg.key), songKey: /^[A-G]#? (major|minor)$/.test(String(msg.songKey || "")) ? String(msg.songKey) : "",
    segments: [] }
  var segs = Array.isArray(msg.segments) ? msg.segments : []
  var last = -1
  for (var i = 0; i < segs.length && out.segments.length < 2000; i++) {
    var s = segs[i]
    if (!Array.isArray(s) || typeof s[0] !== "number" || typeof s[1] !== "number" || !CHORD_RE.test(String(s[2]))) continue
    if (s[0] < last || s[1] < s[0] || s[1] > 86400) continue
    last = s[0]
    out.segments.push({ t: s[0], end: s[1], name: String(s[2]) })
  }
  return out
}

var SCORE_URL_RE = /^https:\/\/(?:www\.songsterr\.com\/a\/wsa\/[a-z0-9-]{1,200}-tab-s[0-9]{1,12}|musescore\.com\/sheetmusic\?text=[A-Za-z0-9%._~-]{0,600}|www\.ultimate-guitar\.com\/search\.php\?search_type=title&value=[A-Za-z0-9%._~-]{0,600})$/

function sanitizeScores(msg) {
  if (!TRACK_KEY_RE.test(String(msg.key || ""))) return null
  var out = { type: "scores", key: String(msg.key), items: [], query: cleanText(msg.query, 200),
    musescore: SCORE_URL_RE.test(String(msg.musescore || "")) ? String(msg.musescore) : "",
    ultimateGuitar: SCORE_URL_RE.test(String(msg.ultimateGuitar || "")) ? String(msg.ultimateGuitar) : "" }
  var items = Array.isArray(msg.items) ? msg.items : []
  for (var i = 0; i < items.length && out.items.length < 6; i++) {
    var it = items[i]
    if (!it || !SCORE_URL_RE.test(String(it.url || ""))) continue
    out.items.push({ title: cleanText(it.title, 120), artist: cleanText(it.artist, 120), url: String(it.url),
      instruments: Array.isArray(it.instruments) ? it.instruments.slice(0, 8).map(function(x) { return cleanText(x, 40) }) : [] })
  }
  return out
}

// A chord's notes as pitch classes (0 = C): root, third, fifth.
function chordTones(name) {
  var m = /^([A-G]#?)(m?)$/.exec(String(name || ""))
  if (!m) return []
  var root = NOTE_NAMES.indexOf(m[1])
  return [root, (root + (m[2] ? 3 : 4)) % 12, (root + 7) % 12]
}

// Flats where musicians write them: B♭ rather than A#, and the notes of a
// flat-side chord (F, B♭, E♭, A♭, Dm, Gm, Cm, Fm …) spelled with flats.
var FLAT_NAMES = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]
var FLAT_ROOTS = { "A#": "B♭", "D#": "E♭", "G#": "A♭" }
var FLAT_SIDE = ["F", "A#", "D#", "G#", "C#", "Dm", "Gm", "Cm", "Fm", "A#m", "D#m"]

function chordLabel(name) {
  var m = /^([A-G]#?)(m?)$/.exec(String(name || ""))
  if (!m) return String(name || "")
  return (FLAT_ROOTS[m[1]] || m[1]) + m[2]
}

function keyLabel(key) {
  var m = /^([A-G]#?) (major|minor)$/.exec(String(key || ""))
  return m ? (FLAT_ROOTS[m[1]] || m[1]) + " " + m[2] : ""
}

function chordNoteNames(name) {
  var names = FLAT_SIDE.indexOf(String(name)) >= 0 ? FLAT_NAMES : NOTE_NAMES
  return chordTones(name).map(function(pc) { return names[pc] })
}

// Guitar shapes for the 24 triads, low E string first: fret numbers, -1 =
// not played, 0 = open. The usual open chords, barre chords elsewhere.
var GUITAR_SHAPES = {
  "C": [-1, 3, 2, 0, 1, 0], "C#": [-1, 4, 6, 6, 6, 4], "D": [-1, -1, 0, 2, 3, 2], "D#": [-1, 6, 8, 8, 8, 6],
  "E": [0, 2, 2, 1, 0, 0], "F": [1, 3, 3, 2, 1, 1], "F#": [2, 4, 4, 3, 2, 2], "G": [3, 2, 0, 0, 0, 3],
  "G#": [4, 6, 6, 5, 4, 4], "A": [-1, 0, 2, 2, 2, 0], "A#": [-1, 1, 3, 3, 3, 1], "B": [-1, 2, 4, 4, 4, 2],
  "Cm": [-1, 3, 5, 5, 4, 3], "C#m": [-1, 4, 6, 6, 5, 4], "Dm": [-1, -1, 0, 2, 3, 1], "D#m": [-1, 6, 8, 8, 7, 6],
  "Em": [0, 2, 2, 0, 0, 0], "Fm": [1, 3, 3, 1, 1, 1], "F#m": [2, 4, 4, 2, 2, 2], "Gm": [3, 5, 5, 3, 3, 3],
  "G#m": [4, 6, 6, 4, 4, 4], "Am": [-1, 0, 2, 2, 1, 0], "A#m": [-1, 1, 3, 3, 2, 1], "Bm": [-1, 2, 4, 4, 3, 2]
}

// What a guitar diagram draws: the first fret shown (1 for open shapes),
// and each string's dot relative to it (0 = open, -1 = muted).
function guitarDiagram(name) {
  var shape = GUITAR_SHAPES[name]
  if (!shape) return null
  var fretted = shape.filter(function(f) { return f > 0 })
  var low = Math.min.apply(null, fretted)
  var high = Math.max.apply(null, fretted)
  var base = high <= 4 ? 1 : low
  return { base: base, strings: shape.map(function(f) { return f <= 0 ? f : f - base + 1 }) }
}
