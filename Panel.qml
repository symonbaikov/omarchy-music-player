import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// YouTube Music without a browser: bar button + keyboard panel that lists
// the library's playlists and tracks (via bin/ytmusic-mpv, which runs
// yt-dlp) and drives a headless mpv over its JSON IPC socket.
Panel {
  id: root
  moduleName: "io.github.symonbaikov.ytmusic-mpv"
  ipcTarget: "io.github.symonbaikov.ytmusic-mpv"
  // Own the IPC target so it can carry playback methods too.
  manageIpc: false

  readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("bin/ytmusic-mpv").toString().replace(/^file:\/\//, ""))

  // ---- settings ------------------------------------------------------------
  readonly property string browser: String(setting("browser", "chromium")).trim() || "none"
  readonly property bool playbackCookies: setting("playbackCookies", "Off") === "On"
  readonly property bool showTitle: setting("showTitle", "On") !== "Off"
  readonly property int defaultVolume: Math.max(0, Math.min(100, Number(setting("defaultVolume", 60)) || 0))
  readonly property bool showCovers: setting("showCovers", "On") !== "Off"
  readonly property bool autoplayEnabled: setting("autoplay", "On") !== "Off"

  // A running player follows the cookie settings from its next track on:
  // turning playback cookies off, or choosing browser "none", revokes them.
  onBrowserChanged: syncPlayerCookies()
  onPlaybackCookiesChanged: syncPlayerCookies()

  // ---- look ----------------------------------------------------------------
  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool barVertical: bar ? bar.vertical === true : false

  // ---- library state -------------------------------------------------------
  property string view: "playlists"          // "playlists" | "tracks" | "addTo"
  property var playlists: []
  property bool playlistsLoading: false
  property string playlistsError: ""
  property var openPlaylist: null            // { id, title, count }
  property var tracks: []
  property bool tracksLoading: false
  property string tracksError: ""
  property int cursorIndex: -1
  readonly property var rows: view === "tracks" ? tracks
    : (view === "addTo" ? (addTargetsLive !== null ? addTargetsLive : (addTargetsLoading ? [] : Model.addTargets(playlists)))
    : playlists)
  // YouTube Music's own add-to-playlist list for `addTrack`: only playlists
  // you can edit, marked when the song is already in them. null until it
  // arrives; if it can't be read, the library's playlists stand in.
  property var addTargetsLive: null
  property bool addTargetsLoading: false
  // The notice is a sign-in problem: offer a "Sign in" button with it.
  property bool noticeAuth: false
  property bool noticeLong: false
  // A skipped song that the account may be able to play (members-only …):
  // the notice offers to turn playback cookies on and play it again.
  property string noticeRetryId: ""
  property string retryVideoId: ""

  // ---- library edits (like, add to playlist) --------------------------------
  // Liked video ids, from the local Liked Music list; updated at once when
  // the heart is pressed and rolled back if YouTube refuses.
  property var likedIds: ({})
  // The song being added to a playlist (the "addTo" view), and the view to
  // return to afterwards.
  property var addTrack: null
  property string viewBeforeAdd: "playlists"
  // A short message under the controls ("Added to …", errors).
  property string notice: ""
  readonly property bool editBusy: likeProc.running || addProc.running

  // ---- player state (mirrored from mpv) -------------------------------------
  property string socketPath: ""
  property string sessionPath: ""
  property bool paused: false
  property string mediaTitle: ""
  property real duration: 0
  property real position: 0
  property int playlistPos: -1
  property int playlistCount: 0
  property real volume: defaultVolume
  property var session: null
  property bool starting: false
  property string playError: ""
  // Repeat mode: the user's choice (saved in the widget's settings, so it
  // survives restarts like Apple Music's), kept in step with mpv's
  // loop-file / loop-playlist while a player is running.
  property string repeatMode: Model.normalizeRepeat(setting("repeat", "off"))
  property var loopFileRaw: false
  property var loopPlaylistRaw: false
  // Video id whose 1280px cover 404'd; the hero then uses the 320px one.
  property string largeCoverFailedFor: ""
  // Recommendations: the song whose radio autoplay last asked for, so each
  // last-song triggers it once.
  property string autoplayRequested: ""
  readonly property bool radioBusy: radioProc.running
  // Loading: mpv's `seeking` (unavailable while a track opens, true during a
  // seek) and `paused-for-cache` (buffer ran dry). See Model.isLoading.
  property var seekingRaw: false
  property bool pausedForCache: false
  readonly property bool loadingRaw: Model.isLoading({
    starting: starting, connected: connected, seeking: seekingRaw, pausedForCache: pausedForCache
  })
  // Shown only once loading has lasted a moment: on a fast connection a seek
  // finishes within a frame, and a spinner flashing for it would be noise.
  property bool loading: false
  onLoadingRawChanged: {
    if (loadingRaw) loadingDelay.restart()
    else {
      loadingDelay.stop()
      loading = false
    }
  }
  Timer {
    id: loadingDelay
    interval: 250
    onTriggered: root.loading = root.loadingRaw
  }
  // Drives the bar icon's spin; constant motion, so linear.
  property real spinAngle: 0
  NumberAnimation on spinAngle {
    from: 0
    to: 360
    duration: 900
    loops: Animation.Infinite
    running: root.loading && !Style.reduceMotion
  }

  readonly property bool connected: mpvSocket.connected
  readonly property bool playing: connected && !paused
  readonly property var currentTrack: connected && session && playlistPos >= 0 && playlistPos < session.tracks.length
    ? session.tracks[playlistPos] : null
  readonly property string nowTitle: currentTrack ? currentTrack.title : Model.cleanText(mediaTitle)
  readonly property string nowArtist: currentTrack ? currentTrack.artist : ""
  readonly property string barLabel: showTitle && connected && !barVertical && nowTitle !== "" ? Model.truncate(nowTitle, 28) : ""
  // Non-empty when autoplay should extend the queue from this song now.
  readonly property string autoplayDueSeed: Model.autoplaySeed({
    enabled: autoplayEnabled, connected: connected, repeat: repeatMode,
    pos: playlistPos, count: playlistCount,
    trackId: currentTrack ? currentTrack.id : "", requested: autoplayRequested
  })
  onAutoplayDueSeedChanged: if (autoplayDueSeed !== "") runAutoplay(autoplayDueSeed)
  readonly property string nowCoverUrl: showCovers && currentTrack
    ? Model.coverUrl(currentTrack.id, largeCoverFailedFor === currentTrack.id ? "small" : "large") : ""

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function playlistTitle(p) {
    if (!p) return ""
    if (p.id === "LM") return strings.t("list.likedMusic")
    if (p.id === Model.SUPERMIX_ID) return strings.t("list.supermix")
    return p.title
  }

  // ---- helper processes ----------------------------------------------------
  function helper(args) {
    return ["python3", "-I", root.helperPath].concat(args)
  }

  property bool cookieSyncPending: false
  function syncPlayerCookies() {
    cookieSyncPending = true
    runCookieSync()
  }
  // A play or radio started with the old settings runs first; this follows.
  function runCookieSync() {
    if (!cookieSyncPending || cookiesProc.running || playProc.running || radioProc.running) return
    cookieSyncPending = false
    cookiesProc.command = helper(["cookies", "--browser", browser, "--playback-cookies", playbackCookies ? "1" : "0"])
    cookiesProc.running = true
  }

  function loadPlaylists(force) {
    if (playlistsProc.running) return
    playlistsError = ""
    playlistsLoading = true
    playlistsProc.command = helper(["playlists", "--browser", browser, "--max-age", force ? "0" : "3600"])
    playlistsProc.running = true
  }

  function loadTracks(force) {
    if (!openPlaylist) return
    tracksError = ""
    tracksLoading = true
    if (tracksProc.running) {
      // Picked up when the running fetch exits.
      tracksProc.queued = { id: openPlaylist.id, force: force }
      return
    }
    tracksProc.command = helper(["tracks", openPlaylist.id, "--browser", browser, "--max-age", force ? "0" : "3600"])
    tracksProc.running = true
  }

  function handleHelperLine(line, source) {
    var msg = Model.parseLine(line)
    if (!msg) return
    if (msg.type === "playlists") {
      playlists = msg.items
      if (!msg.stale) playlistsLoading = false
    } else if (msg.type === "tracks") {
      // A fresh Liked Music list is the truth about what's liked.
      if (msg.playlistId === "LM" && !msg.stale) likedIds = Model.likedSet(msg.items.map(function(t) { return t.id }))
      if (!openPlaylist || msg.playlistId !== openPlaylist.id) return
      tracks = msg.items
      if (!msg.stale) tracksLoading = false
    } else if (msg.type === "likedIds") {
      likedIds = Model.likedSet(msg.ids)
    } else if (msg.type === "liked") {
      likedIds = Model.withLiked(likedIds, msg.id, msg.liked)
      showNotice(msg.liked ? strings.t("notice.liked") : strings.t("notice.unliked"))
    } else if (msg.type === "added") {
      showNotice(strings.t("notice.added").arg(addProc.title || playlistTitleById(msg.playlistId)))
    } else if (msg.type === "targets") {
      if (addTrack && msg.videoId === addTrack.id) {
        addTargetsLive = msg.items
        addTargetsLoading = false
      }
    } else if (msg.type === "cookies") {
      if (msg.state === "applied" && retryVideoId !== "") retrySkipped()
      else retryVideoId = ""
    } else if (msg.type === "stopped" && source === "cookies") {
      retryVideoId = ""
    } else if (msg.type === "signin") {
      showNotice(strings.t("notice.signinOpened").arg(msg.browser))
    } else if (msg.type === "playing") {
      starting = false
      attachAll()
    } else if (msg.type === "radio") {
      // The queue changed under a running player: every bar re-reads it.
      reloadSessionAll()
    } else if (msg.type === "error") {
      if (source === "playlists") { playlistsError = msg.message; playlistsLoading = false }
      else if (source === "tracks") { tracksError = msg.message; tracksLoading = false }
      else if (source === "like") {
        // Put the heart back the way it was.
        likedIds = Model.withLiked(likedIds, likeProc.videoId, !likeProc.liking)
        showNotice(strings.t("notice.failed").arg(msg.message), msg.auth)
      }
      else if (source === "add") showNotice(strings.t("notice.failed").arg(msg.message), msg.auth)
      else if (source === "targets") {
        // Fall back to the library's playlists; only a sign-in problem is
        // worth telling the user about here.
        addTargetsLoading = false
        if (msg.auth) showNotice(msg.message, true)
      }
      else if (source === "signin") showNotice(msg.message)
      else {
        playError = msg.message
        starting = false
        if (source === "radio") tracksLoading = false
      }
    }
  }

  Process {
    id: pathsProc
    command: root.helper(["paths"])
    stdout: SplitParser {
      onRead: function(line) {
        var msg = Model.parseMpvLine(line)
        if (!msg || msg.type !== "paths") return
        root.sessionPath = String(msg.session || "")
        root.socketPath = String(msg.socket || "")
        // Reattach to a player that outlived a shell reload.
        root.attach()
      }
    }
  }

  Process {
    id: playlistsProc
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "playlists") } }
    onExited: root.playlistsLoading = false
  }

  Process {
    id: tracksProc
    property var queued: null
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "tracks") } }
    onExited: {
      var next = queued
      queued = null
      if (next && root.openPlaylist && next.id === root.openPlaylist.id) {
        command = root.helper(["tracks", next.id, "--browser", root.browser, "--max-age", next.force ? "0" : "3600"])
        running = true
      } else {
        root.tracksLoading = false
      }
    }
  }

  Process {
    id: playProc
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "play") } }
    onExited: {
      root.starting = false
      root.runCookieSync()
    }
  }

  Process {
    id: cookiesProc
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "cookies") } }
    onExited: root.runCookieSync()
  }

  Process {
    id: stopProc
    command: root.helper(["stop"])
  }

  Process {
    id: likedProc
    command: root.helper(["liked"])
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "liked") } }
  }

  Process {
    id: likeProc
    property string videoId: ""
    property bool liking: true
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "like") } }
  }

  Process {
    id: addProc
    property string title: ""
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "add") } }
  }

  Process {
    id: targetsProc
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "targets") } }
    onExited: root.addTargetsLoading = false
  }

  Process {
    id: signinProc
    command: root.helper(["signin", "--browser", root.browser])
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "signin") } }
  }

  Timer {
    id: noticeTimer
    // Sign-in problems stay longer: there's a button to press.
    interval: root.noticeAuth || root.noticeLong ? 12000 : 4000
    onTriggered: {
      root.notice = ""
      root.noticeAuth = false
      root.noticeLong = false
      root.noticeRetryId = ""
    }
  }

  Process {
    id: radioProc
    property string listId: ""
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "radio") } }
    onExited: function(exitCode) {
      root.starting = false
      // The radio's list is cached now: show it if it's the open view.
      if (exitCode === 0 && root.openPlaylist && root.openPlaylist.id === listId) root.loadTracks(false)
      // Autoplay may have come due while this was busy.
      if (root.autoplayDueSeed !== "") root.runAutoplay(root.autoplayDueSeed)
      root.runCookieSync()
    }
  }

  FileView {
    id: sessionFile
    path: root.sessionPath
    printErrors: false
    onLoaded: root.session = Model.parseSession(text())
    onLoadFailed: root.session = null
  }

  // ---- mpv IPC -------------------------------------------------------------
  readonly property int timePosRequest: 100

  Socket {
    id: mpvSocket
    path: root.socketPath
    connected: false
    parser: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.handleMpvLine(line) }
    }
    onConnectedChanged: {
      if (connected) {
        root.playError = ""
        sessionFile.reload()
        for (var i = 0; i < Model.OBSERVED.length; i++)
          root.send(["observe_property", i + 1, Model.OBSERVED[i]])
        // Errors only: why a track couldn't be opened (see showSkipped).
        root.send(["request_log_messages", "error"])
        root.requestPosition()
      } else {
        root.resetPlayer()
      }
    }
    // Deliberately no onError handler, and nothing else touches `connected`
    // from inside this socket's callbacks. Quickshell already tears the socket
    // down on a failed connect or a peer close. Setting `connected = false`
    // from onError makes quickshell 0.3.2's Socket::onSocketError call
    // deleteLater() on a null socket, which segfaults the whole shell
    // (reproduced in isolation).
  }

  // Every monitor's bar holds its own instance of this widget, each with its
  // own connection to mpv. Whichever instance starts playback tells the rest.
  function attach() {
    if (socketPath === "") return
    sessionFile.reload()
    if (!mpvSocket.connected) mpvSocket.connected = true
  }

  function reloadSession() { sessionFile.reload() }

  function reloadSessionAll() {
    var peers = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    var sawSelf = false
    for (var i = 0; i < peers.length; i++) {
      if (peers[i] === root) sawSelf = true
      if (peers[i] && typeof peers[i].reloadSession === "function") peers[i].reloadSession()
    }
    if (!sawSelf) reloadSession()
  }

  function attachAll() {
    var peers = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    var sawSelf = false
    for (var i = 0; i < peers.length; i++) {
      if (peers[i] === root) sawSelf = true
      if (peers[i] && typeof peers[i].attach === "function") peers[i].attach()
    }
    if (!sawSelf) attach()
  }

  function send(args, requestId) {
    if (!mpvSocket.connected) return
    mpvSocket.write(Model.mpvCommand(args, requestId))
    mpvSocket.flush()
  }

  function requestPosition() { send(["get_property", "time-pos"], timePosRequest) }

  // mpv skips a track it can't open (members-only, removed, region-locked …)
  // and plays the next one. Say which and why, instead of silently playing
  // something else. For each track mpv sends "start-file", then (on failure)
  // the ytdl hook's "ERROR: …" log line, then "end-file" with reason "error".
  property string ytdlError: ""

  function showSkipped(errorLine) {
    var f = Model.playbackFailure(errorLine)
    if (!f) { showNotice(strings.t("notice.skippedUnknown"), false, true); return }
    var title = f.id
    var queue = session && session.tracks ? session.tracks : []
    for (var i = 0; i < queue.length; i++) {
      if (queue[i].id === f.id) { title = queue[i].title; break }
    }
    var text = strings.t("notice.skipped").arg(Model.truncate(title, 60)).arg(f.reason)
    var offer = f.account && !playbackCookies && browser !== "none"
    if (offer) text += " " + strings.t("notice.cookiesHint")
    showNotice(text, false, true)
    if (offer) noticeRetryId = f.id
  }

  // The user asked to play `videoId` with their account: turn playback
  // cookies on (saved in this widget's shell.json entry, like repeat). The
  // settings change hands them to the running player (syncPlayerCookies);
  // once that's done the song is played again (see the "cookies" reply).
  function playWithAccount(videoId) {
    var shell = bar ? bar.shell : null
    if (!shell || typeof shell.updateEntryInline !== "function") return
    retryVideoId = videoId
    notice = ""
    noticeTimer.stop()
    noticeRetryId = ""
    settings = Object.assign({}, settings, { playbackCookies: "On" })
    shell.updateEntryInline(moduleName, settings)
  }

  function retrySkipped() {
    var id = retryVideoId
    retryVideoId = ""
    var queue = session && session.tracks ? session.tracks : []
    for (var i = 0; i < queue.length; i++) {
      if (queue[i].id === id) { send(["playlist-play-index", i]); send(["set_property", "pause", false]); return }
    }
  }

  function handleMpvLine(line) {
    var m = Model.parseMpvLine(line)
    if (!m) return
    if (m.event === "property-change") applyProperty(m.name, m.data)
    else if (m.event === "start-file") ytdlError = ""
    else if (m.event === "log-message") {
      if (m.prefix === "ytdl_hook" && /^ERROR: /.test(String(m.text))) ytdlError = String(m.text)
    }
    else if (m.event === "end-file" && m.reason === "error") showSkipped(ytdlError)
    else if (m.request_id === timePosRequest && m.error === "success") position = Number(m.data) || 0
  }

  function applyProperty(name, data) {
    switch (name) {
    case "pause": paused = data === true; break
    case "media-title": mediaTitle = Model.cleanText(data); break
    case "duration": duration = typeof data === "number" && isFinite(data) ? data : 0; break
    case "playlist-pos":
      playlistPos = typeof data === "number" ? data : -1
      position = 0
      break
    case "playlist-count":
      playlistCount = typeof data === "number" ? data : 0
      // A radio or autoplay changed the queue (possibly from another bar).
      sessionFile.reload()
      break
    case "volume": if (typeof data === "number") volume = data; break
    case "seeking": seekingRaw = data; break
    case "paused-for-cache": pausedForCache = data === true; break
    case "loop-file":
      loopFileRaw = data
      repeatMode = Model.repeatFromMpv(loopFileRaw, loopPlaylistRaw)
      break
    case "loop-playlist":
      loopPlaylistRaw = data
      repeatMode = Model.repeatFromMpv(loopFileRaw, loopPlaylistRaw)
      break
    }
  }

  function resetPlayer() {
    paused = false
    mediaTitle = ""
    duration = 0
    position = 0
    playlistPos = -1
    playlistCount = 0
    seekingRaw = false
    pausedForCache = false
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.connected && root.opened && !root.paused
    onTriggered: root.requestPosition()
  }

  // ---- actions -------------------------------------------------------------
  function play(index, shuffle) {
    if (!openPlaylist || playProc.running) return
    // Read before disconnecting: the new player keeps the current volume.
    var startVolume = Math.round(volume)
    playError = ""
    starting = true
    mpvSocket.connected = false
    var chosen = tracks[index]
    playProc.command = helper([
      "play", openPlaylist.id,
      "--index", String(Math.max(0, index)),
      // The song itself, so the queue starts on it even if the list changed.
      "--video-id", chosen && chosen.id ? chosen.id : "",
      "--shuffle", shuffle ? "1" : "0",
      "--browser", browser,
      "--playback-cookies", playbackCookies ? "1" : "0",
      "--volume", String(startVolume),
      "--repeat", repeatMode,
      "--title", playlistTitle(openPlaylist)
    ])
    playProc.running = true
  }

  function radioArgs(videoId, mode, title) {
    return helper([
      "radio", videoId, "--mode", mode,
      "--browser", browser,
      "--playback-cookies", playbackCookies ? "1" : "0",
      "--volume", String(Math.round(volume)),
      "--repeat", repeatMode,
      "--title", title
    ])
  }

  // "Start radio", like YouTube Music: a queue of songs YouTube recommends
  // for `track`. For the song that's playing, it keeps playing and the radio
  // follows it; for any other song, the radio starts with that song.
  function startRadio(track) {
    var listId = track ? Model.radioListId(track.id) : ""
    if (listId === "" || radioProc.running) return
    var keep = connected && currentTrack !== null && currentTrack.id === track.id
    var title = strings.t("list.radioTitle").arg(track.title)
    playError = ""
    if (!keep) {
      starting = true
      mpvSocket.connected = false
    }
    // Show the radio's list as the open view, like YouTube Music's "Up next".
    openPlaylist = { id: listId, title: title, count: null }
    tracks = []
    cursorIndex = -1
    view = "tracks"
    tracksLoading = true
    radioProc.listId = listId
    radioProc.command = radioArgs(track.id, keep ? "keep" : "replace", title)
    radioProc.running = true
  }

  function runAutoplay(seed) {
    if (radioProc.running) return
    autoplayRequested = seed
    radioProc.listId = ""
    radioProc.command = radioArgs(seed, "append", session ? session.playlistTitle : "")
    radioProc.running = true
  }

  function cursorOrCurrentTrack() {
    if (view === "tracks" && cursorIndex >= 0 && cursorIndex < tracks.length) return tracks[cursorIndex]
    return currentTrack
  }

  function showNotice(text, auth, long) {
    notice = text
    noticeAuth = auth === true
    noticeLong = long === true
    noticeRetryId = ""
    noticeTimer.restart()
  }

  // Opens YouTube's sign-in page in the browser the cookies come from.
  function signIn() {
    if (!signinProc.running) signinProc.running = true
  }

  function playlistTitleById(id) {
    for (var i = 0; i < playlists.length; i++) if (playlists[i].id === id) return playlistTitle(playlists[i])
    return id
  }

  function isLiked(id) { return !!(id && likedIds[id]) }

  // The heart, like YouTube Music's: likes the song (it goes to Liked Music)
  // or removes the like. Shown at once, rolled back if YouTube refuses.
  function toggleLike(track) {
    if (!track || !Model.radioListId(track.id) || likeProc.running) return
    var like = !isLiked(track.id)
    likedIds = Model.withLiked(likedIds, track.id, like)
    likeProc.videoId = track.id
    likeProc.liking = like
    var args = ["like", track.id, "--browser", browser,
                "--title", track.title || "", "--artist", track.artist || "",
                "--duration", String(track.duration || 0)]
    if (!like) args.push("--remove", "1")
    likeProc.command = helper(args)
    likeProc.running = true
  }

  // "Add to playlist": the list switches to your playlists; picking one adds
  // the song and returns to where you were.
  function openAddTo(track) {
    if (!track || !Model.radioListId(track.id)) return
    if (playlists.length === 0) loadPlaylists(false)
    addTrack = track
    if (view !== "addTo") viewBeforeAdd = view
    view = "addTo"
    cursorIndex = -1
    // Ask YouTube Music which playlists this song can go to.
    addTargetsLive = null
    if (browser !== "none") {
      addTargetsLoading = true
      targetsProc.command = helper(["targets", track.id, "--browser", browser])
      targetsProc.running = true
    } else {
      addTargetsLoading = false
    }
  }

  function closeAddTo() {
    if (view !== "addTo") return
    view = viewBeforeAdd
    addTrack = null
    addTargetsLive = null
    addTargetsLoading = false
    cursorIndex = -1
  }

  function addToPlaylist(playlist) {
    if (!playlist || !addTrack || addProc.running) return
    var title = playlistTitle(playlist)
    if (playlist.contains === true) {
      showNotice(strings.t("notice.alreadyIn").arg(title))
      closeAddTo()
      return
    }
    addProc.title = title
    addProc.command = helper(["add", playlist.id, addTrack.id, "--browser", browser])
    addProc.running = true
    closeAddTo()
  }

  // Off -> repeat all -> repeat one -> off. Works with nothing playing too:
  // the next playback starts in the chosen mode.
  function cycleRepeat() {
    var mode = Model.nextRepeat(repeatMode)
    repeatMode = mode
    var cmds = Model.repeatCommands(mode)
    for (var i = 0; i < cmds.length; i++) send(cmds[i])
    // Remember it in this widget's own shell.json entry.
    var shell = bar ? bar.shell : null
    if (shell && typeof shell.updateEntryInline === "function") {
      settings = Object.assign({}, settings, { repeat: mode })
      shell.updateEntryInline(moduleName, settings)
    }
  }

  function togglePause() { send(["cycle", "pause"]) }
  function next() { send(["playlist-next", "weak"]) }
  function previous() {
    // Like most players: restart the track unless we're at its very start.
    if (position > 3) { send(["seek", 0, "absolute"]); position = 0 }
    else send(["playlist-prev", "weak"])
  }
  function stop() {
    send(["quit"])
    if (!stopProc.running) stopProc.running = true
  }
  function seek(seconds) {
    send(["seek", seconds, "absolute"])
    position = seconds
  }
  function setVolume(value) {
    var v = Math.max(0, Math.min(100, Math.round(value)))
    volume = v
    send(["set_property", "volume", v])
  }

  function openPlaylistAt(index) {
    var p = playlists[index]
    if (!p) return
    openPlaylist = p
    tracks = []
    cursorIndex = -1
    view = "tracks"
    loadTracks(false)
  }

  function backToPlaylists() {
    if (view === "addTo") { closeAddTo(); return }
    if (view !== "tracks") return
    view = "playlists"
    var id = openPlaylist ? openPlaylist.id : ""
    cursorIndex = -1
    for (var i = 0; i < playlists.length; i++) if (playlists[i].id === id) { cursorIndex = i; break }
  }

  function refreshList() {
    if (view === "tracks") loadTracks(true)
    else loadPlaylists(true)
  }

  function activateRow(index) {
    if (view === "tracks") play(index, false)
    else if (view === "addTo") addToPlaylist(rows[index])
    else openPlaylistAt(index)
  }

  function isPlayingPlaylist(id) {
    return connected && session !== null && session.playlistId === id
  }

  function isPlayingTrack(index) {
    // The queue is in the playlist's order unless shuffled; when shuffled,
    // match on the video id instead.
    if (!connected || !session || !openPlaylist || session.playlistId !== openPlaylist.id || !currentTrack) return false
    var t = tracks[index]
    if (!t) return false
    // Shuffled queues and radios (whose queue may start with a song that
    // isn't first in the list) match by id.
    return session.shuffle || Model.isMix(session.playlistId)
      ? t.id === currentTrack.id : index === playlistPos && t.id === currentTrack.id
  }

  // ---- keyboard ------------------------------------------------------------
  function moveCursor(dx, dy) {
    if (dy !== 0) cursorIndex = Model.clampIndex(cursorIndex, dy, rows.length)
    else if (dx < 0) backToPlaylists()
    else if (dx > 0 && view === "playlists" && cursorIndex >= 0) openPlaylistAt(cursorIndex)
  }

  function activateCursor() {
    if (cursorIndex >= 0 && cursorIndex < rows.length) activateRow(cursorIndex)
    else togglePause()
  }

  function handleKey(text) {
    switch (text) {
    case "p": togglePause(); break
    case "n": next(); break
    case "b": previous(); break
    case "r": refreshList(); break
    case "R": cycleRepeat(); break
    case "m": startRadio(cursorOrCurrentTrack()); break
    case "f": toggleLike(cursorOrCurrentTrack()); break
    case "a": openAddTo(cursorOrCurrentTrack()); break
    case "s": if (view === "tracks") play(Math.floor(Math.random() * Math.max(1, tracks.length)), true); break
    case "+": case "=": setVolume(volume + 5); break
    case "-": setVolume(volume - 5); break
    case "\b": backToPlaylists(); break
    }
  }

  ShellIpc {
    target: "io.github.symonbaikov.ytmusic-mpv"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function playPause(): void { root.togglePause() }
    function next(): void { root.next() }
    function previous(): void { root.previous() }
    function stop(): void { root.stop() }
    function cycleRepeat(): void { root.cycleRepeat() }
    function startRadio(): void { root.startRadio(root.currentTrack) }
    function toggleLike(): void { root.toggleLike(root.currentTrack) }
    function addToPlaylist(): void {
      root.open()
      root.openAddTo(root.currentTrack)
    }
    function signIn(): void { root.signIn() }
  }

  onOpenedChanged: {
    if (!opened) return
    cursorIndex = -1
    if (playlists.length === 0 || !playlistsLoading) loadPlaylists(false)
    if (!likedProc.running) likedProc.running = true
    if (connected) requestPosition()
    else attach()
  }

  Component.onCompleted: {
    pathsProc.running = true
    likedProc.running = true
    // Settings may have changed while the shell wasn't running.
    syncPlayerCookies()
  }

  // ---- bar button ----------------------------------------------------------
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  TextMetrics {
    id: labelMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.bar.iconFont
    text: root.barLabel
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.loading ? Model.GLYPH.loading : (root.connected && root.paused ? Model.GLYPH.pause : Model.GLYPH.music)
    textRotation: root.loading ? root.spinAngle : 0
    active: root.playing
    labelText: root.barLabel
    slotSize: Style.bar.iconSlot + (root.barLabel !== "" ? Math.ceil(labelMetrics.advanceWidth) + Style.space(8) : 0)
    tooltipText: root.connected && root.nowTitle !== ""
      ? Model.plain(root.nowArtist !== "" ? strings.t("widget.tooltipPlaying").arg(root.nowTitle).arg(root.nowArtist) : root.nowTitle)
      : strings.t("widget.tooltip")
    onPressed: function(b) {
      if (b === Qt.RightButton) root.togglePause()
      else if (b === Qt.MiddleButton) root.next()
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      if (root.connected && delta !== 0) root.setVolume(root.volume + (delta > 0 ? 5 : -5))
    }
  }

  // ---- panel ---------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text, modifiers) { root.handleKey(text) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- now playing ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(nowIcon.height, nowLabels.implicitHeight)

          // Cover art, like the built-in media widget: the image sits inside
          // a bordered tile and is decoded at the size it is drawn.
          BorderSurface {
            id: nowIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(72)
            height: Style.space(72)
            radius: Style.spacing.labelGap
            color: Style.normalFillFor(root.fg, Commons.Color.accent)
            borderSpec: Border.controlSpec("normal", root.fg, Commons.Color.accent)

            SizedImage {
              id: nowCover
              anchors.fill: parent
              anchors.margins: Style.space(2)
              crop: true
              url: root.nowCoverUrl
              visible: url != "" && status === Image.Ready
              onStatusChanged: {
                // maxresdefault is missing for some uploads: use the 320px one.
                if (status === Image.Error && root.currentTrack && String(url).indexOf("maxresdefault") >= 0)
                  root.largeCoverFailedFor = root.currentTrack.id
              }
            }

            PlainText {
              anchors.centerIn: parent
              visible: !nowCover.visible && !root.loading
              text: Model.GLYPH.music
              font.pixelSize: Style.font.displayLarge
              elide: Text.ElideNone
            }

            // Loading: dim the cover and spin over it.
            Rectangle {
              anchors.fill: nowCover
              visible: root.loading && nowCover.visible
              color: Qt.rgba(0, 0, 0, 0.5)
            }
            Spinner {
              anchors.centerIn: parent
              visible: root.loading
              color: nowCover.visible ? "white" : root.fg
              font.pixelSize: Style.font.displayLarge
            }
          }

          // Like and add-to-playlist for the playing song, beside its title.
          Row {
            id: nowActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)
            visible: root.connected && root.currentTrack !== null

            PanelActionButton {
              readonly property bool liked: root.currentTrack !== null && root.isLiked(root.currentTrack.id)
              iconText: liked ? Model.GLYPH.heart : Model.GLYPH.heartOutline
              tooltipText: liked ? strings.t("controls.unlike") : strings.t("controls.like")
              foreground: liked ? Style.selectedStateColor(root.fg, Commons.Color.accent) : root.fg
              fontFamily: root.fontFamily
              enabled: !likeProc.running
              onClicked: root.toggleLike(root.currentTrack)
            }
            PanelActionButton {
              iconText: Model.GLYPH.playlistAdd
              tooltipText: strings.t("controls.addToPlaylist")
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.openAddTo(root.currentTrack)
            }
          }

          Column {
            id: nowLabels
            anchors.left: nowIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: nowActions.visible ? nowActions.left : parent.right
            anchors.rightMargin: nowActions.visible ? Style.space(6) : 0
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            PlainText {
              width: parent.width
              text: root.starting ? strings.t("now.loading")
                : (root.connected && root.nowTitle !== "" ? root.nowTitle : strings.t("now.idle"))
              font.pixelSize: Style.font.title
              font.bold: true
            }
            PlainText {
              width: parent.width
              text: root.connected ? root.nowArtist : strings.t("now.idleHint")
              color: root.dim
              visible: text !== ""
            }
            PlainText {
              width: parent.width
              visible: root.connected && root.session !== null
              color: root.dim
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.1
              text: {
                if (!root.session) return ""
                var parts = [strings.t("now.position")
                  .arg(Commons.I18n.formatNumber(root.playlistPos + 1))
                  .arg(Commons.I18n.formatNumber(root.playlistCount))]
                if (root.session.playlistTitle !== "") parts.push(root.session.playlistTitle)
                if (root.session.shuffle) parts.push(strings.t("now.shuffled"))
                if (root.session.autoplay) parts.push(strings.t("now.autoplay"))
                if (root.repeatMode === "all") parts.push(strings.t("now.repeatAll"))
                else if (root.repeatMode === "one") parts.push(strings.t("now.repeatOne"))
                return parts.join("  ·  ").toUpperCase()
              }
            }
          }
        }

        // ---------- progress ----------
        Column {
          visible: root.connected
          width: parent.width
          spacing: Style.space(2)

          PanelSlider {
            width: parent.width
            bar: root.bar
            minimum: 0
            maximum: Math.max(1, root.duration)
            step: 1
            value: root.position
            onReleased: function(value) { root.seek(value) }
          }

          Item {
            width: parent.width
            implicitHeight: elapsed.implicitHeight
            PlainText {
              id: elapsed
              anchors.left: parent.left
              text: Model.formatTime(root.position, Commons.I18n.formatNumber)
              color: root.dim
              font.pixelSize: Style.font.caption
              elide: Text.ElideNone
            }
            PlainText {
              anchors.right: parent.right
              text: root.duration > 0 ? Model.formatTime(root.duration, Commons.I18n.formatNumber) : ""
              color: root.dim
              font.pixelSize: Style.font.caption
              elide: Text.ElideNone
            }
          }
        }

        // ---------- transport + volume ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(controls.implicitHeight, volumeRow.implicitHeight)

          Row {
            id: controls
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            PanelActionButton {
              iconText: LayoutMirroring.enabled ? Model.GLYPH.next : Model.GLYPH.previous
              tooltipText: strings.t("controls.previous")
              foreground: root.fg
              fontFamily: root.fontFamily
              enabled: root.connected
              opacity: enabled ? 1 : 0.4
              onClicked: root.previous()
            }
            PanelActionButton {
              id: playButton
              // While loading, the spinner takes the icon's place, as in
              // YouTube Music; the button still pauses.
              iconText: root.loading ? "" : (root.playing ? Model.GLYPH.pause : Model.GLYPH.play)
              tooltipText: root.loading ? strings.t("controls.loading") : strings.t("controls.playPause")
              foreground: root.fg
              fontFamily: root.fontFamily
              fontSize: Style.font.title
              bordered: true
              enabled: root.connected
              opacity: enabled ? 1 : 0.4
              onClicked: root.togglePause()

              Spinner {
                anchors.centerIn: parent
                visible: root.loading
                font.pixelSize: Style.font.title
              }
            }
            PanelActionButton {
              iconText: LayoutMirroring.enabled ? Model.GLYPH.previous : Model.GLYPH.next
              tooltipText: strings.t("controls.next")
              foreground: root.fg
              fontFamily: root.fontFamily
              enabled: root.connected
              opacity: enabled ? 1 : 0.4
              onClicked: root.next()
            }
            // Repeat, as in Apple Music: dim when off, highlighted for repeat
            // all, and the "1" glyph for repeat one. It can be set before
            // anything plays.
            PanelActionButton {
              iconText: root.repeatMode === "one" ? Model.GLYPH.repeatOne : Model.GLYPH.repeat
              tooltipText: strings.t(root.repeatMode === "one" ? "controls.repeatOne"
                : (root.repeatMode === "all" ? "controls.repeatAll" : "controls.repeatOff"))
              foreground: root.repeatMode === "off" ? root.fg : Style.selectedStateColor(root.fg, Commons.Color.accent)
              fontFamily: root.fontFamily
              bordered: root.repeatMode !== "off"
              opacity: root.repeatMode === "off" ? 0.55 : 1
              onClicked: root.cycleRepeat()
            }
            // Start radio from the playing song (it keeps playing).
            PanelActionButton {
              iconText: Model.GLYPH.radio
              tooltipText: strings.t("controls.radio")
              foreground: root.fg
              fontFamily: root.fontFamily
              enabled: root.connected && root.currentTrack !== null && !root.radioBusy
              opacity: enabled ? 1 : 0.4
              onClicked: root.startRadio(root.currentTrack)
            }
            PanelActionButton {
              iconText: Model.GLYPH.stop
              tooltipText: strings.t("controls.stop")
              foreground: root.fg
              fontFamily: root.fontFamily
              enabled: root.connected
              opacity: enabled ? 1 : 0.4
              onClicked: root.stop()
            }
          }

          Row {
            id: volumeRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)
            visible: root.connected

            PlainText {
              anchors.verticalCenter: parent.verticalCenter
              text: root.volume <= 0 ? Model.GLYPH.volumeOff : Model.GLYPH.volume
              elide: Text.ElideNone
            }
            PanelSlider {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(120)
              bar: root.bar
              minimum: 0
              maximum: 100
              step: 1
              integer: true
              value: root.volume
              onMoved: function(value) { root.setVolume(value) }
            }
          }
        }

        PlainText {
          visible: root.playError !== ""
          width: parent.width
          text: strings.t("error.prefix").arg(root.playError)
          wrapMode: Text.Wrap
          elide: Text.ElideNone
          font.pixelSize: Style.font.bodySmall
        }

        // Notices ("Added to …", errors). A sign-in problem gets a button that
        // opens YouTube's sign-in page in the browser the cookies come from.
        Item {
          visible: root.notice !== ""
          width: parent.width
          implicitHeight: Math.max(noticeText.implicitHeight, noticeButton.visible ? noticeButton.implicitHeight : 0)

          PlainText {
            id: noticeText
            anchors.left: parent.left
            anchors.right: noticeButton.visible ? noticeButton.left : parent.right
            anchors.rightMargin: noticeButton.visible ? Style.space(8) : 0
            anchors.verticalCenter: parent.verticalCenter
            text: root.notice
            color: root.dim
            wrapMode: Text.Wrap
            elide: Text.ElideNone
            font.pixelSize: Style.font.bodySmall
          }
          // "Sign in" for a sign-in problem; "Play with my account" for a
          // song skipped for a reason the account may get past.
          Button {
            id: noticeButton
            readonly property bool retry: root.noticeRetryId !== ""
            visible: root.browser !== "none" && (root.noticeAuth || retry)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: retry ? Model.GLYPH.play : Model.GLYPH.login
            text: retry ? strings.t("controls.useAccount") : strings.t("controls.signIn")
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            onClicked: retry ? root.playWithAccount(root.noticeRetryId) : root.signIn()
          }
        }

        PanelSeparator { foreground: root.fg }

        // ---------- list header ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(headerLeft.implicitHeight, headerRight.implicitHeight)

          Row {
            id: headerLeft
            anchors.left: parent.left
            anchors.right: headerRight.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            PanelActionButton {
              visible: root.view === "tracks" || root.view === "addTo"
              anchors.verticalCenter: parent.verticalCenter
              iconText: LayoutMirroring.enabled ? Model.GLYPH.forward : Model.GLYPH.back
              tooltipText: strings.t("list.back")
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.backToPlaylists()
            }
            PanelSectionHeader {
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, headerLeft.width - (root.view !== "playlists" ? Style.space(40) : 0))
              elide: Text.ElideRight
              text: root.view === "tracks" ? root.playlistTitle(root.openPlaylist)
                : (root.view === "addTo" && root.addTrack ? strings.t("list.addTo").arg(root.addTrack.title) : strings.t("list.playlists"))
              foreground: root.fg
              fontFamily: root.fontFamily
            }
          }

          Row {
            id: headerRight
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Button {
              visible: root.view === "tracks" && root.tracks.length > 0
              iconText: Model.GLYPH.play
              text: strings.t("list.playAll")
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.play(0, false)
            }
            Button {
              visible: root.view === "tracks" && root.tracks.length > 1
              iconText: Model.GLYPH.shuffle
              text: strings.t("list.shuffle")
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.handleKey("s")
            }
            Button {
              iconText: Model.GLYPH.refresh
              iconSpinning: root.view === "tracks" ? root.tracksLoading : root.playlistsLoading
              tooltipText: strings.t("list.refresh")
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.refreshList()
            }
          }
        }

        // ---------- playlists / tracks ----------
        ListView {
          id: listView
          width: parent.width
          height: Math.min(contentHeight, Style.space(360))
          visible: count > 0
          spacing: Style.space(2)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.rows
          currentIndex: root.cursorIndex
          onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(keepCurrentVisible)
          function keepCurrentVisible() {
            if (currentIndex >= 0 && currentIndex < count) positionViewAtIndex(currentIndex, ListView.Contain)
          }

          delegate: CursorSurface {
            id: rowItem
            required property var modelData
            required property int index
            readonly property bool isTrack: root.view === "tracks"
            readonly property bool isNow: isTrack ? root.isPlayingTrack(index) : root.isPlayingPlaylist(modelData.id)

            readonly property bool hasCover: isTrack && root.showCovers

            width: ListView.view.width
            height: Math.max(rowLabels.implicitHeight, leading.height) + Style.spacing.controlPaddingY * 2
            foreground: root.fg
            hasCursor: root.cursorIndex === index
            current: isNow

            Item {
              id: leading
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.rowPaddingX
              anchors.verticalCenter: parent.verticalCenter
              width: rowItem.hasCover ? Style.space(36) : Style.space(28)
              height: rowItem.hasCover ? Style.space(36) : leadingGlyph.implicitHeight

              // Small cover: the 320px thumbnail, fetched only for rows the
              // list actually creates (the visible ones).
              SizedImage {
                id: rowCover
                anchors.fill: parent
                visible: rowItem.hasCover && status === Image.Ready
                crop: true
                url: rowItem.hasCover ? Model.coverUrl(rowItem.modelData.id, "small") : ""
              }

              Rectangle {
                anchors.fill: parent
                visible: rowCover.visible && rowItem.isNow
                color: Qt.rgba(0, 0, 0, 0.55)
              }

              PlainText {
                id: leadingGlyph
                anchors.centerIn: parent
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideNone
                visible: (!rowCover.visible || rowItem.isNow) && !(rowItem.isNow && root.loading)
                color: rowCover.visible ? "white" : (rowItem.isNow ? root.fg : root.dim)
                font.pixelSize: rowItem.isTrack && !rowItem.isNow ? Style.font.caption : Style.font.body
                text: {
                  if (rowItem.isNow) return root.paused ? Model.GLYPH.pause : Model.GLYPH.play
                  if (!rowItem.isTrack) {
                    if (rowItem.modelData.id === "LM") return Model.GLYPH.heart
                    if (rowItem.modelData.id === Model.SUPERMIX_ID) return Model.GLYPH.supermix
                    return Model.GLYPH.playlist
                  }
                  return Commons.I18n.formatNumber(rowItem.index + 1)
                }
              }

              Spinner {
                anchors.centerIn: parent
                visible: rowItem.isNow && root.loading
                color: rowCover.visible ? "white" : root.fg
              }
            }

            Column {
              id: rowLabels
              anchors.left: leading.right
              anchors.leftMargin: Style.space(8)
              anchors.right: rowActions.visible ? rowActions.left : (rowLikedMark.visible ? rowLikedMark.left : trailing.left)
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)

              PlainText {
                width: parent.width
                text: rowItem.isTrack ? rowItem.modelData.title : root.playlistTitle(rowItem.modelData)
                font.bold: rowItem.isNow
              }
              PlainText {
                width: parent.width
                visible: text !== ""
                color: root.dim
                font.pixelSize: Style.font.bodySmall
                text: rowItem.isTrack ? rowItem.modelData.artist : ""
              }
            }

            PlainText {
              id: trailing
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.rowPaddingX
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideNone
              color: root.dim
              font.pixelSize: Style.font.bodySmall
              text: {
                var d = rowItem.modelData
                if (rowItem.isTrack) return d.duration !== null ? Model.formatTime(d.duration, Commons.I18n.formatNumber) : ""
                // Add-to view: a check where the song already is.
                if (root.view === "addTo" && d.contains === true) return Model.GLYPH.check
                return typeof d.count === "number" ? strings.tn("list.tracks", d.count).arg(Commons.I18n.formatNumber(d.count)) : ""
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.cursorIndex = rowItem.index
              onClicked: root.activateRow(rowItem.index)
            }

            readonly property bool liked: isTrack && root.isLiked(modelData.id)

            // A liked song keeps a small heart when it isn't highlighted.
            PlainText {
              id: rowLikedMark
              visible: rowItem.liked && !rowActions.visible
              anchors.right: trailing.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: Model.GLYPH.heart
              color: root.dim
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideNone
            }

            // Like, add to playlist and start radio for the highlighted track.
            // Declared after the row's MouseArea so the buttons sit above it
            // and get their own clicks.
            Row {
              id: rowActions
              visible: rowItem.isTrack && rowItem.hasCursor
              anchors.right: trailing.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              PanelActionButton {
                iconText: rowItem.liked ? Model.GLYPH.heart : Model.GLYPH.heartOutline
                tooltipText: rowItem.liked ? strings.t("controls.unlike") : strings.t("controls.like")
                foreground: rowItem.liked ? Style.selectedStateColor(root.fg, Commons.Color.accent) : root.fg
                fontFamily: root.fontFamily
                enabled: !likeProc.running
                onClicked: root.toggleLike(rowItem.modelData)
              }
              PanelActionButton {
                iconText: Model.GLYPH.playlistAdd
                tooltipText: strings.t("controls.addToPlaylist")
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: root.openAddTo(rowItem.modelData)
              }
              PanelActionButton {
                iconText: Model.GLYPH.radio
                tooltipText: strings.t("list.startRadio")
                foreground: root.fg
                fontFamily: root.fontFamily
                enabled: !root.radioBusy
                onClicked: root.startRadio(rowItem.modelData)
              }
            }
          }
        }

        PlainText {
          width: parent.width
          visible: text !== ""
          wrapMode: Text.Wrap
          elide: Text.ElideNone
          color: root.dim
          font.pixelSize: Style.font.bodySmall
          text: {
            if (root.view === "addTo") {
              if (root.rows.length > 0) return ""
              if (root.addTargetsLoading) return strings.t("list.loadingTargets")
              // Empty only means "none of your own" when YouTube said so.
              return root.addTargetsLive !== null ? strings.t("list.noOwnPlaylists") : strings.t("list.targetsFailed")
            }
            var loading = root.view === "tracks" ? root.tracksLoading : root.playlistsLoading
            var error = root.view === "tracks" ? root.tracksError : root.playlistsError
            if (error !== "") {
              var msg = strings.t("error.prefix").arg(error)
              if (root.view === "playlists" && root.browser !== "none") msg += "\n" + strings.t("error.cookiesHint").arg(root.browser)
              return msg
            }
            if (root.rows.length > 0) return ""
            if (loading) return strings.t("list.loading")
            return root.view === "tracks" ? strings.t("list.emptyTracks") : strings.t("list.emptyPlaylists")
          }
        }

        // The library didn't load: most often not signed in to that browser.
        Button {
          visible: root.view === "playlists" && root.playlistsError !== "" && root.browser !== "none"
          iconText: Model.GLYPH.login
          text: strings.t("controls.signIn")
          fontSize: Style.font.bodySmall
          foreground: root.fg
          fontFamily: root.fontFamily
          bordered: true
          onClicked: root.signIn()
        }
      }
    }
  }

  // Loading indicator, like Omarchy's own spinning buttons: it turns only
  // while visible, and stands still when animations are turned off.
  component Spinner: Text {
    id: spinner
    textFormat: Text.PlainText
    text: Model.GLYPH.loading
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    transformOrigin: Item.Center

    RotationAnimation on rotation {
      from: 0
      to: 360
      duration: Style.duration(900)
      loops: Animation.Infinite
      running: spinner.visible && !Style.reduceMotion
    }
  }

  // All text in this plugin is plain: titles come from YouTube.
  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }
}
