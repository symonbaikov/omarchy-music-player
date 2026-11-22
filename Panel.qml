import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
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
  // Fades and the peak mix run inside mpv (mpv/ytmusic.lua); a running
  // player follows changes from the next moment on.
  readonly property real fadeIn: Model.seconds(setting("fadeIn", 0), 0, 30, 0)
  readonly property real fadeOut: Model.seconds(setting("fadeOut", 0), 0, 30, 0)
  readonly property string transitionMode: setting("transition", "Off") === "Peak mix" ? "peak" : "off"
  readonly property real crossfade: Model.seconds(setting("crossfade", 6), 2, 16, 6)
  // Pausing fades the song away over this long (milliseconds in settings).
  readonly property real pauseFade: Model.seconds(Number(setting("pauseFade", 600)) / 1000, 0, 3, 0.6)
  onPauseFadeChanged: sendPlayerSetting("pause_fade", pauseFade)
  // The running player's script knows `ytmusic-toggle-pause` (one started by
  // an older version doesn't: it pauses at once).
  property bool pauseFadeSupported: false
  onFadeInChanged: sendPlayerSetting("fade_in", fadeIn)
  onFadeOutChanged: sendPlayerSetting("fade_out", fadeOut)
  onTransitionModeChanged: sendPlayerSetting("transition", transitionMode)
  onCrossfadeChanged: sendPlayerSetting("xfade", crossfade)

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
  property string view: "playlists"          // "playlists" | "tracks" | "addTo" | "settings"
  property string viewBeforeSettings: "playlists"
  property var playlists: []
  property bool playlistsLoading: false
  property string playlistsError: ""
  property var openPlaylist: null            // { id, title, count }
  property var tracks: []
  property bool tracksLoading: false
  property string tracksError: ""
  property int cursorIndex: -1
  readonly property var libraryRows: service === "yt" ? [exploreEntry].concat(playlists)
    : service === "sc" ? (svc.sc.setup ? [] : [scSearchEntry].concat(svc.sc.items))
    : service === "cl" ? (svc.cl.setup || cloudFormOpen ? [] : svc.cl.items.concat([cloudAddEntry]))
    : service === "rd" ? [radioCountryEntry].concat(svc.rd.items)
    : service === "my" ? (svc.my.setup ? [] : [aiEntry].concat(svc.my.items))
    : svc[service].setup ? [] : svc[service].items
  readonly property var rows: view === "settings" || view === "download" || view === "services" || view === "ai" ? []
    : view === "countries" ? countryRows
    : view === "explore" ? exploreRowsData
    : view === "playlists" ? libraryRows
    : view === "tracks" ? tracks
    : (view === "addTo" ? addRows
    : playlists)
  // Where a song can be added: your mixes (any service), and for a YouTube
  // song its YouTube Music playlists too.
  readonly property var addRows: {
    if (!addTrack) return []
    var yt = []
    if (Model.isYouTube(addTrack.id)) {
      var src = addTargetsLive !== null ? addTargetsLive : (addTargetsLoading ? [] : Model.addTargets(playlists))
      for (var i = 0; i < src.length; i++) yt.push(Object.assign({}, src[i], { section: strings.t("mix.ytSection") }))
    }
    return mixTargets.concat(yt)
  }
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
  // A song nothing on YouTube could play while backup mirrors are off:
  // { id, title, reason }, shown as a card offering them until answered.
  property var mirrorOffer: null
  property bool mirrorOfferDeclined: false
  readonly property bool mirrorsOn: setting("backupMirrors", "Off") === "On"
  readonly property bool updateCheckOn: setting("updateCheck", "On") !== "Off"
  readonly property string downloadDir: String(setting("downloadDir", "~/Music") || "~/Music")
  readonly property string downloadFormat: Model.DOWNLOAD_FORMATS.indexOf(setting("downloadFormat", "mp3")) >= 0
    ? setting("downloadFormat", "mp3") : "mp3"
  readonly property bool downloadCover: setting("downloadCover", "On") !== "Off"
  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string downloadPath: downloadDir.indexOf("~") === 0 ? homeDir + downloadDir.slice(1) : downloadDir

  // ---- services --------------------------------------------------------------
  // Tabs at the top: YouTube Music, Spotify, SoundCloud and My Music (your
  // mixes, My Mix and Downloads). The player is shared; only the library
  // below changes.
  property string service: "yt"
  readonly property var serviceTabs: [
    { id: "yt", glyph: Model.GLYPH.youtube, color: "#FF0033", label: strings.t("tab.yt") },
    { id: "sp", glyph: Model.GLYPH.spotify, color: "#1ED760", label: strings.t("tab.sp") },
    { id: "dz", glyph: Model.GLYPH.deezer, color: "#A238FF", label: strings.t("tab.dz") },
    { id: "sc", glyph: Model.GLYPH.soundcloud, color: "#FF5500", label: strings.t("tab.sc") },
    { id: "mc", glyph: Model.GLYPH.mixcloud, color: "#5B6CFF", label: strings.t("tab.mc") },
    { id: "au", glyph: Model.GLYPH.audius, color: "#CC0FE0", label: strings.t("tab.au") },
    { id: "cl", glyph: Model.GLYPH.cloud, color: "#4FA3FF", label: strings.t("tab.cl") },
    { id: "rd", glyph: Model.GLYPH.radioService, color: "#B388FF", label: strings.t("tab.rd") },
    { id: "pc", glyph: Model.GLYPH.podcast, color: "#D56DFB", label: strings.t("tab.pc") },
    { id: "my", glyph: Model.GLYPH.supermix, color: Commons.Color.accent, label: strings.t("tab.my") }
  ]
  // Per service: { items, loading, error, setup } ("setup": needs connecting).
  property var svc: ({ sp: { items: [], loading: false, error: "", setup: "" },
                       dz: { items: [], loading: false, error: "", setup: "" },
                       mc: { items: [], loading: false, error: "", setup: "" },
                       au: { items: [], loading: false, error: "", setup: "" },
                       sc: { items: [], loading: false, error: "", setup: "" },
                       cl: { items: [], loading: false, error: "", setup: "" },
                       rd: { items: [], loading: false, error: "", setup: "" },
                       pc: { items: [], loading: false, error: "", setup: "" },
                       my: { items: [], loading: false, error: "", setup: "" } })
  readonly property string spClientId: String(setting("spotifyClientId", "") || "")
  readonly property string scUserSetting: String(setting("soundcloudUser", "") || "")
  readonly property string dzUserSetting: String(setting("deezerUser", "") || "")
  property bool spotifyWaiting: false
  readonly property var scSearchEntry: ({ kind: "explore", id: "__scsearch", title: strings.t("sc.searchEntry"),
    artist: strings.t("sc.searchHint") })

  // The tabs the user keeps (setting "tabs"; the "+" tab picks them).
  readonly property var shownTabs: {
    var ids = Model.visibleTabs(setting("tabs", Model.DEFAULT_TABS))
    return serviceTabs.filter(function(t) { return ids.indexOf(t.id) >= 0 })
  }
  function setTabShown(id, on) {
    var ids = Model.visibleTabs(setting("tabs", Model.DEFAULT_TABS)).filter(function(x) { return x !== id })
    if (on) ids.push(id)
    saveSettings({ tabs: Model.SERVICES.filter(function(x) { return ids.indexOf(x) >= 0 }).join(",") })
    if (!on && service === id) switchService("yt")
  }
  function openServices() {
    if (view !== "services") viewBeforeSettings = view === "addTo" ? "playlists" : view
    view = "services"
    cursorIndex = -1
    if (!opened) open()
  }

  function setSvc(name, changes) {
    var next = Object.assign({}, svc)
    next[name] = Object.assign({}, svc[name], changes)
    svc = next
  }

  function switchService(name) {
    if (Model.SERVICES.indexOf(name) < 0) return
    service = name
    view = "playlists"
    cursorIndex = -1
    if (name === "cl") loadCloud()
    if (name === "rd" && radioCountries.length === 0 && !countriesProc.running) countriesProc.running = true
    if (name !== "yt" && svc[name].items.length === 0 && !svc[name].loading) loadPlaylists(false)
  }

  // ---- cloud storage -----------------------------------------------------------
  // Your own music folders through rclone (S3, Google Drive, Dropbox,
  // OneDrive, SFTP, SMB, WebDAV, FTP, or a remote rclone already has).
  property var cloudSources: []
  property var cloudRemotes: []
  property bool rcloneInstalled: true
  // The form can be used: a folder on this computer needs no rclone.
  readonly property bool cloudFormUsable: rcloneInstalled || cloudKind === "local" || cloudKindSpec.server === true
  // ~/Music, when it's there and not added yet: offered in one click.
  property string cloudMusicDir: ""
  property bool cloudFormOpen: false
  property string cloudKind: "drive"
  property bool cloudKindTouched: false
  property var cloudValues: ({})
  property string cloudRemote: ""
  property string cloudBusy: ""              // "" | "waiting" (browser sign-in) | "checking"
  property string cloudError: ""
  property bool cloudTyping: false
  // Fields inside the panel's content (set by it when it's made).
  property Item searchInput: null
  property Item cloudPathInput: null
  property Item cloudTitleInput: null
  function focusSearch() { if (searchInput) searchInput.forceActiveFocus() }
  function setSearchText(text) { if (searchInput) searchInput.text = text }
  // Bumped to clear the form's fields (their delegates are made again).
  property int cloudFormEpoch: 0
  readonly property bool cloudFormShown: view === "playlists" && service === "cl" && (svc.cl.setup !== "" || cloudFormOpen)
  readonly property var cloudKindSpec: {
    for (var i = 0; i < Model.CLOUD_KINDS.length; i++) if (Model.CLOUD_KINDS[i].id === cloudKind) return Model.CLOUD_KINDS[i]
    return Model.CLOUD_KINDS[0]
  }
  readonly property var cloudAddEntry: ({ kind: "explore", id: "__cloudadd", title: strings.t("cloud.addEntry"),
    artist: strings.t("cloud.addHint") })

  function loadCloud() {
    if (!cloudProc.running) cloudProc.running = true
  }

  function openCloudForm() {
    cloudError = ""
    cloudFormOpen = true
    if (service !== "cl") switchService("cl")
    view = "playlists"
    loadCloud()
    if (!opened) open()
  }

  function setCloudValue(key, value) {
    var next = Object.assign({}, cloudValues)
    next[key] = value
    cloudValues = next
  }

  // `path` and `title` come from whichever form was used (the panel's or
  // the full-screen view's); the panel's own fields when left out.
  function connectCloud(path, title) {
    if (cloudAddProc.running) return
    if (cloudKind === "remote" && cloudRemote === "") { cloudError = strings.t("cloud.pickRemote"); return }
    var form = Model.cloudForm(cloudKind, cloudValues, cloudRemote,
      path !== undefined ? path : (cloudPathInput ? cloudPathInput.text : ""),
      title !== undefined ? title : (cloudTitleInput ? cloudTitleInput.text : ""))
    if (!form) return
    cloudError = ""
    cloudBusy = cloudKindSpec.oauth ? "waiting" : "checking"
    cloudAddProc.form = form
    cloudAddProc.running = true
  }

  // rclone does the talking to every storage; installing it needs the
  // password, so it runs in a terminal the user sees.
  function installRclone() {
    installProc.command = ["omarchy-launch-floating-terminal-with-presentation", "omarchy pkg add rclone"]
    installProc.running = true
    close()
  }

  function addMusicFolder() {
    cloudKind = "local"
    connectCloud(cloudMusicDir, "")
  }

  function removeCloud(id) {
    if (cloudRemoveProc.running) return
    cloudRemoveProc.command = helper(["cloud-remove", id])
    cloudRemoveProc.running = true
  }

  // Mixes you can add a song to, plus starting a new one.
  readonly property var mixTargets: {
    var out = []
    var items = svc.my.items
    for (var i = 0; i < items.length; i++)
      if (/^mix:[a-f0-9]{8}$/.test(items[i].id))
        out.push({ kind: "mixTarget", id: items[i].id, title: items[i].title, count: items[i].count, section: strings.t("mix.section") })
    out.push({ kind: "mixTarget", id: "new", title: strings.t("mix.new"), count: null, section: strings.t("mix.section") })
    return out
  }

  // ---- explore -------------------------------------------------------------
  property string exploreService: "yt"      // "yt" (Explore) or "sc" (SoundCloud search)
  property var exploreSections: []
  property var exploreRowsData: []
  property bool exploreLoading: false
  property string exploreError: ""
  property string exploreMode: "home"        // "home" | "mood" | "search"
  property string exploreTitle: ""
  property bool tracksFromExplore: false
  readonly property var exploreEntry: ({ kind: "explore", id: "__explore", title: strings.t("explore.title"),
    artist: strings.t("explore.subtitle") })
  readonly property var downloadsEntry: ({ kind: "list", id: "DOWNLOADS", title: strings.t("list.downloads"),
    artist: strings.t("list.downloadsHint") })

  // ---- download ------------------------------------------------------------
  property var downloadTrack: null           // the song the download screen is for
  property string viewBeforeDownload: "playlists"
  property var downloading: null             // { id, title, stage } while one runs
  property string noticeFolder: ""           // "Open folder" after a download
  // A newer version of this plugin: { version, current, notes } (see
  // checkForUpdate); offered as a card until updated or put off.
  property var updateInfo: null
  property string updateDeclined: ""
  property bool youtubeFailing: false
  property string healthReason: ""
  onMirrorsOnChanged: if (mirrorsOn) mirrorOffer = null
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
  // A station shows the song on air (when the stream says), the station under it.
  property string onAir: ""
  readonly property bool onRadio: currentTrack !== null && Model.isRadio(currentTrack.id)
  readonly property string nowTitle: onRadio && onAir !== "" ? onAir : currentTrack ? currentTrack.title : Model.cleanText(mediaTitle)
  readonly property string nowArtist: onRadio ? (onAir !== "" ? currentTrack.title : strings.t("rd.live")) : currentTrack ? currentTrack.artist : ""
  readonly property string barLabel: showTitle && connected && !barVertical && nowTitle !== "" ? Model.truncate(nowTitle, 28) : ""
  // Non-empty when autoplay should extend the queue from this song now.
  readonly property string autoplayDueSeed: Model.autoplaySeed({
    enabled: autoplayEnabled, connected: connected, repeat: repeatMode,
    pos: playlistPos, count: playlistCount,
    trackId: currentTrack ? currentTrack.id : "", requested: autoplayRequested
  })
  onAutoplayDueSeedChanged: if (autoplayDueSeed !== "") runAutoplay(autoplayDueSeed)
  readonly property string nowCoverUrl: showCovers && currentTrack
    ? Model.trackCover(currentTrack, largeCoverFailedFor === currentTrack.id ? "small" : "large") : ""

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }
  // For FullView.qml, which shares this panel's strings.
  readonly property var i18n: strings

  function playlistTitle(p) {
    if (!p) return ""
    if (p.id === "LM") return strings.t("list.likedMusic")
    if (p.id === "DOWNLOADS") return strings.t("list.downloads")
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
    if (service !== "yt") loadService(service, force)
    else loadYouTube(force)
  }

  function loadYouTube(force) {
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
    if (msg.type === "playlists" && msg.service !== "yt") {
      setSvc(msg.service, { items: msg.items, loading: msg.stale, error: "", setup: "" })
    } else if (msg.type === "chords") {
      if (msg.key === chordsProc.key) { chords = msg; chordsStage = ""; chordsError = "" }
    } else if (msg.type === "chordsProgress") {
      if (msg.key === chordsProc.key) chordsStage = msg.stage
    } else if (msg.type === "scores") {
      if (msg.key === scoresProc.key) scores = msg
    } else if (msg.type === "aiMix") {
      if (msg.state === "asking" || msg.state === "finding") { aiState = msg.state; if (msg.agent) aiAgent = msg.agent }
      else if (msg.state === "done") {
        aiState = ""
        loadService("my", true)
        // A desktop notification: making one takes half a minute, and the
        // panel has usually been closed by then.
        notifyAiMix(msg.title, msg.count)
        if (!aiProc.auto) {
          showNotice(strings.t("ai.ready").arg(msg.title).arg(msg.count))
          openList({ id: "ai:mix", title: msg.title, count: msg.count })
        }
      }
    } else if (msg.type === "radioCountries") {
      radioCountries = msg.items
      radioCountry = msg.current
    } else if (msg.type === "podcastSubs") {
      var subs = {}
      for (var si = 0; si < msg.ids.length; si++) subs[msg.ids[si]] = true
      podcastSubs = subs
      if (source === "podcastSub" && service === "pc") loadService("pc", true)
    } else if (msg.type === "radioFavs") {
      var set = {}
      for (var fi = 0; fi < msg.ids.length; fi++) set[msg.ids[fi]] = true
      radioFavs = set
      if (view === "tracks" && openPlaylist && openPlaylist.id === "rd:fav") loadTracks(true)
      if (service === "rd") loadService("rd", true)
    } else if (msg.type === "lyrics") {
      if (msg.key === lyricsProc.key) { lyrics = msg; lyricsLoading = false }
    } else if (msg.type === "cloud") {
      if (msg.state === "list") {
        cloudSources = msg.sources
        cloudRemotes = msg.remotes
        rcloneInstalled = msg.rclone
        cloudMusicDir = msg.musicDir
        if (cloudRemote === "" && msg.remotes.length > 0) cloudRemote = msg.remotes[0].name
        // rclone already knows a storage: offer it first, nothing to type.
        if (!cloudKindTouched && msg.musicDir !== "" && msg.sources.length === 0) cloudKind = "local"
        else if (!cloudKindTouched && msg.remotes.length > 0) cloudKind = "remote"
      } else if (msg.state === "waiting" || msg.state === "checking") {
        cloudBusy = msg.state
      } else if (msg.state === "added") {
        cloudBusy = ""
        cloudFormOpen = false
        cloudValues = ({})
        cloudFormEpoch++
        if (cloudPathInput) cloudPathInput.text = ""
        if (cloudTitleInput) cloudTitleInput.text = ""
        showNotice(strings.t("cloud.added").arg(msg.title))
        setSvc("cl", { setup: "", error: "", items: [] })
        loadCloud()
        loadService("cl", true)
      } else if (msg.state === "removed") {
        loadCloud()
        setSvc("cl", { items: [] })
        loadService("cl", true)
      }
    } else if (msg.type === "mixAdded") {
      showNotice(strings.t(msg.already ? "mix.already" : "mix.added").arg(msg.title))
      loadService("my", true)
    } else if (msg.type === "spotify") {
      if (msg.state === "waiting") showNotice(strings.t("sp.waiting"), false, true)
      else if (msg.state === "connected") {
        spotifyWaiting = false
        showNotice(strings.t("sp.connected").arg(msg.user))
        setSvc("sp", { setup: "", error: "", items: [] })
        loadService("sp", true)
      }
    } else if (msg.type === "playlists") {
      playlists = msg.items
      if (!msg.stale) playlistsLoading = false
    } else if (msg.type === "tracks" && source === "recent") {
      recentTracks = msg.items.slice(0, 30)
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
    } else if (msg.type === "explore") {
      if (source === "explore") {
        if (msg.mood !== "" && exploreMode !== "mood") return
        if (msg.mood === "") exploreSections = msg.sections
        exploreRowsData = Model.exploreRows(msg.sections)
        if (!msg.stale) exploreLoading = false
      }
    } else if (msg.type === "search") {
      if (exploreMode === "search") {
        exploreRowsData = msg.items.map(function(it) {
          return { kind: it.kind, id: it.id, title: it.title, artist: it.artist, duration: it.duration, section: "" }
        })
        exploreLoading = false
      }
    } else if (msg.type === "downloading") {
      if (downloading && downloading.id === msg.id) {
        downloading = { id: downloading.id, title: downloading.title, stage: msg.stage }
      }
    } else if (msg.type === "downloaded") {
      var saved = downloading ? downloading.title : ""
      downloading = null
      showNotice(strings.t("download.done").arg(Model.truncate(saved, 50)) + "\n" + msg.path, false, true)
      noticeFolder = msg.folder
      if (view === "tracks" && openPlaylist && openPlaylist.id === "DOWNLOADS") loadTracks(true)
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
      else if (source === "service") setSvc(servicePlaylistsProc.target, { loading: false, error: msg.setup ? "" : msg.message, setup: msg.setup })
      else if (source === "spotify") { spotifyWaiting = false; showNotice(msg.message, false, true) }
      else if (source === "countries") showNotice(strings.t("notice.failed").arg(msg.message))
      else if (source === "ai") { aiState = ""; if (!aiProc.auto) aiError = msg.message }
      else if (source === "chords") { chordsStage = ""; chordsError = msg.message; numpyMissing = msg.setup === "numpy" }
      else if (source === "scores" || source === "openScore") { if (source === "openScore") showNotice(msg.message) }
      else if (source === "lyrics") { lyricsLoading = false; lyrics = { key: lyricsProc.key, lines: [], none: true, synced: false } }
      else if (source === "cloudAdd") { cloudBusy = ""; cloudError = msg.message; if (msg.setup === "rclone") rcloneInstalled = false }
      else if (source === "cloud") showNotice(msg.message)
      else if (source === "mix") showNotice(strings.t("notice.failed").arg(msg.message))
      else if (source === "explore" || source === "search") { exploreError = msg.message; exploreLoading = false }
      else if (source === "download") {
        downloading = null
        showNotice(strings.t("notice.failed").arg(msg.message), msg.auth, true)
      }
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
    id: servicePlaylistsProc
    property string target: ""
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "service") } }
    onExited: {
      if (root.svc[target] && root.svc[target].loading) root.setSvc(target, { loading: false })
      // The full-screen view asks for every service at once: one at a time.
      if (root.serviceQueue.length > 0) {
        var next = root.serviceQueue[0]
        root.serviceQueue = root.serviceQueue.slice(1)
        Qt.callLater(function() { root.loadService(next.name, next.force) })
      }
    }
  }

  Process {
    id: spotifyLoginProc
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "spotify") } }
    onExited: root.spotifyWaiting = false
  }

  Process {
    id: cloudProc
    command: root.helper(["cloud"])
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "cloud") } }
  }

  // The form goes over stdin, so no password is ever on a command line.
  Process {
    id: cloudAddProc
    property string form: ""
    command: root.helper(["cloud-add"])
    stdinEnabled: true
    onStarted: write(form + "\n")
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "cloudAdd") } }
    onExited: { root.cloudBusy = ""; form = "" }
  }

  Process { id: installProc }

  // ---- scrobbling: Last.fm and ListenBrainz ------------------------------------------
  // Who's connected ("" when not); the form open in settings, if any.
  property var scrobbleState: ({ listenbrainz: "", lastfm: "" })
  property string scrobbleForm: ""
  property bool scrobbleWaiting: false
  function connectScrobble(service, values) {
    if (scrobbleProc.running) return
    scrobbleProc.form = JSON.stringify(Object.assign({ service: service }, values))
    scrobbleProc.command = helper(["scrobble", "--set"])
    scrobbleProc.running = true
  }
  function disconnectScrobble(service) {
    if (scrobbleProc.running) return
    scrobbleProc.form = ""
    scrobbleProc.command = helper(["scrobble", "--remove", service])
    scrobbleProc.running = true
  }
  Process {
    id: scrobbleProc
    property string form: ""
    stdinEnabled: true
    onStarted: write(form + "\n")
    stdout: SplitParser {
      onRead: function(line) {
        var msg = Model.parseLine(line)
        if (!msg) return
        if (msg.type === "scrobbleWaiting") { root.scrobbleWaiting = true; root.showNotice(strings.t("scrobble.approve")) }
        else if (msg.type === "error") root.showNotice(msg.message, false, true)
        else if (msg.type === "scrobble") {
          root.scrobbleState = { listenbrainz: msg.listenbrainz, lastfm: msg.lastfm }
          if (scrobbleProc.form !== "") {
            root.scrobbleForm = ""
            root.showNotice(strings.t("scrobble.connected"))
          }
        }
      }
    }
    onExited: { root.scrobbleWaiting = false; form = "" }
  }

  Process {
    id: cloudRemoveProc
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "cloud") } }
  }

  Process {
    id: mixAddProc
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "mix") } }
  }

  Process {
    id: mixEditProc
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "mix") } }
    onExited: {
      root.loadService("my", true)
      if (root.openPlaylist && /^mix:/.test(root.openPlaylist.id)) root.loadTracks(true)
    }
  }

  Process { id: openUrlProc }

  Process {
    id: reportProc
    stdout: SplitParser {
      onRead: function(line) {
        var msg = Model.parseMpvLine(line)
        if (msg && msg.type === "report") root.showNotice(strings.t("report.opened"), false, true)
        else if (msg && msg.type === "error") root.showNotice(Model.cleanText(msg.message), false, true)
      }
    }
  }

  Process {
    id: spotifyLogoutProc
    command: root.helper(["spotify-logout"])
  }

  Process {
    id: exploreProc
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "explore") } }
    onExited: root.exploreLoading = false
  }

  Process {
    id: searchProc
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "search") } }
    onExited: root.exploreLoading = false
  }

  Process {
    id: downloadProc
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "download") } }
    onExited: if (root.downloading) root.downloading = null
  }

  Process { id: openFolderProc }

  FolderDialog {
    id: folderDialog
    title: strings.t("download.pick")
    onAccepted: {
      var path = decodeURIComponent(String(selectedFolder).replace(/^file:\/\//, ""))
      if (path.charAt(0) === "/") root.saveSettings({ downloadDir: path })
      root.open()
    }
    onRejected: root.open()
  }

  Process {
    id: updateCheckProc
    stdout: SplitParser { onRead: function(line) { root.handleUpdateLine(line) } }
  }

  Process {
    id: updateApplyProc
    property string output: ""
    command: ["omarchy", "plugin", "update", root.moduleName, "--yes"]
    stdout: SplitParser { onRead: function(line) { updateApplyProc.output = String(line).slice(-200) } }
    stderr: SplitParser { onRead: function(line) { updateApplyProc.output = String(line).slice(-200) } }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        restartProc.running = true
      } else {
        root.showNotice(strings.t("update.failed").arg(Model.cleanText(output || ("exit " + exitCode), 160)), false, true)
      }
    }
  }

  // Detached, so it outlives the shell it restarts.
  Process {
    id: restartProc
    command: ["setsid", "-f", "omarchy", "restart", "shell"]
  }

  Timer {
    id: updateTimer
    // A while after start, then daily (the helper skips it when checked
    // in the last day).
    interval: 45000
    repeat: true
    running: root.updateCheckOn
    onTriggered: {
      interval = 6 * 3600 * 1000
      root.checkForUpdate(86400)
    }
  }

  // The desktop notification for a song that won't play; its button opens
  // the panel, where the offer waits.
  Process {
    id: notifyProc
    stdout: SplitParser { onRead: function(line) { if (String(line).trim() === "open") root.open() } }
  }

  Process {
    id: signinProc
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
      root.noticeFolder = ""
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
        // Settings may have changed while no panel was connected.
        root.sendPlayerSettings()
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

  property var serviceQueue: []
  function loadService(name, force) {
    if (name === "yt") return
    if (servicePlaylistsProc.running) {
      if (servicePlaylistsProc.target !== name && !serviceQueue.some(function(q) { return q.name === name }))
        serviceQueue = serviceQueue.concat([{ name: name, force: force }])
      return
    }
    setSvc(name, { loading: true, error: "" })
    servicePlaylistsProc.target = name
    servicePlaylistsProc.command = helper(["playlists", "--service", name, "--browser", browser, "--max-age", force ? "0" : "3600"])
    servicePlaylistsProc.running = true
  }

  function saveSetup(name, value) {
    var v = String(value || "").trim()
    if (v === "") return
    if (name === "sc") saveSettings({ soundcloudUser: v })
    else if (name === "dz") saveSettings({ deezerUser: v })
    else if (name === "sp") saveSettings({ spotifyClientId: v })
    setSvc(name, { setup: "", error: "", items: [] })
    Qt.callLater(function() { loadService(name, true) })
  }

  function connectSpotify() {
    if (spotifyLoginProc.running) return
    spotifyWaiting = true
    spotifyLoginProc.command = helper(["spotify-login", "--browser", browser])
    spotifyLoginProc.running = true
  }

  function addToMix(target) {
    if (!addTrack || mixAddProc.running) return
    var t = { id: addTrack.id, title: addTrack.title || "", artist: addTrack.artist || "", duration: addTrack.duration || null }
    // Any cover the list showed; the helper keeps only allowed hosts and its own files.
    if (addTrack.cover) t.cover = String(addTrack.cover)
    mixAddProc.command = helper(["mix-add", target.id, "--track", JSON.stringify(t)])
    mixAddProc.running = true
    closeAddTo()
  }

  function removeFromMix(track) {
    if (!openPlaylist || !/^mix:[a-f0-9]{8}$/.test(openPlaylist.id) || !track || mixEditProc.running) return
    mixEditProc.command = helper(["mix-remove", openPlaylist.id, track.id])
    mixEditProc.running = true
  }

  // ---- lyrics ----------------------------------------------------------------------
  // For the full-screen view's Lyrics: { key, lines, synced, instrumental,
  // none, source } for the playing song (Model.sanitizeLyrics).
  property var lyrics: null
  property bool lyricsLoading: false
  // Asked for while lyrics are on screen: the position is read 4× a second.
  property bool fastPosition: false

  function loadLyrics(track) {
    if (!track || !Model.TRACK_KEY_RE.test(String(track.id))) return
    if (lyrics && lyrics.key === track.id) return
    if (lyricsProc.running) { if (lyricsProc.key !== track.id) lyricsProc.queued = track; return }
    lyrics = null
    lyricsLoading = true
    lyricsProc.key = track.id
    lyricsProc.command = helper(["lyrics", track.id, "--title", track.title || "", "--artist", track.artist || "",
      "--duration", String(Math.round(duration > 0 ? duration : (track.duration || 0)))])
    lyricsProc.running = true
  }

  Process {
    id: lyricsProc
    property string key: ""
    property var queued: null
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "lyrics") } }
    onExited: {
      root.lyricsLoading = false
      var next = queued
      queued = null
      if (next) Qt.callLater(function() { root.loadLyrics(next) })
    }
  }

  // ---- AI Mix ----------------------------------------------------------------------
  // A mix your AI agent makes from what you listen to (bin/ytmusic-mpv
  // ai-mix). Off until turned on: it sends a summary of your taste to the
  // agent. When on, a mix older than a day is remade by itself.
  readonly property bool aiEnabled: setting("aiMix", "Off") === "On"
  property string aiState: ""                 // "" | "asking" | "finding"
  property string aiAgent: ""
  property string aiError: ""
  readonly property var aiEntry: ({ kind: "explore", id: "__aimake", title: strings.t("ai.make"), artist: strings.t("ai.makeHint") })

  // Recently played, for the player window's home.
  property var recentTracks: []
  Process {
    id: recentProc
    command: root.helper(["tracks", "hist:recent"])
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "recent") } }
  }
  onFullOpenChanged: if (fullOpen && !recentProc.running) recentProc.running = true

  function openAiMaker() {
    aiError = ""
    if (service !== "my") switchService("my")
    view = "ai"
    cursorIndex = -1
    if (!opened) open()
  }

  function makeAiMix(wish, auto) {
    if (aiProc.running) return
    if (!aiEnabled) saveSettings({ aiMix: "On" })
    aiError = ""
    aiState = "asking"
    aiProc.auto = auto === true
    aiProc.command = helper(["ai-mix", "--browser", browser].concat(wish ? ["--prompt", wish] : [])
      .concat(auto ? ["--if-older", "86400"] : []))
    aiProc.running = true
  }

  function notifyAiMix(title, count) {
    if (aiNotifyProc.running) return
    var peers = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    if (peers.length > 0 && peers[0] !== root) return
    aiNotifyProc.title = title
    aiNotifyProc.command = ["notify-send", "--app-name=Omarchy Music Player", "--icon=audio-x-generic",
      "--action=play=" + strings.t("ai.notifyPlay"), "--action=open=" + strings.t("ai.notifyOpen"),
      strings.t("ai.notifyTitle").arg(title), strings.t("ai.notifyBody").arg(count)]
    aiNotifyProc.running = true
  }
  Process {
    id: aiNotifyProc
    property string title: ""
    stdout: SplitParser {
      onRead: function(line) {
        var action = String(line).trim()
        if (action !== "play" && action !== "open") return
        if (root.service !== "my") root.switchService("my")
        root.openList({ id: "ai:mix", title: aiNotifyProc.title, count: null })
        if (action === "play") root.play(0, false)
        else root.open()
      }
    }
  }

  Process {
    id: aiProc
    property bool auto: false
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "ai") } }
    onExited: root.aiState = ""
  }
  // Remade by itself once a day while it's on (and only then).
  Timer {
    interval: 3 * 3600 * 1000
    repeat: true
    triggeredOnStart: true
    running: root.aiEnabled
    onTriggered: root.makeAiMix("", true)
  }

  // ---- notes: chords and scores -----------------------------------------------------
  // For the player window's Notes: the playing song's chords in time
  // (Model.sanitizeChords) and the sheet music and tabs found for it.
  property var chords: null
  property string chordsStage: ""            // "audio" | "listen" while the helper works
  property string chordsError: ""
  property bool numpyMissing: false
  property var scores: null

  function loadNotes(track) {
    if (!track || !Model.TRACK_KEY_RE.test(String(track.id))) return
    if (!(scores && scores.key === track.id) && !scoresProc.running) {
      scores = null
      scoresProc.key = track.id
      scoresProc.command = helper(["scores", track.id, "--title", track.title || "", "--artist", track.artist || ""])
      scoresProc.running = true
    }
    if (chords && chords.key === track.id) return
    if (chordsProc.running) { if (chordsProc.key !== track.id) chordsProc.queued = track; return }
    chords = null
    chordsError = ""
    chordsStage = "audio"
    chordsProc.key = track.id
    chordsProc.command = helper(["chords", track.id, "--browser", browser, "--playback-cookies", playbackCookies ? "1" : "0"])
    chordsProc.running = true
  }

  function openScore(url) {
    openScoreProc.command = helper(["open-score", url])
    openScoreProc.running = true
  }

  // Chord detection needs numpy; installing asks for the password, so it
  // runs in a terminal the user sees.
  function installNumpy() {
    installProc.command = ["omarchy-launch-floating-terminal-with-presentation", "omarchy pkg add python-numpy"]
    installProc.running = true
    numpyMissing = false
  }

  Process {
    id: chordsProc
    property string key: ""
    property var queued: null
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "chords") } }
    onExited: {
      if (root.chordsStage !== "" && !(root.chords && root.chords.key === key)) root.chordsStage = ""
      var next = queued
      queued = null
      if (next) Qt.callLater(function() { root.loadNotes(next) })
    }
  }
  Process {
    id: scoresProc
    property string key: ""
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "scores") } }
  }
  Process {
    id: openScoreProc
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "openScore") } }
  }

  // ---- full screen ---------------------------------------------------------------
  // The whole player on the whole screen (FullView.qml), like Apple Music's
  // window: a sidebar with every service, big covers, the queue. It shares
  // this panel's state, so both always agree.
  property bool fullOpen: false

  function openFull() {
    close()
    // Already open (maybe on another workspace): bring it here.
    if (fullOpen) { focusFullProc.running = true; return }
    fullOpen = true
    if (playlists.length === 0 && !playlistsLoading) loadYouTube(false)
    var names = ["my", "sp", "sc", "cl"]
    for (var i = 0; i < names.length; i++)
      if (svc[names[i]].items.length === 0 && svc[names[i]].setup === "") loadService(names[i], false)
    loadCloud()
    if (exploreSections.length === 0 && !exploreProc.running) loadExplore(21600)
    if (!likedProc.running) likedProc.running = true
    if (connected) requestPosition()
    else attach()
  }

  function closeFull() { fullOpen = false }

  Process {
    id: focusFullProc
    command: ["sh", "-c", "a=$(hyprctl clients -j | jq -r '.[] | select(.class == \"org.quickshell\" and .title == \"Omarchy Music Player\") | .address' | head -n1); [ -n \"$a\" ] && hyprctl dispatch \"hl.dsp.focus({ window = \\\"address:$a\\\" })\" >/dev/null"]
  }

  // Spotify's and SoundCloud's setup lives in the panel: leave full screen,
  // then open the panel on that tab once the full-screen window is gone
  // (opened in the same moment, the panel would lose the keyboard to it).
  // Spotify's and SoundCloud's setup lives in the panel, which opens over
  // the player window.
  function connectInPanel(name) {
    switchService(name)
    if (!opened) open()
  }


  // ---- explore ---------------------------------------------------------------
  function openSoundCloudSearch() {
    exploreService = "sc"
    view = "explore"
    cursorIndex = -1
    exploreMode = "search"
    exploreTitle = strings.t("sc.searchTitle")
    exploreRowsData = []
    exploreError = ""
    focusSearch()
  }

  // The search field under the tabs: results right away, wherever the panel
  // was; Back returns there.
  property string searchReturnView: ""
  function searchFromBar(text) {
    var q = String(text || "").trim()
    // In the country list the field narrows it; Enter picks the only match.
    if (view === "countries") {
      countryFilter = q
      if (countryRows.length === 1) chooseCountry(countryRows[0])
      return
    }
    if (q === "") return
    if (view !== "explore") {
      if (view === "addTo") closeAddTo()
      searchReturnView = view === "settings" || view === "download" ? "playlists" : view
      exploreService = ["sc", "rd", "pc", "dz", "mc", "au"].indexOf(service) >= 0 ? service : "yt"
    }
    view = "explore"
    runSearch(q)
  }

  function openExplore() {
    searchReturnView = ""
    exploreService = "yt"
    view = "explore"
    cursorIndex = -1
    showExploreHome()
    if (exploreSections.length === 0 || exploreError !== "") loadExplore(21600)
  }

  function showExploreHome() {
    exploreMode = "home"
    exploreTitle = strings.t("explore.title")
    exploreRowsData = Model.exploreRows(exploreSections)
    cursorIndex = -1
  }

  function loadExplore(maxAge) {
    if (exploreProc.running) return
    exploreError = ""
    exploreLoading = true
    exploreProc.command = helper(["explore", "--max-age", String(maxAge)])
    exploreProc.running = true
  }

  function openMood(item) {
    if (exploreProc.running) return
    exploreMode = "mood"
    exploreTitle = item.title
    exploreRowsData = []
    exploreError = ""
    exploreLoading = true
    cursorIndex = -1
    exploreProc.command = helper(["mood", item.id])
    exploreProc.running = true
  }

  function runSearch(text) {
    var q = String(text || "").trim()
    if (q === "" || searchProc.running) return
    exploreMode = "search"
    exploreTitle = strings.t("explore.results").arg(Model.truncate(q, 40))
    exploreRowsData = []
    exploreError = ""
    exploreLoading = true
    cursorIndex = -1
    searchProc.command = helper(["search", q, "--service", exploreService, "--browser", browser])
    searchProc.running = true
  }

  // A song plays with its radio after it, like YouTube Music; a list opens.
  function activateExplore(item) {
    if (!item) return
    // A SoundCloud result plays with the other results after it.
    if (item.kind === "song" && !Model.isYouTube(item.id)) {
      var at = exploreRowsData.indexOf(item)
      openPlaylist = { id: exploreService + ":search", title: exploreTitle, count: null }
      tracks = exploreRowsData
      tracksFromExplore = true
      play(at >= 0 ? at : Math.max(0, cursorIndex), false)
      return
    }
    if (item.kind === "song") { startRadio(item); tracksFromExplore = true }
    else if (item.kind === "mood") openMood(item)
    else if (item.kind === "list") {
      openPlaylist = { id: item.id, title: item.title, count: null }
      tracks = []
      cursorIndex = -1
      tracksFromExplore = true
      view = "tracks"
      loadTracks(false)
    }
  }

  // ---- download --------------------------------------------------------------
  function openDownload(track) {
    if (!track || !Model.canDownload(track.id)) return
    downloadTrack = { id: track.id, title: track.title, artist: track.artist || "" }
    if (view !== "download") viewBeforeDownload = view === "addTo" || view === "settings" ? "playlists" : view
    view = "download"
    cursorIndex = -1
    if (!opened) open()
  }

  // The folder picker is the desktop's own (GTK) dialog. The panel steps
  // aside while it is open, since it holds the keyboard.
  function chooseFolder() {
    close()
    folderDialog.currentFolder = "file://" + downloadPath
    folderDialog.open()
  }

  function startDownload() {
    var t = downloadTrack
    if (!t) return
    if (downloadProc.running) { showNotice(strings.t("download.busy")); return }
    downloading = { id: t.id, title: t.title, stage: "fetch" }
    downloadProc.command = helper([
      "download", t.id, "--dir", downloadPath, "--format", downloadFormat,
      "--title", t.title, "--artist", t.artist, "--cover", downloadCover ? "1" : "0",
      "--browser", browser, "--playback-cookies", playbackCookies ? "1" : "0"
    ])
    downloadProc.running = true
    view = viewBeforeDownload
    cursorIndex = -1
  }

  // ---- problem reports -------------------------------------------------------
  // Everything about an error, gathered by the helper and opened as a
  // filled-in GitHub issue: the user only presses Submit.
  function reportProblem(where, message) {
    if (reportProc.running) return
    reportProc.command = helper(["report", "--where", String(where || "panel"), "--error", String(message || ""),
      "--service", service, "--browser", browser])
    reportProc.running = true
  }

  // The error a report is about: what's on screen, else YouTube's own reason.
  readonly property string troubleText: playError !== "" ? playError
    : youtubeFailing ? (healthReason || ytdlError.replace(/^ERROR: /, "") || strings.t("report.troubleTitle")) : ""

  // ---- plugin updates ------------------------------------------------------
  function checkForUpdate(maxAge) {
    if (!updateCheckOn || updateCheckProc.running || updateApplyProc.running) return
    updateCheckProc.command = helper(["update-check", "--max-age", String(maxAge)])
    updateCheckProc.running = true
  }

  function handleUpdateLine(line) {
    var u = Model.parseUpdate(line)
    if (!u) return
    if (u.state !== "available" || u.version === updateDeclined) { updateInfo = null; return }
    var fresh = updateInfo === null || updateInfo.version !== u.version
    updateInfo = u
    if (fresh && youtubeFailing && !opened) notifyUpdate(u.version)
  }

  function notifyTrouble() {
    if (notifyProc.running) return
    var peers = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    if (peers.length > 0 && peers[0] !== root) return
    notifyProc.command = ["notify-send", "--app-name=Omarchy Music Player", "--icon=dialog-warning",
      "--action=open=" + strings.t("offer.notifyOpen"),
      strings.t("report.troubleTitle"), strings.t("report.notifyBody")]
    notifyProc.running = true
  }

  function notifyUpdate(version) {
    if (notifyProc.running) return
    var peers = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    if (peers.length > 0 && peers[0] !== root) return
    notifyProc.command = ["notify-send", "--app-name=Omarchy Music Player", "--icon=software-update-available",
      "--action=open=" + strings.t("offer.notifyOpen"),
      strings.t("update.notifyTitle"), strings.t("update.notifyBody").arg(version)]
    notifyProc.running = true
  }

  // `omarchy plugin update` pulls the new version; the shell then restarts
  // to load it (the player keeps playing).
  function applyUpdate() {
    if (updateApplyProc.running) return
    updateApplyProc.output = ""
    updateApplyProc.running = true
  }

  function declineUpdate() {
    if (updateInfo) updateDeclined = updateInfo.version
    updateInfo = null
  }

  // ---- backup mirrors offer -------------------------------------------------
  function notifyUnplayable(title) {
    if (notifyProc.running) return
    // Every monitor's bar has this widget: one notification, from the first,
    // and none while a panel is open (it shows the offer itself).
    var peers = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    for (var i = 0; i < peers.length; i++) if (peers[i] && peers[i].opened) return
    if (peers.length > 0 && peers[0] !== root) return
    notifyProc.command = ["notify-send", "--app-name=Omarchy Music Player", "--icon=audio-x-generic",
      "--action=open=" + strings.t("offer.notifyOpen"),
      strings.t("offer.notifyTitle"), strings.t("offer.notifyBody").arg(title)]
    notifyProc.running = true
  }

  // Yes: turn the mirrors on (saved like any setting) and play the song again.
  function acceptMirrorOffer() {
    var offer = mirrorOffer
    mirrorOffer = null
    if (!offer) return
    saveSettings({ backupMirrors: "On" })
    playAgain(offer.id)
  }

  function declineMirrorOffer() {
    mirrorOffer = null
    mirrorOfferDeclined = true      // until the shell restarts
  }

  // The song from the current queue again: in the running player, or by
  // starting the queue's list at it if the player has stopped.
  function playAgain(id) {
    var queue = session && session.tracks ? session.tracks : []
    var index = -1
    for (var i = 0; i < queue.length; i++) if (queue[i].id === id) { index = i; break }
    if (index < 0) return
    if (connected) {
      send(["playlist-play-index", index])
      send(["set_property", "pause", false])
      return
    }
    if (playProc.running) return
    playError = ""
    starting = true
    playProc.command = helper([
      "play", session.playlistId, "--index", String(index), "--video-id", id,
      "--shuffle", "0", "--browser", browser,
      "--playback-cookies", playbackCookies ? "1" : "0",
      "--volume", String(Math.round(volume || defaultVolume)),
      "--repeat", repeatMode, "--title", session.playlistTitle
    ].concat(playerArgs()))
    playProc.running = true
  }

  function trackTitleById(id) {
    var queue = session && session.tracks ? session.tracks : []
    for (var i = 0; i < queue.length; i++) if (queue[i].id === id) return queue[i].title
    return id
  }

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
      onAir = ""
      position = 0
      break
    case "playlist-count":
      playlistCount = typeof data === "number" ? data : 0
      // A radio or autoplay changed the queue (possibly from another bar).
      sessionFile.reload()
      break
    case "volume": if (typeof data === "number") volume = data; break
    case "user-data/ytmusic/fallback": {
      var used = Model.recentReport(data, Date.now() / 1000)
      if (used) showNotice(strings.t("notice.backupSource").arg(Model.truncate(trackTitleById(String(used.id)), 60))
        .arg(Model.cleanText(used.via, 60)))
      break
    }
    case "user-data/ytmusic/unplayable": {
      var offer = mirrorOfferDeclined ? null : Model.mirrorOffer(Model.recentReport(data, Date.now() / 1000), mirrorsOn)
      if (offer) {
        offer.title = Model.truncate(trackTitleById(offer.id), 60)
        mirrorOffer = offer
        if (!opened) notifyUnplayable(offer.title)
      }
      break
    }
    case "user-data/ytmusic/health": {
      var health = Model.recentReport(data, Date.now() / 1000)
      if (health && health.state === "failing") {
        // The "Music isn't playing" card says it, with the report button.
        healthReason = Model.truncate(Model.cleanText(health.reason), 200)
        youtubeFailing = true
        checkForUpdate(600)        // a fix may be out already
        if (!opened) notifyTrouble()
      } else if (health && health.state === "ok") {
        youtubeFailing = false
      }
      break
    }
    case "user-data/ytmusic/features": pauseFadeSupported = !!data && data.pause_fade === true; break
    case "metadata/by-key/icy-title": onAir = typeof data === "string" ? Model.cleanText(data, 200) : ""; break
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
    pauseFadeSupported = false
    mediaTitle = ""
    duration = 0
    position = 0
    playlistPos = -1
    playlistCount = 0
    seekingRaw = false
    pausedForCache = false
  }

  Timer {
    // Lyrics follow the song closely; otherwise once a second is plenty.
    interval: root.fastPosition ? 250 : 1000
    repeat: true
    running: root.connected && (root.opened || root.fullOpen) && !root.paused
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
    ].concat(playerArgs()))
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
    ].concat(playerArgs()))
  }

  function playerArgs() {
    return ["--fade-in", String(fadeIn), "--fade-out", String(fadeOut), "--pause-fade", String(pauseFade),
      "--transition", transitionMode, "--xfade", String(crossfade)]
  }

  function sendPlayerSetting(key, value) {
    send(["script-message", "ytmusic-set", key, String(value)])
  }

  function sendPlayerSettings() {
    sendPlayerSetting("fade_in", fadeIn)
    sendPlayerSetting("fade_out", fadeOut)
    sendPlayerSetting("xfade", crossfade)
    sendPlayerSetting("pause_fade", pauseFade)
    sendPlayerSetting("transition", transitionMode)
  }

  // Saved in this widget's own shell.json entry; every bar picks it up.
  function saveSettings(changes) {
    var shell = bar ? bar.shell : null
    if (!shell || typeof shell.updateEntryInline !== "function") return
    settings = Object.assign({}, settings, changes)
    shell.updateEntryInline(moduleName, settings)
  }

  // ---- settings screen -----------------------------------------------------
  readonly property var fadeChoices: [0, 1, 2, 3, 5, 8]
  readonly property var crossfadeChoices: [4, 6, 8, 12]
  readonly property var pauseFadeChoices: [0, 0.3, 0.6, 1, 2]
  readonly property var settingsItems: [
    { key: "fadeIn", kind: "choice", section: strings.t("settings.playback"), label: strings.t("settings.fadeIn"),
      hint: strings.t("settings.fadeInHint"), choices: fadeChoices, value: fadeIn, enabled: true },
    { key: "fadeOut", kind: "choice", section: "", label: strings.t("settings.fadeOut"),
      hint: strings.t("settings.fadeOutHint"), choices: fadeChoices, value: fadeOut, enabled: true },
    { key: "pauseFade", kind: "choice", section: "", label: strings.t("settings.pauseFade"),
      hint: strings.t("settings.pauseFadeHint"), choices: pauseFadeChoices, value: pauseFade, enabled: true },
    { key: "transition", kind: "toggle", section: "", label: strings.t("settings.peakMix"),
      hint: strings.t("settings.peakMixHint"), checked: transitionMode === "peak", enabled: true },
    { key: "crossfade", kind: "choice", section: "", label: strings.t("settings.crossfade"),
      hint: strings.t("settings.crossfadeHint"), choices: crossfadeChoices, value: crossfade, enabled: transitionMode === "peak" },
    { key: "autoplay", kind: "toggle", section: "", label: strings.t("settings.autoplay"),
      hint: strings.t("settings.autoplayHint"), checked: autoplayEnabled, enabled: true },
    { key: "playbackCookies", kind: "toggle", section: strings.t("settings.account"), label: strings.t("settings.playbackCookies"),
      hint: strings.t("settings.playbackCookiesHint"), checked: playbackCookies, enabled: browser !== "none" },
    { key: "backupMirrors", kind: "toggle", section: strings.t("settings.backup"), label: strings.t("settings.mirrors"),
      hint: strings.t("settings.mirrorsHint"), checked: setting("backupMirrors", "Off") === "On", enabled: true },
    { key: "updateCheck", kind: "toggle", section: "", label: strings.t("settings.updates"),
      hint: strings.t("settings.updatesHint"), checked: updateCheckOn, enabled: true },
    { key: "aiMix", kind: "toggle", section: strings.t("settings.ai"), label: strings.t("ai.setting"),
      hint: strings.t("ai.settingHint"), checked: aiEnabled, enabled: true },
    { key: "showCovers", kind: "toggle", section: strings.t("settings.display"), label: strings.t("settings.covers"),
      hint: strings.t("settings.coversHint"), checked: showCovers, enabled: true },
    { key: "showTitle", kind: "toggle", section: "", label: strings.t("settings.barTitle"),
      hint: strings.t("settings.barTitleHint"), checked: showTitle, enabled: true }
  ]

  function choiceLabel(seconds) {
    return seconds > 0 ? strings.t("settings.seconds").arg(Commons.I18n.formatNumber(seconds)) : strings.t("settings.off")
  }

  function setToggle(key, on) {
    var changes = {}
    changes[key] = key === "transition" ? (on ? "Peak mix" : "Off") : (on ? "On" : "Off")
    saveSettings(changes)
  }

  function setChoice(key, seconds) {
    var changes = {}
    // The pause fade is kept in milliseconds (the settings schema has whole numbers).
    changes[key] = key === "pauseFade" ? Math.round(Number(seconds) * 1000) : Number(seconds)
    saveSettings(changes)
  }

  // Enter on a row: flip a toggle, or step a choice forward (wrapping).
  function activateSetting(index, delta) {
    var item = settingsItems[index]
    if (!item || !item.enabled) return
    if (item.kind === "toggle") { if (delta === 0) setToggle(item.key, !item.checked); return }
    var next = Model.stepChoice(item.choices, item.value, delta === 0 ? 1 : delta)
    if (delta === 0 && next === item.value) next = item.choices[0]
    setChoice(item.key, next)
  }

  function openSettings() {
    if (view !== "settings") viewBeforeSettings = view === "addTo" ? "playlists" : view
    if (view === "addTo") closeAddTo()
    view = "settings"
    cursorIndex = -1
    if (!opened) open()
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
    tracksFromExplore = false
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
    if (view === "explore" && cursorIndex >= 0 && cursorIndex < rows.length && rows[cursorIndex].kind === "song") return rows[cursorIndex]
    return currentTrack
  }

  function showNotice(text, auth, long) {
    notice = text
    noticeAuth = auth === true
    noticeLong = long === true
    noticeRetryId = ""
    noticeFolder = ""
    noticeTimer.restart()
  }

  // Opens YouTube's sign-in page in the browser the cookies come from.
  function signIn() {
    openServicePage("yt")
  }
  // A service's sign-in page, or your own page there ("sc-profile" …), in
  // that same browser.
  function openServicePage(page) {
    if (signinProc.running) return
    signinProc.command = helper(["signin", "--browser", browser, "--service", page])
    signinProc.running = true
  }
  // "Paste link": the profile link you copied, from the clipboard, so
  // nothing has to be typed.
  function pasteSetup(target) {
    if (pasteProc.running) return
    pasteProc.target = target
    pasteProc.running = true
  }
  Process {
    id: pasteProc
    property string target: ""
    command: ["wl-paste", "--no-newline", "--type", "text/plain"]
    stdout: StdioCollector { onStreamFinished: root.usePasted(pasteProc.target, text) }
  }
  function usePasted(target, text) {
    var link = String(text || "").trim().split("\n")[0].slice(0, 300)
    var ok = target === "sc" ? /soundcloud\.com\/[A-Za-z0-9_-]+/.test(link)
      : target === "dz" ? /deezer\.(com|page\.link)\/|^[0-9]{3,15}$/.test(link) : false
    if (ok) saveSetup(target, link)
    else showNotice(strings.t("setup.pasteNothing").arg(strings.t("tab." + target)))
  }

  function playlistTitleById(id) {
    for (var i = 0; i < playlists.length; i++) if (playlists[i].id === id) return playlistTitle(playlists[i])
    return id
  }

  function isLiked(id) { return !!(id && (Model.isRadio(id) ? radioFavs[id] : likedIds[id])) }
  // Can be liked: a YouTube song, or a station (a favorite).
  function canLike(id) { return Model.isYouTube(id) || Model.isRadio(id) }

  // Favorite stations, as a lookup.
  property var radioFavs: ({})

  // The Radio tab's country: chosen from a list (the "countries" view),
  // typed into the search field to narrow it.
  property var radioCountries: []
  property string radioCountry: ""
  property string countryFilter: ""
  readonly property var radioCountryEntry: ({ kind: "explore", id: "__rdcountry", title: strings.t("rd.chooseCountry"),
    artist: radioCountryName !== "" ? strings.t("rd.countryNow").arg(radioCountryName) : strings.t("rd.countryHint") })
  readonly property string radioCountryName: {
    for (var i = 0; i < radioCountries.length; i++) if (radioCountries[i].id === radioCountry) return radioCountries[i].title
    return radioCountry
  }
  readonly property var countryRows: {
    var q = countryFilter.trim().toLowerCase()
    return q === "" ? radioCountries : radioCountries.filter(function(c) {
      return c.title.toLowerCase().indexOf(q) >= 0 || c.id.toLowerCase() === q
    })
  }
  Process {
    id: countriesProc
    command: root.helper(["radio-countries"])
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "countries") } }
  }
  function openCountries() {
    countryFilter = ""
    setSearchText("")
    view = "countries"
    cursorIndex = -1
    if (!countriesProc.running) countriesProc.running = true
    if (!opened) open()
  }
  function chooseCountry(row) {
    if (!row) return
    saveSettings({ radioCountry: row.id })
    radioCountry = row.id
    countryFilter = ""
    setSearchText("")
    view = "playlists"
    loadService("rd", true)
    openList({ id: "rd:country:" + row.id, title: strings.t("rd.stationsIn").arg(row.title), count: null })
  }
  Process {
    id: radioFavProc
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "radioFav") } }
  }

  // ---- podcasts --------------------------------------------------------------------
  // Subscribed shows ({ "pc:<show>": true }); their new episodes are a list.
  property var podcastSubs: ({})
  readonly property bool podcastOpen: view === "tracks" && openPlaylist !== null && Model.isPodcastShow(openPlaylist.id)
  function toggleSubscribe(id) {
    if (!Model.isPodcastShow(id) || podcastSubProc.running) return
    var on = !podcastSubs[id]
    var next = Object.assign({}, podcastSubs)
    if (on) next[id] = true
    else delete next[id]
    podcastSubs = next
    podcastSubProc.command = helper(["podcast-sub", id].concat(on ? [] : ["--remove", "1"]))
    podcastSubProc.running = true
    showNotice(strings.t(on ? "pc.subscribed" : "pc.unsubscribed"))
  }
  Process {
    id: podcastSubProc
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line, "podcastSub") } }
  }

  // The heart, like YouTube Music's: likes the song (it goes to Liked Music)
  // or removes the like. Shown at once, rolled back if YouTube refuses.
  function toggleLike(track) {
    if (track && Model.isRadio(track.id)) {
      if (radioFavProc.running) return
      var fav = !isLiked(track.id)
      var next = Object.assign({}, radioFavs)
      if (fav) next[track.id] = true
      else delete next[track.id]
      radioFavs = next
      radioFavProc.command = helper(["radio-fav", track.id].concat(fav ? [] : ["--remove", "1"]))
      radioFavProc.running = true
      showNotice(strings.t(fav ? "rd.faved" : "rd.unfaved"))
      return
    }
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
    if (!track || !Model.TRACK_KEY_RE.test(String(track.id))) return
    if (svc.my.items.length === 0) loadService("my", false)
    if (!Model.isYouTube(track.id)) {
      addTrack = track
      if (view !== "addTo") viewBeforeAdd = view
      view = "addTo"
      cursorIndex = -1
      addTargetsLive = null
      addTargetsLoading = false
      return
    }
    if (playlists.length === 0) loadYouTube(false)
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
    if (playlist && playlist.kind === "mixTarget") { addToMix(playlist); return }
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

  function togglePause() {
    if (pauseFadeSupported) send(["script-message", "ytmusic-toggle-pause"])
    else send(["cycle", "pause"])
  }
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
    var p = rows[index]
    if (!p) return
    openList(p)
  }

  // Opens a list (or one of the special entries) wherever it came from: the
  // panel's rows or the full-screen view.
  function openList(p) {
    if (!p) return
    if (p.kind === "explore") {
      if (p.id === "__scsearch") openSoundCloudSearch()
      else if (p.id === "__cloudadd") openCloudForm()
      else if (p.id === "__rdcountry") openCountries()
      else if (p.id === "__aimake") openAiMaker()
      else openExplore()
      return
    }
    tracksFromExplore = false
    openPlaylist = p
    tracks = []
    cursorIndex = -1
    view = "tracks"
    loadTracks(false)
  }

  function backToPlaylists() {
    if (view === "playlists" && cloudFormOpen && svc.cl.setup === "") { cloudFormOpen = false; return }
    if (view === "download") { view = viewBeforeDownload; cursorIndex = -1; return }
    if (view === "explore") {
      if (exploreMode === "search" && searchReturnView !== "") {
        view = searchReturnView
        searchReturnView = ""
        cursorIndex = -1
        return
      }
      if (exploreMode !== "home" && exploreService === "yt") showExploreHome()
      else { view = "playlists"; cursorIndex = 0 }
      return
    }
    if (view === "tracks" && tracksFromExplore) { view = "explore"; cursorIndex = -1; return }
    if (view === "countries") { view = "playlists"; countryFilter = ""; cursorIndex = -1; return }
    if (view === "ai") { view = "playlists"; cursorIndex = -1; return }
    if (view === "settings" || view === "services") {
      view = viewBeforeSettings === "tracks" && openPlaylist ? "tracks" : "playlists"
      cursorIndex = -1
      return
    }
    if (view === "addTo") { closeAddTo(); return }
    if (view !== "tracks") return
    view = "playlists"
    var id = openPlaylist ? openPlaylist.id : ""
    cursorIndex = -1
    for (var i = 0; i < rows.length; i++) if (rows[i].id === id) { cursorIndex = i; break }
  }

  function refreshList() {
    if (view === "settings" || view === "download") return
    if (view === "explore") {
      if (exploreMode === "search") runSearch(searchInput ? searchInput.text : "")
      else if (exploreMode === "home") loadExplore(0)
      return
    }
    if (view === "playlists" && service !== "yt") { loadService(service, true); return }
    if (view === "tracks") loadTracks(true)
    else loadPlaylists(true)
  }

  function activateRow(index) {
    if (view === "countries") { chooseCountry(rows[index]); return }
    if (view === "explore") { activateExplore(rows[index]); return }
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
    if (view === "settings") {
      if (dy !== 0) cursorIndex = Model.clampIndex(cursorIndex, dy, settingsItems.length)
      else if (cursorIndex >= 0 && settingsItems[cursorIndex].kind === "choice") activateSetting(cursorIndex, dx)
      else if (dx < 0) backToPlaylists()
      return
    }
    if (dy !== 0) cursorIndex = Model.clampIndex(cursorIndex, dy, rows.length)
    else if (dx < 0) backToPlaylists()
    else if (dx > 0 && view === "playlists" && cursorIndex >= 0) openPlaylistAt(cursorIndex)
  }

  function activateCursor() {
    if (view === "settings") { if (cursorIndex >= 0) activateSetting(cursorIndex, 0); return }
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
    case ",": openSettings(); break
    case "d": openDownload(cursorOrCurrentTrack()); break
    case "e": openExplore(); break
    case "F": openFull(); break
    case "/": focusSearch(); break
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
    function openSettings(): void { root.openSettings() }
    function explore(): void { root.open(); root.openExplore() }
    function tab(name: string): void { root.open(); root.switchService(name) }
    function download(): void { root.openDownload(root.currentTrack) }
    function fullscreen(): void { root.fullOpen ? root.closeFull() : root.openFull() }
    // The player window on one page: home, browse, nowplaying, lyrics, notes, or a service
    // (yt, sp, sc, cl, my) — handy for a keybinding.
    function full(page: string): void {
      if (!root.fullOpen) root.openFull()
      if (Model.SERVICES.indexOf(page) >= 0) fullView.showService(page)
      else if (page === "browse") fullView.showBrowse()
      else if (page === "lyrics") fullView.showLyrics()
      else if (page === "notes") fullView.showNotes()
      else if (page === "home" || page === "nowplaying") fullView.go(page)
    }
    function cloud(): void { root.fullOpen ? fullView.addStorage() : root.openCloudForm() }
    function aiMix(): void { root.openAiMaker() }
  }

  onOpenedChanged: {
    if (!opened) return
    cursorIndex = -1
    // The keys go to the panel's shortcuts, not the search field, until
    // the field is clicked or "/" is pressed.
    Qt.callLater(function() { if (searchInput && searchInput.activeFocus) searchInput.focus = false; if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
    if (playlists.length === 0 || !playlistsLoading) loadYouTube(false)
    if (service !== "yt") loadService(service, false)
    if (svc.my.items.length === 0) loadService("my", false)
    if (!likedProc.running) likedProc.running = true
    if (connected) requestPosition()
    else attach()
  }

  Component.onCompleted: {
    radioFavProc.command = helper(["radio-favs"])
    radioFavProc.running = true
    podcastSubProc.command = helper(["podcast-sub"])
    podcastSubProc.running = true
    scrobbleProc.command = helper(["scrobble"])
    scrobbleProc.running = true
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
    text: root.mirrorOffer !== null && !root.opened ? Model.GLYPH.alert
      : root.loading ? Model.GLYPH.loading : (root.connected && root.paused ? Model.GLYPH.pause : Model.GLYPH.music)
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
    contentWidth: panel.fittedContentWidth(Style.space(527))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      // The panel's functions live outside this content and can't see its
      // ids: hand them the fields they work with.
      Component.onCompleted: {
        root.searchInput = searchField
        root.cloudPathInput = cloudPathField
        root.cloudTitleInput = cloudTitleField
      }
      // Typing in the search field goes to the field, not to shortcuts.
      blocked: searchField.activeFocus || setupField.activeFocus || root.cloudTyping
      implicitHeight: Math.max(column.implicitHeight, rail.implicitHeight + railEnd.implicitHeight + Style.space(24))
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text, modifiers) { root.handleKey(text) }

      // ---------- services, down the left side ----------
      // Each service's logo in its color (its name in a tooltip and in the
      // header), "+" to pick them; the player window and settings at the foot.
      Column {
        id: rail
        anchors.left: parent.left
        anchors.top: parent.top
        width: Style.space(38)
        spacing: Style.space(6)

        Repeater {
          model: root.shownTabs
          ServiceTab {
            required property var modelData
            glyph: modelData.glyph
            brand: modelData.color
            label: modelData.label
            selected: root.service === modelData.id && root.view !== "services"
            onClicked: root.switchService(modelData.id)
          }
        }
        ServiceTab {
          glyph: Model.GLYPH.plus
          brand: root.fg
          label: strings.t("services.title")
          selected: root.view === "services"
          onClicked: root.view === "services" ? root.backToPlaylists() : root.openServices()
        }
      }
      Column {
        id: railEnd
        anchors.horizontalCenter: rail.horizontalCenter
        anchors.bottom: parent.bottom
        spacing: Style.space(4)
        PanelActionButton {
          anchors.horizontalCenter: parent.horizontalCenter
          iconText: Model.GLYPH.fullscreen
          fontSize: Style.font.title
          tooltipText: strings.t("full.open")
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.openFull()
        }
        PanelActionButton {
          anchors.horizontalCenter: parent.horizontalCenter
          iconText: Model.GLYPH.settings
          fontSize: Style.font.title
          tooltipText: strings.t("settings.open")
          foreground: root.view === "settings" ? Style.selectedStateColor(root.fg, Commons.Color.accent) : root.fg
          fontFamily: root.fontFamily
          onClicked: root.view === "settings" ? root.backToPlaylists() : root.openSettings()
        }
      }
      Rectangle {
        id: railLine
        anchors.left: rail.right
        anchors.leftMargin: Style.space(8)
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
      }

      Column {
        id: column
        anchors.left: railLine.right
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- search, across the panel under the tabs ----------
        // YouTube Music's songs (SoundCloud's on its tab); Enter shows them.
        BorderSurface {
          width: parent.width
          implicitHeight: Style.space(40)
          radius: Style.cornerRadius
          color: Style.controlFill(searchField.activeFocus, searchMouse.containsMouse, root.fg, Commons.Color.accent)
          borderSpec: Border.controlSpec(searchField.activeFocus ? "focus" : "normal", root.fg, Commons.Color.accent)

          MouseArea {
            id: searchMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.IBeamCursor
            onClicked: searchField.forceActiveFocus()
          }
          PlainText {
            id: searchIcon
            anchors.left: parent.left
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            text: Model.GLYPH.search
            color: root.dim
            font.pixelSize: Style.font.subtitle
            elide: Text.ElideNone
          }
          TextInput {
            id: searchField
            onTextEdited: if (root.view === "countries") root.countryFilter = text
            anchors.left: searchIcon.right
            anchors.leftMargin: Style.space(10)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            clip: true
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            selectByMouse: true
            // Enter is taken here: TextInput passes it on after `accepted`,
            // and the panel would take it as "play the highlighted song".
            Keys.onReturnPressed: function(event) { root.searchFromBar(text); focus = false; event.accepted = true }
            Keys.onEnterPressed: function(event) { root.searchFromBar(text); focus = false; event.accepted = true }
            Keys.onEscapePressed: function(event) {
              if (text !== "") text = ""
              else focus = false
              event.accepted = true
            }
            Keys.onDownPressed: function(event) {
              focus = false
              root.cursorIndex = 0
              event.accepted = true
            }
          }
          PlainText {
            anchors.fill: searchField
            verticalAlignment: Text.AlignVCenter
            visible: searchField.text === "" && !searchField.preeditText
            readonly property string where: root.view === "explore" ? root.exploreService : root.service
            text: root.view === "countries" ? strings.t("rd.countryField")
              : where === "sc" ? strings.t("sc.searchField") : where === "rd" ? strings.t("rd.searchField")
              : ["pc", "dz", "mc", "au"].indexOf(where) >= 0 ? strings.t(where + ".searchField") : strings.t("explore.search")
            color: root.dim
            font.pixelSize: Style.font.subtitle
          }
        }

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

          // Like, add and download for the playing song, beside its title.
          Row {
            id: nowActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)
            visible: root.connected && root.currentTrack !== null

            PanelActionButton {
              visible: root.currentTrack !== null && root.canLike(root.currentTrack.id)
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
            PanelActionButton {
              visible: root.currentTrack !== null && Model.canDownload(root.currentTrack.id)
              iconText: Model.GLYPH.download
              tooltipText: strings.t("controls.download")
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.openDownload(root.currentTrack)
            }
          }

          Column {
            id: nowLabels
            anchors.left: nowIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: nowActions.visible ? nowActions.left : parent.right
            anchors.rightMargin: Style.space(6)
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

        // ---------- music isn't playing: report it in one click ----------
        BorderSurface {
          visible: root.troubleText !== "" && !root.starting
          width: parent.width
          implicitHeight: troubleColumn.implicitHeight + Style.space(24)
          radius: Style.cornerRadius
          color: Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.10)
          borderSpec: Border.flat(Commons.Color.accent, 1)

          Column {
            id: troubleColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(12)
            spacing: Style.space(8)

            PlainText {
              width: parent.width
              text: Model.GLYPH.alert + "  " + strings.t("report.troubleTitle")
              font.pixelSize: Style.font.title
              font.bold: true
            }
            PlainText {
              width: parent.width
              text: root.troubleText
              color: root.dim
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
              elide: Text.ElideNone
            }
            PlainText {
              width: parent.width
              text: strings.t("report.troubleBody")
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
              elide: Text.ElideNone
            }
            PlainText {
              width: parent.width
              visible: root.youtubeFailing
              text: strings.t("report.updateHint")
              color: root.dim
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
              elide: Text.ElideNone
            }
            ReportButton { where: "playback"; message: root.troubleText }
          }
        }

        // ---------- a newer version of the plugin ----------
        BorderSurface {
          visible: root.updateInfo !== null
          width: parent.width
          implicitHeight: updateColumn.implicitHeight + Style.space(24)
          radius: Style.cornerRadius
          color: Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.08)
          borderSpec: Border.flat(Commons.Color.accent, 1)

          Column {
            id: updateColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(12)
            spacing: Style.space(6)

            PlainText {
              width: parent.width
              text: root.updateInfo ? strings.t(root.youtubeFailing ? "update.titleFix" : "update.title").arg(root.updateInfo.version) : ""
              font.bold: true
              wrapMode: Text.Wrap
              elide: Text.ElideNone
            }
            Repeater {
              model: root.updateInfo ? root.updateInfo.notes : []
              PlainText {
                required property var modelData
                width: updateColumn.width
                text: "• " + modelData
                color: root.dim
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
                elide: Text.ElideNone
              }
            }
            Row {
              spacing: Style.space(8)
              Button {
                iconText: updateApplyProc.running ? Model.GLYPH.loading : Model.GLYPH.refresh
                iconSpinning: updateApplyProc.running
                text: updateApplyProc.running ? strings.t("update.running") : strings.t("update.now")
                enabled: !updateApplyProc.running
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.applyUpdate()
              }
              Button {
                visible: !updateApplyProc.running
                text: strings.t("update.later")
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.declineUpdate()
              }
            }
          }
        }

        // ---------- a song won't play: offer backup mirrors ----------
        BorderSurface {
          visible: root.mirrorOffer !== null
          width: parent.width
          implicitHeight: offerColumn.implicitHeight + Style.space(24)
          radius: Style.cornerRadius
          color: Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.10)
          borderSpec: Border.flat(Commons.Color.accent, 1)

          Column {
            id: offerColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(12)
            spacing: Style.space(8)

            Row {
              width: parent.width
              spacing: Style.space(8)
              PlainText {
                id: offerIcon
                text: Model.GLYPH.alert
                color: Commons.Color.accent
                font.pixelSize: Style.font.title
                elide: Text.ElideNone
              }
              PlainText {
                width: parent.width - offerIcon.width - parent.spacing
                anchors.verticalCenter: offerIcon.verticalCenter
                text: root.mirrorOffer ? strings.t("offer.title").arg(root.mirrorOffer.title) : ""
                font.bold: true
                wrapMode: Text.Wrap
                elide: Text.ElideNone
              }
            }
            PlainText {
              width: parent.width
              visible: text !== ""
              text: root.mirrorOffer ? root.mirrorOffer.reason : ""
              color: root.dim
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
              elide: Text.ElideNone
            }
            PlainText {
              width: parent.width
              text: strings.t("offer.body")
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
              elide: Text.ElideNone
            }
            Row {
              spacing: Style.space(8)
              Button {
                iconText: Model.GLYPH.refresh
                text: strings.t("offer.enable")
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.acceptMirrorOffer()
              }
              Button {
                text: strings.t("offer.dismiss")
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.declineMirrorOffer()
              }
            }
          }
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
            readonly property bool folder: root.noticeFolder !== ""
            visible: folder || (root.browser !== "none" && (root.noticeAuth || retry))
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: folder ? Model.GLYPH.folder : retry ? Model.GLYPH.play : Model.GLYPH.login
            text: folder ? strings.t("download.openFolder") : retry ? strings.t("controls.useAccount") : strings.t("controls.signIn")
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            onClicked: {
              if (folder) { openFolderProc.command = ["xdg-open", root.noticeFolder]; openFolderProc.running = true }
              else if (retry) root.playWithAccount(root.noticeRetryId)
              else root.signIn()
            }
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
              visible: root.view !== "playlists"
              anchors.verticalCenter: parent.verticalCenter
              iconText: LayoutMirroring.enabled ? Model.GLYPH.forward : Model.GLYPH.back
              fontSize: Style.font.title
              tooltipText: strings.t("list.back")
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.backToPlaylists()
            }
            PanelSectionHeader {
              anchors.verticalCenter: parent.verticalCenter
              fontSize: Style.font.title
              font.bold: true
              width: Math.min(implicitWidth, headerLeft.width - (root.view !== "playlists" ? Style.space(48) : 0))
              elide: Text.ElideRight
              text: root.view === "settings" ? strings.t("settings.title")
                : root.view === "services" ? strings.t("services.title")
                : root.view === "countries" ? strings.t("rd.countries")
                : root.view === "ai" ? strings.t("ai.title")
                : root.view === "explore" ? root.exploreTitle
                : root.view === "download" && root.downloadTrack ? strings.t("download.title").arg(root.downloadTrack.title)
                : root.view === "tracks" ? root.playlistTitle(root.openPlaylist)
                : (root.view === "addTo" && root.addTrack ? strings.t("list.addTo").arg(root.addTrack.title)
                  : root.service === "yt" ? strings.t("list.playlists") : strings.t("tab." + root.service))
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
              visible: root.podcastOpen
              iconText: root.podcastOpen && root.podcastSubs[root.openPlaylist.id] ? Model.GLYPH.check : Model.GLYPH.plus
              text: strings.t(root.podcastOpen && root.podcastSubs[root.openPlaylist.id] ? "pc.subscribedButton" : "pc.subscribe")
              fontSize: Style.font.body
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.toggleSubscribe(root.openPlaylist.id)
            }
            Button {
              visible: root.view === "tracks" && root.tracks.length > 0 && !root.podcastOpen
              iconText: Model.GLYPH.play
              text: strings.t("list.playAll")
              fontSize: Style.font.body
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.play(0, false)
            }
            Button {
              visible: root.view === "tracks" && root.tracks.length > 1 && !root.podcastOpen
              iconText: Model.GLYPH.shuffle
              text: strings.t("list.shuffle")
              fontSize: Style.font.body
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.handleKey("s")
            }
            Button {
              visible: root.view !== "settings" && root.view !== "download" && root.view !== "services" && root.view !== "ai" && !(root.view === "explore" && root.exploreMode === "mood")
              iconText: Model.GLYPH.refresh
              iconSpinning: root.view === "tracks" ? root.tracksLoading : root.view === "explore" ? root.exploreLoading : root.playlistsLoading
              fontSize: Style.font.title
              tooltipText: strings.t("list.refresh")
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.refreshList()
            }
          }
        }

        // ---------- download a song ----------
        Column {
          visible: root.view === "download" && root.downloadTrack !== null
          width: parent.width
          spacing: Style.space(10)

          PlainText {
            text: strings.t("download.format").toUpperCase()
            color: root.dim
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            font.letterSpacing: 1.1
          }
          ButtonGroup {
            focusable: false
            foreground: root.fg
            accent: Commons.Color.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.body
            options: Model.DOWNLOAD_FORMATS.map(function(f) { return { value: f, label: f.toUpperCase() } })
            value: root.downloadFormat
            onChanged: function(v) { root.saveSettings({ downloadFormat: v }) }
          }
          PlainText {
            text: strings.t("download.folder").toUpperCase()
            color: root.dim
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            font.letterSpacing: 1.1
          }
          BorderSurface {
            width: parent.width
            implicitHeight: Math.max(folderText.implicitHeight, chooseButton.implicitHeight) + Style.space(16)
            radius: Style.cornerRadius
            color: Style.controlFill(false, false, root.fg, Commons.Color.accent)
            borderSpec: Border.controlSpec("normal", root.fg, Commons.Color.accent)
            PlainText {
              id: folderText
              anchors.left: parent.left
              anchors.leftMargin: Style.space(12)
              anchors.right: chooseButton.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: Model.GLYPH.folder + "  " + root.downloadPath
              elide: Text.ElideMiddle
            }
            Button {
              id: chooseButton
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: strings.t("download.choose")
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.chooseFolder()
            }
          }
          Toggle {
            width: parent.width
            label: strings.t("download.cover")
            description: strings.t("download.coverHint")
            checked: root.downloadCover
            foreground: root.fg
            accent: Commons.Color.accent
            fontFamily: root.fontFamily
            onClicked: root.saveSettings({ downloadCover: root.downloadCover ? "Off" : "On" })
          }
          Row {
            spacing: Style.space(8)
            Button {
              iconText: Model.GLYPH.download
              text: strings.t("download.start")
              enabled: !downloadProc.running
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.startDownload()
            }
            Button {
              text: strings.t("download.cancel")
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.backToPlaylists()
            }
          }
        }

        // A download in progress, wherever the panel is.
        Row {
          visible: root.downloading !== null
          spacing: Style.space(8)
          Spinner { anchors.verticalCenter: parent.verticalCenter }
          PlainText {
            anchors.verticalCenter: parent.verticalCenter
            color: root.dim
            font.pixelSize: Style.font.bodySmall
            text: !root.downloading ? ""
              : root.downloading.stage === "convert"
                ? strings.t("download.converting").arg(Model.truncate(root.downloading.title, 40)).arg(root.downloadFormat.toUpperCase())
                : strings.t("download.fetching").arg(Model.truncate(root.downloading.title, 40))
          }
        }

        // ---------- connect Spotify / SoundCloud ----------
        BorderSurface {
          id: setupCard
          readonly property string target: root.view === "playlists" && (root.service === "sp" || root.service === "sc" || root.service === "dz")
            ? root.svc[root.service].setup : ""
          // Spotify with a Client ID but no login only needs the Connect button.
          readonly property bool needsField: target === "sc" || target === "dz" || (target === "sp" && root.spClientId === "")
          visible: target !== ""
          width: parent.width
          implicitHeight: setupColumn.implicitHeight + Style.space(24)
          radius: Style.cornerRadius
          color: Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.08)
          borderSpec: Border.flat(Commons.Color.accent, 1)

          Column {
            id: setupColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(12)
            spacing: Style.space(10)

            PlainText {
              width: parent.width
              text: strings.t(setupCard.target + ".setupTitle")
              font.pixelSize: Style.font.title
              font.bold: true
            }
            PlainText {
              width: parent.width
              text: setupCard.target === "sp"
                ? (setupCard.needsField ? strings.t("sp.setupBody") : strings.t("sp.connectBody"))
                : setupCard.target === "dz" ? strings.t("dz.setupBody") : strings.t("sc.setupBody").arg(root.browser)
              color: root.dim
              wrapMode: Text.Wrap
              elide: Text.ElideNone
            }
            BorderSurface {
              visible: setupCard.needsField
              width: parent.width
              implicitHeight: Style.space(38)
              radius: Style.cornerRadius
              color: Style.controlFill(setupField.activeFocus, false, root.fg, Commons.Color.accent)
              borderSpec: Border.controlSpec(setupField.activeFocus ? "focus" : "normal", root.fg, Commons.Color.accent)
              TextInput {
                id: setupField
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                clip: true
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                selectByMouse: true
                Keys.onReturnPressed: function(event) { root.saveSetup(setupCard.target, text); text = ""; focus = false; event.accepted = true }
                Keys.onEnterPressed: function(event) { root.saveSetup(setupCard.target, text); text = ""; focus = false; event.accepted = true }
                Keys.onEscapePressed: function(event) { focus = false; event.accepted = true }
              }
              PlainText {
                anchors.fill: setupField
                verticalAlignment: Text.AlignVCenter
                visible: setupField.text === ""
                text: strings.t(setupCard.target + ".setupField")
                color: root.dim
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.IBeamCursor
                onClicked: setupField.forceActiveFocus()
              }
            }
            Row {
              spacing: Style.space(8)
              Button {
                visible: setupCard.needsField
                text: strings.t("setup.save")
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: { root.saveSetup(setupCard.target, setupField.text); setupField.text = "" }
              }
            }
            // The lazy way: sign in, open your profile, copy its link, paste.
            // (Spotify's buttons follow in the same row.)
            Flow {
              readonly property bool profileLink: setupCard.target === "sc" || setupCard.target === "dz"
              width: parent.width
              spacing: Style.space(8)
              Button {
                visible: parent.profileLink
                iconText: Model.GLYPH.forward
                text: strings.t("setup.signin").arg(strings.t("tab." + setupCard.target))
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.openServicePage(setupCard.target)
              }
              Button {
                visible: parent.profileLink
                iconText: Model.GLYPH.artist
                text: strings.t("setup.myProfile")
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.openServicePage(setupCard.target + "-profile")
              }
              Button {
                visible: parent.profileLink
                iconText: Model.GLYPH.check
                text: strings.t("setup.paste")
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.pasteSetup(setupCard.target)
              }
              Button {
                visible: setupCard.target === "sp" && setupCard.needsField
                iconText: Model.GLYPH.forward
                text: strings.t("sp.dashboard")
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: { openUrlProc.command = ["xdg-open", "https://developer.spotify.com/dashboard"]; openUrlProc.running = true }
              }
              Button {
                visible: setupCard.target === "sp" && !setupCard.needsField
                iconText: root.spotifyWaiting ? Model.GLYPH.loading : Model.GLYPH.spotify
                iconSpinning: root.spotifyWaiting
                text: root.spotifyWaiting ? strings.t("sp.waiting") : strings.t("sp.connect")
                enabled: !root.spotifyWaiting
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.connectSpotify()
              }
            }
          }
        }

        // ---------- AI Mix: make one ----------
        Column {
          visible: root.view === "ai"
          width: parent.width
          spacing: Style.space(10)
          PlainText {
            width: parent.width
            text: strings.t("ai.body")
            color: root.dim
            wrapMode: Text.Wrap
            elide: Text.ElideNone
          }
          CloudField {
            id: aiWish
            width: parent.width
            label: strings.t("ai.wish")
            onSubmitted: root.makeAiMix(aiWish.text, false)
          }
          Button {
            iconText: root.aiState !== "" ? Model.GLYPH.loading : Model.GLYPH.ai
            iconSpinning: root.aiState !== ""
            text: root.aiState === "asking" ? strings.t("ai.asking").arg(root.aiAgent || strings.t("ai.agent"))
              : root.aiState === "finding" ? strings.t("ai.finding")
              : root.aiEnabled ? strings.t("ai.go") : strings.t("ai.goFirst")
            enabled: root.aiState === ""
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.makeAiMix(aiWish.text, false)
          }
          PlainText {
            visible: root.aiError !== ""
            width: parent.width
            text: root.aiError
            color: Commons.Color.urgent
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            elide: Text.ElideNone
          }
          PlainText {
            width: parent.width
            text: strings.t("ai.privacy")
            color: root.dim
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
            elide: Text.ElideNone
          }
        }

        // ---------- which services have a tab ----------
        Column {
          visible: root.view === "services"
          width: parent.width
          spacing: Style.space(6)
          PlainText {
            width: parent.width
            text: strings.t("services.hint")
            color: root.dim
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            elide: Text.ElideNone
          }
          Repeater {
            model: root.serviceTabs.filter(function(t) { return t.id !== "yt" && t.id !== "my" })
            Toggle {
              required property var modelData
              width: parent.width
              label: modelData.glyph + "  " + modelData.label
              description: strings.t("services.about." + modelData.id)
              checked: root.shownTabs.some(function(t) { return t.id === modelData.id })
              foreground: root.fg
              accent: Commons.Color.accent
              fontFamily: root.fontFamily
              onClicked: root.setTabShown(modelData.id, !checked)
            }
          }
          PlainText {
            width: parent.width
            topPadding: Style.space(4)
            text: strings.t("services.soon")
            color: root.dim
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
            elide: Text.ElideNone
          }
        }

        // ---------- connect cloud storage ----------
        BorderSurface {
          id: cloudCard
          visible: root.cloudFormShown
          width: parent.width
          implicitHeight: cloudColumn.implicitHeight + Style.space(24)
          radius: Style.cornerRadius
          color: Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.08)
          borderSpec: Border.flat(Commons.Color.accent, 1)

          Column {
            id: cloudColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(12)
            spacing: Style.space(10)

            PlainText {
              width: parent.width
              text: Model.GLYPH.cloud + "  " + strings.t("cloud.title")
              font.pixelSize: Style.font.title
              font.bold: true
            }
            PlainText {
              width: parent.width
              text: root.cloudFormUsable ? strings.t("cloud.body") : strings.t("cloud.noRclone")
              color: root.dim
              wrapMode: Text.Wrap
              elide: Text.ElideNone
            }
            Button {
              visible: root.cloudMusicDir !== "" && root.cloudBusy === ""
              iconText: Model.GLYPH.folderMusic
              text: strings.t("cloud.addMusic").arg(root.cloudMusicDir.replace(root.homeDir, "~"))
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.addMusicFolder()
            }
            Button {
              visible: !root.cloudFormUsable
              iconText: Model.GLYPH.download
              text: strings.t("cloud.installRclone")
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.installRclone()
            }

            Flow {
              visible: true
              width: parent.width
              spacing: Style.space(6)
              Repeater {
                model: Model.CLOUD_KINDS
                Button {
                  required property var modelData
                  text: modelData.label
                  selected: root.cloudKind === modelData.id
                  bordered: true
                  fontSize: Style.font.bodySmall
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  enabled: root.cloudBusy === ""
                  onClicked: { root.cloudKind = modelData.id; root.cloudKindTouched = true; root.cloudError = "" }
                }
              }
            }
            PlainText {
              visible: root.cloudFormUsable
              width: parent.width
              text: strings.t("cloud.hint." + root.cloudKind)
              color: root.dim
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
              elide: Text.ElideNone
            }

            // A remote rclone already has (`rclone config`).
            Flow {
              visible: root.cloudFormUsable && root.cloudKind === "remote" && root.cloudRemotes.length > 0
              width: parent.width
              spacing: Style.space(6)
              Repeater {
                model: root.cloudRemotes
                Button {
                  required property var modelData
                  text: modelData.name + "  ·  " + modelData.type
                  selected: root.cloudRemote === modelData.name
                  bordered: true
                  fontSize: Style.font.bodySmall
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  onClicked: root.cloudRemote = modelData.name
                }
              }
            }
            PlainText {
              visible: root.cloudFormUsable && root.cloudKind === "remote" && root.cloudRemotes.length === 0
              width: parent.width
              text: strings.t("cloud.noRemotes")
              color: root.dim
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
              elide: Text.ElideNone
            }

            Repeater {
              model: root.cloudFormUsable && root.cloudFormEpoch >= 0 ? root.cloudKindSpec.fields.slice() : []
              CloudField {
                onSubmitted: root.connectCloud()
                required property var modelData
                width: cloudColumn.width
                label: strings.t("cloud.field." + modelData)
                secret: Model.SECRET_FIELDS.indexOf(modelData) >= 0
                onEdited: function(value) { root.setCloudValue(modelData, value) }
              }
            }
            CloudField {
              onSubmitted: root.connectCloud()
              id: cloudPathField
              visible: root.cloudFormUsable && root.cloudKindSpec.server !== true
              width: parent.width
              label: strings.t(root.cloudKind === "s3" ? "cloud.pathS3" : root.cloudKind === "smb" ? "cloud.pathSmb"
                : root.cloudKind === "local" ? "cloud.pathLocal" : "cloud.path")
            }
            CloudField {
              onSubmitted: root.connectCloud()
              id: cloudTitleField
              visible: root.cloudFormUsable
              width: parent.width
              label: strings.t("cloud.name")
            }

            Row {
              visible: root.cloudFormUsable
              spacing: Style.space(8)
              Button {
                iconText: root.cloudBusy !== "" ? Model.GLYPH.loading : Model.GLYPH.cloud
                iconSpinning: root.cloudBusy !== ""
                text: root.cloudBusy === "waiting" ? strings.t("cloud.waiting")
                  : root.cloudBusy === "checking" ? strings.t("cloud.checking")
                  : root.cloudKindSpec.oauth ? strings.t("cloud.signIn").arg(root.cloudKindSpec.label) : strings.t("cloud.connect")
                enabled: root.cloudBusy === ""
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.connectCloud()
              }
              Button {
                visible: root.svc.cl.setup === "" && root.cloudBusy === ""
                text: strings.t("download.cancel")
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.cloudFormOpen = false
              }
            }
            PlainText {
              visible: root.cloudError !== ""
              width: parent.width
              text: root.cloudError
              color: Commons.Color.urgent
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
              elide: Text.ElideNone
            }
            ReportButton {
              visible: root.cloudError !== ""
              where: strings.t("tab.cl")
              message: root.cloudError
            }
          }
        }

        // ---------- settings ----------
        Flickable {
          id: settingsView
          visible: root.view === "settings"
          width: parent.width
          height: Math.min(settingsColumn.implicitHeight, Style.space(420))
          contentHeight: settingsColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: settingsColumn
            width: settingsView.width
            spacing: Style.space(6)

            Repeater {
              model: root.settingsItems

              Column {
                id: settingRow
                required property var modelData
                required property int index
                width: settingsColumn.width
                spacing: Style.space(6)
                opacity: modelData.enabled ? 1 : 0.45

                function keepVisible() {
                  if (root.cursorIndex !== index) return
                  var top = settingRow.y, bottom = settingRow.y + settingRow.height
                  if (top < settingsView.contentY) settingsView.contentY = top
                  else if (bottom > settingsView.contentY + settingsView.height) settingsView.contentY = bottom - settingsView.height
                }
                Connections {
                  target: root
                  function onCursorIndexChanged() { if (root.view === "settings") Qt.callLater(settingRow.keepVisible) }
                }

                PlainText {
                  visible: settingRow.modelData.section !== ""
                  topPadding: settingRow.index > 0 ? Style.space(8) : 0
                  text: settingRow.modelData.section.toUpperCase()
                  color: root.dim
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  font.letterSpacing: 1.1
                }

                Toggle {
                  visible: settingRow.modelData.kind === "toggle"
                  width: parent.width
                  label: settingRow.modelData.label
                  description: settingRow.modelData.hint
                  checked: settingRow.modelData.checked === true
                  foreground: root.fg
                  accent: Commons.Color.accent
                  fontFamily: root.fontFamily
                  hasCursor: root.cursorIndex === settingRow.index
                  enabled: settingRow.modelData.enabled
                  onHovered: function(h) { if (h) root.cursorIndex = settingRow.index }
                  onClicked: root.activateSetting(settingRow.index, 0)
                }

                // A label with its choices as a row of chips.
                BorderSurface {
                  visible: settingRow.modelData.kind === "choice"
                  width: parent.width
                  implicitHeight: choiceColumn.implicitHeight + Style.spacing.rowPaddingX * 2
                  radius: Style.cornerRadius
                  readonly property bool hot: root.cursorIndex === settingRow.index || choiceHover.hovered
                  color: Style.controlFill(false, hot, root.fg, Commons.Color.accent)
                  borderSpec: Border.controlSpec(hot ? "hover-cursor" : "normal", root.fg, Commons.Color.accent)

                  HoverHandler {
                    id: choiceHover
                    onHoveredChanged: if (hovered) root.cursorIndex = settingRow.index
                  }

                  Column {
                    id: choiceColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: Style.spacing.rowPaddingX
                    spacing: Style.space(6)

                    PlainText {
                      width: parent.width
                      text: settingRow.modelData.label
                      font.pixelSize: Style.font.subtitle
                    }
                    PlainText {
                      width: parent.width
                      text: settingRow.modelData.hint
                      color: root.dim
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.Wrap
                      elide: Text.ElideNone
                    }
                    ButtonGroup {
                      enabled: settingRow.modelData.enabled
                      focusable: false
                      foreground: root.fg
                      accent: Commons.Color.accent
                      fontFamily: root.fontFamily
                      fontSize: Style.font.bodySmall
                      options: (settingRow.modelData.choices || []).map(function(s) {
                        return { value: String(s), label: root.choiceLabel(s) }
                      })
                      value: String(settingRow.modelData.value)
                      onChanged: function(v) { root.setChoice(settingRow.modelData.key, Number(v)) }
                    }
                  }
                }
              }
            }

            // Accounts: change the SoundCloud profile, disconnect Spotify.
            Row {
              spacing: Style.space(8)
              PlainText {
                anchors.verticalCenter: parent.verticalCenter
                text: Model.GLYPH.soundcloud + "  " + strings.t("accounts.sc").arg(root.scUserSetting || strings.t("accounts.none"))
              }
              Button {
                visible: root.scUserSetting !== ""
                text: strings.t("accounts.change")
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: {
                  root.saveSettings({ soundcloudUser: "" })
                  root.setSvc("sc", { items: [], setup: "sc" })
                  root.switchService("sc")
                }
              }
            }
            Row {
              visible: root.dzUserSetting !== ""
              spacing: Style.space(8)
              PlainText {
                anchors.verticalCenter: parent.verticalCenter
                text: Model.GLYPH.deezer + "  " + strings.t("accounts.dz").arg(root.dzUserSetting)
              }
              Button {
                text: strings.t("accounts.change")
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: {
                  root.saveSettings({ deezerUser: "" })
                  root.setSvc("dz", { items: [], setup: "dz" })
                  root.setTabShown("dz", true)
                  root.switchService("dz")
                }
              }
            }
            Row {
              spacing: Style.space(8)
              PlainText {
                anchors.verticalCenter: parent.verticalCenter
                text: Model.GLYPH.spotify + "  " + strings.t("accounts.sp").arg(
                  root.svc.sp.items.length > 0 ? strings.t("accounts.connected") : strings.t("accounts.none"))
              }
              Button {
                visible: root.svc.sp.items.length > 0 || root.spClientId !== ""
                text: strings.t("accounts.disconnect")
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: {
                  spotifyLogoutProc.running = true
                  root.saveSettings({ spotifyClientId: "" })
                  root.setSvc("sp", { items: [], setup: "sp" })
                }
              }
            }

            // Scrobbling: Last.fm and ListenBrainz, each connected or with its form.
            Repeater {
              model: [{ id: "lastfm", fields: ["key", "secret"], help: "https://www.last.fm/api/account/create" },
                      { id: "listenbrainz", fields: ["token"], help: "https://listenbrainz.org/settings/" }]
              Column {
                id: scrobbleRow
                required property var modelData
                readonly property string who: root.scrobbleState[modelData.id] || ""
                readonly property bool formOpen: root.scrobbleForm === modelData.id && who === ""
                property var values: ({})
                width: parent.width
                spacing: Style.space(6)
                Row {
                  spacing: Style.space(8)
                  PlainText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Model.GLYPH.history + "  " + strings.t("scrobble." + scrobbleRow.modelData.id)
                      .arg(scrobbleRow.who !== "" ? scrobbleRow.who : strings.t("accounts.none"))
                  }
                  Button {
                    text: strings.t(scrobbleRow.who !== "" ? "accounts.disconnect" : scrobbleRow.formOpen ? "scrobble.cancel" : "scrobble.connect")
                    fontSize: Style.font.bodySmall
                    foreground: root.fg
                    fontFamily: root.fontFamily
                    bordered: true
                    enabled: !scrobbleProc.running
                    onClicked: {
                      if (scrobbleRow.who !== "") root.disconnectScrobble(scrobbleRow.modelData.id)
                      else root.scrobbleForm = scrobbleRow.formOpen ? "" : scrobbleRow.modelData.id
                    }
                  }
                }
                PlainText {
                  visible: scrobbleRow.formOpen
                  width: parent.width
                  text: strings.t("scrobble." + scrobbleRow.modelData.id + "Help")
                  color: root.dim
                  wrapMode: Text.Wrap
                  elide: Text.ElideNone
                }
                Repeater {
                  model: scrobbleRow.formOpen ? scrobbleRow.modelData.fields : []
                  CloudField {
                    required property var modelData
                    width: scrobbleRow.width
                    label: strings.t("scrobble.field." + modelData)
                    secret: modelData !== "key"
                    onEdited: function(value) {
                      var next = Object.assign({}, scrobbleRow.values)
                      next[modelData] = value
                      scrobbleRow.values = next
                    }
                    onSubmitted: root.connectScrobble(scrobbleRow.modelData.id, scrobbleRow.values)
                  }
                }
                Row {
                  visible: scrobbleRow.formOpen
                  spacing: Style.space(8)
                  Button {
                    iconText: scrobbleProc.running ? Model.GLYPH.loading : Model.GLYPH.check
                    iconSpinning: scrobbleProc.running
                    text: strings.t(root.scrobbleWaiting ? "scrobble.waiting" : "scrobble.connect")
                    fontSize: Style.font.bodySmall
                    foreground: root.fg
                    fontFamily: root.fontFamily
                    bordered: true
                    enabled: !scrobbleProc.running
                    onClicked: root.connectScrobble(scrobbleRow.modelData.id, scrobbleRow.values)
                  }
                  Button {
                    iconText: Model.GLYPH.forward
                    text: strings.t("scrobble." + scrobbleRow.modelData.id + "Where")
                    fontSize: Style.font.bodySmall
                    foreground: root.fg
                    fontFamily: root.fontFamily
                    bordered: true
                    onClicked: { openUrlProc.command = ["xdg-open", scrobbleRow.modelData.help]; openUrlProc.running = true }
                  }
                }
              }
            }

            // Cloud storage: each connected source, and adding another.
            Repeater {
              model: root.cloudSources
              Row {
                required property var modelData
                spacing: Style.space(8)
                PlainText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: Model.GLYPH.cloud + "  " + modelData.title + "  ·  " + modelData.remote + ":" + modelData.path
                }
                Button {
                  text: strings.t("accounts.remove")
                  fontSize: Style.font.bodySmall
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  bordered: true
                  enabled: !cloudRemoveProc.running
                  onClicked: root.removeCloud(modelData.id)
                }
              }
            }
            Button {
              iconText: Model.GLYPH.plus
              text: strings.t("cloud.addEntry")
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.openCloudForm()
            }

            // The browser can't be picked here: a profile path is free text.
            PlainText {
              width: parent.width
              topPadding: Style.space(4)
              text: strings.t("settings.browser").arg(root.browser) + "\n" + strings.t("settings.browserHint")
              color: root.dim
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
              elide: Text.ElideNone
            }
          }
        }

        // ---------- playlists / tracks ----------
        ListView {
          id: listView
          width: parent.width
          height: Math.min(contentHeight, Style.space(460))
          visible: count > 0
          spacing: Style.space(2)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.rows
          currentIndex: root.cursorIndex
          // Explore's rows carry their section (New releases, Trending …).
          section.property: "section"
          section.delegate: PlainText {
            required property string section
            width: ListView.view.width
            height: section === "" ? 0 : implicitHeight
            visible: section !== ""
            topPadding: Style.space(10)
            bottomPadding: Style.space(4)
            leftPadding: Style.spacing.rowPaddingX
            text: section.toUpperCase()
            color: root.dim
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            font.letterSpacing: 1.1
          }
          onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(keepCurrentVisible)
          function keepCurrentVisible() {
            if (currentIndex >= 0 && currentIndex < count) positionViewAtIndex(currentIndex, ListView.Contain)
          }

          delegate: CursorSurface {
            id: rowItem
            required property var modelData
            required property int index
            readonly property string kind: modelData.kind || (root.view === "tracks" ? "song" : "list")
            readonly property bool isTrack: kind === "song"
            readonly property bool isNow: root.view === "tracks" ? root.isPlayingTrack(index)
              : isTrack ? (root.currentTrack !== null && root.currentTrack.id === modelData.id)
              : kind === "list" && root.isPlayingPlaylist(modelData.id)

            readonly property bool hasCover: (isTrack || !!modelData.cover) && root.showCovers && Model.trackCover(modelData, "small") !== ""

            width: ListView.view.width
            height: Math.max(rowLabels.implicitHeight, leading.height) + Style.spacing.controlPaddingY * 2 + Style.space(8)
            foreground: root.fg
            hasCursor: root.cursorIndex === index
            current: isNow

            Item {
              id: leading
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.rowPaddingX
              anchors.verticalCenter: parent.verticalCenter
              width: rowItem.hasCover ? Style.space(46) : Style.space(36)
              height: rowItem.hasCover ? Style.space(46) : Style.space(36)

              // Small cover: the 320px thumbnail, fetched only for rows the
              // list actually creates (the visible ones).
              SizedImage {
                id: rowCover
                anchors.fill: parent
                visible: rowItem.hasCover && status === Image.Ready
                crop: true
                url: rowItem.hasCover ? Model.trackCover(rowItem.modelData, "small") : ""
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
                font.pixelSize: rowItem.isTrack && !rowItem.isNow && root.view === "tracks" ? Style.font.body : Style.font.title
                text: {
                  if (rowItem.isNow) return root.paused ? Model.GLYPH.pause : Model.GLYPH.play
                  if (rowItem.kind === "country") return rowItem.modelData.id === root.radioCountry ? Model.GLYPH.check : Model.GLYPH.explore
                  if (rowItem.kind === "explore") return rowItem.modelData.id === "__scsearch" ? Model.GLYPH.search
                    : rowItem.modelData.id === "__rdcountry" ? Model.GLYPH.explore
                    : rowItem.modelData.id === "__aimake" ? Model.GLYPH.ai
                    : rowItem.modelData.id === "__cloudadd" ? Model.GLYPH.plus : Model.GLYPH.explore
                  if (rowItem.kind === "mood") return Model.GLYPH.mood
                  if (!rowItem.isTrack) {
                    if (rowItem.modelData.id === "LM") return Model.GLYPH.heart
                    if (rowItem.modelData.id === "DOWNLOADS") return Model.GLYPH.download
                    if (rowItem.modelData.id === "new") return Model.GLYPH.playlistAdd
                    if (/^mix:/.test(rowItem.modelData.id) || rowItem.kind === "mixTarget") return Model.GLYPH.supermix
                    if (rowItem.modelData.id === "sp:liked") return Model.GLYPH.spotify
                    if (rowItem.modelData.id === "dz:fav") return Model.GLYPH.heart
                    if (rowItem.modelData.id === "dz:chart") return Model.GLYPH.deezer
                    if (/^mc:/.test(rowItem.modelData.id)) return Model.GLYPH.mixcloud
                    if (/^au:/.test(rowItem.modelData.id)) return Model.GLYPH.audius
                    if (/^sc:likes:/.test(rowItem.modelData.id)) return Model.GLYPH.soundcloud
                    if (/^cl:[a-f0-9]{8}$/.test(rowItem.modelData.id)) return Model.GLYPH.cloud
                    if (rowItem.modelData.id === "rd:fav") return Model.GLYPH.heart
                    if (rowItem.modelData.id === "ai:mix") return Model.GLYPH.ai
                    if (rowItem.modelData.id === "hist:recent") return Model.GLYPH.history
                    if (/^ms:[a-f0-9]{8}:fav$/.test(rowItem.modelData.id)) return Model.GLYPH.heart
                    if (/^ms:[a-f0-9]{8}:rnd$/.test(rowItem.modelData.id)) return Model.GLYPH.shuffle
                    if (/^ms:[a-f0-9]{8}:pl:/.test(rowItem.modelData.id)) return Model.GLYPH.playlist
                    if (/^ms:/.test(rowItem.modelData.id)) return Model.GLYPH.album
                    if (/^rd:/.test(rowItem.modelData.id)) return Model.GLYPH.radioService
                    if (rowItem.modelData.id === "pc:new") return Model.GLYPH.history
                    if (/^pc:/.test(rowItem.modelData.id)) return Model.GLYPH.podcast
                    if (/^cl:/.test(rowItem.modelData.id)) return Model.GLYPH.album
                    if (rowItem.modelData.id === Model.SUPERMIX_ID) return Model.GLYPH.supermix
                    return root.view === "explore" ? Model.GLYPH.album : Model.GLYPH.playlist
                  }
                  return root.view === "tracks" ? Commons.I18n.formatNumber(rowItem.index + 1) : Model.GLYPH.music
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
                text: rowItem.kind === "list" && root.view !== "explore" ? root.playlistTitle(rowItem.modelData) : rowItem.modelData.title
                font.bold: rowItem.isNow || rowItem.kind === "explore"
                font.pixelSize: Style.font.subtitle
              }
              PlainText {
                width: parent.width
                visible: text !== ""
                color: root.dim
                font.pixelSize: Style.font.body
                text: (rowItem.modelData.artist || rowItem.modelData.subtitle || "")
                  + (rowItem.modelData.note ? "  ·  " + rowItem.modelData.note : "")
              }
            }

            PlainText {
              id: trailing
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.rowPaddingX
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideNone
              color: root.dim
              font.pixelSize: Style.font.body
              text: {
                var d = rowItem.modelData
                if (rowItem.kind === "explore" || rowItem.kind === "mood") return rowItem.kind === "explore" ? Model.GLYPH.forward : ""
                if (rowItem.isTrack) return d.duration !== null && d.duration !== undefined ? Model.formatTime(d.duration, Commons.I18n.formatNumber) : ""
                if (rowItem.kind === "country") return strings.t("rd.stationCount").arg(Commons.I18n.formatNumber(d.count || 0))
                if (/^rd:/.test(String(d.id)) && typeof d.count === "number") return strings.t("rd.stationCount").arg(Commons.I18n.formatNumber(d.count))
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
                visible: root.canLike(rowItem.modelData.id)
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
                visible: Model.isYouTube(rowItem.modelData.id)
                iconText: Model.GLYPH.radio
                tooltipText: strings.t("list.startRadio")
                foreground: root.fg
                fontFamily: root.fontFamily
                enabled: !root.radioBusy
                onClicked: root.startRadio(rowItem.modelData)
              }
              PanelActionButton {
                visible: Model.canDownload(rowItem.modelData.id)
                iconText: Model.GLYPH.download
                tooltipText: strings.t("controls.download")
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: root.openDownload(rowItem.modelData)
              }
              PanelActionButton {
                visible: root.view === "tracks" && root.openPlaylist !== null && /^mix:[a-f0-9]{8}$/.test(root.openPlaylist.id)
                iconText: Model.GLYPH.stop
                tooltipText: strings.t("mix.remove")
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: root.removeFromMix(rowItem.modelData)
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
            if (root.view === "settings" || root.view === "download" || root.view === "services" || root.view === "ai") return ""
            if (root.view === "explore") {
              if (root.exploreError !== "") return strings.t("error.prefix").arg(root.exploreError)
              if (root.rows.length > 0) return ""
              if (root.exploreLoading) return strings.t(root.exploreMode === "search" ? "explore.searching" : "explore.loading")
              return root.exploreMode === "search" ? strings.t("explore.noResults") : ""
            }
            if (root.view === "addTo") {
              if (root.rows.length > 0) return ""
              if (root.addTargetsLoading) return strings.t("list.loadingTargets")
              // Empty only means "none of your own" when YouTube said so.
              return root.addTargetsLive !== null ? strings.t("list.noOwnPlaylists") : strings.t("list.targetsFailed")
            }
            var other = root.view === "playlists" && root.service !== "yt"
            if (other && (root.svc[root.service].setup || (root.service === "cl" && root.cloudFormOpen))) return ""
            var loading = root.view === "tracks" ? root.tracksLoading : other ? root.svc[root.service].loading : root.playlistsLoading
            var error = root.view === "tracks" ? root.tracksError : other ? root.svc[root.service].error : root.playlistsError
            if (error !== "") {
              var msg = strings.t("error.prefix").arg(error)
              if (root.view === "playlists" && root.browser !== "none") msg += "\n" + strings.t("error.cookiesHint").arg(root.browser)
              return msg
            }
            if (root.rows.length > 0) return ""
            if (loading) return strings.t("list.loading")
            if (root.view === "tracks" && root.openPlaylist && root.openPlaylist.id === "DOWNLOADS") return strings.t("list.emptyDownloads")
            return root.view === "tracks" ? strings.t("list.emptyTracks") : strings.t("list.emptyPlaylists")
          }
        }

        // A list didn't load: sign in (most often the cause) or report it.
        Row {
          readonly property string error: root.view === "tracks" ? root.tracksError
            : root.view === "explore" ? root.exploreError
            : root.view === "playlists" ? (root.service === "yt" ? root.playlistsError : root.svc[root.service].error) : ""
          visible: error !== ""
          spacing: Style.space(8)
          Button {
            visible: root.view === "playlists" && root.service === "yt" && root.playlistsError !== "" && root.browser !== "none"
            iconText: Model.GLYPH.login
            text: strings.t("controls.signIn")
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.signIn()
          }
          ReportButton {
            where: root.view === "tracks" ? root.playlistTitle(root.openPlaylist)
              : root.view === "explore" ? root.exploreTitle : strings.t("tab." + root.service)
            message: parent.error
          }
        }
      }
    }
  }

  FullView { id: fullView; p: root }

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

  // "Report the problem": a filled-in GitHub issue for `message`.
  component ReportButton: Button {
    property string where: ""
    property string message: ""
    iconText: reportProc.running ? Model.GLYPH.loading : Model.GLYPH.alert
    iconSpinning: reportProc.running
    text: reportProc.running ? strings.t("report.preparing") : strings.t("report.button")
    enabled: !reportProc.running
    fontSize: Style.font.bodySmall
    foreground: root.fg
    fontFamily: root.fontFamily
    bordered: true
    onClicked: root.reportProblem(where, message)
  }

  // A service in the rail: its logo in the service's color; the selected one
  // lit and outlined. Its name shows on hover.
  component ServiceTab: BorderSurface {
    id: tab
    property string glyph: ""
    property color brand: root.fg
    property string label: ""
    property bool selected: false
    signal clicked()
    implicitWidth: Style.space(38)
    implicitHeight: Style.space(38)
    radius: Style.cornerRadius
    color: selected || tabMouse.containsMouse ? Style.controlFill(false, true, root.fg, Commons.Color.accent) : "transparent"
    borderSpec: selected ? Border.controlSpec("focus", root.fg, Commons.Color.accent) : Border.flat("transparent", 0)

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: tab.glyph
      color: tab.brand
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
    }
    MouseArea {
      id: tabMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tab.clicked()
    }
    PanelToolTip {
      visible: tabMouse.containsMouse
      text: tab.label
    }
  }

  // A labelled text field of the "Connect storage" form.
  component CloudField: Column {
    id: field
    property string label: ""
    property bool secret: false
    property alias text: input.text
    signal edited(string value)
    signal submitted()
    spacing: Style.space(4)

    PlainText {
      width: field.width
      text: field.label
      color: root.dim
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    BorderSurface {
      width: field.width
      implicitHeight: Style.space(34)
      radius: Style.cornerRadius
      color: Style.controlFill(input.activeFocus, false, root.fg, Commons.Color.accent)
      borderSpec: Border.controlSpec(input.activeFocus ? "focus" : "normal", root.fg, Commons.Color.accent)
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.IBeamCursor
        onClicked: input.forceActiveFocus()
      }
      TextInput {
        id: input
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        clip: true
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        selectByMouse: true
        echoMode: field.secret ? TextInput.Password : TextInput.Normal
        onTextEdited: field.edited(text)
        onActiveFocusChanged: root.cloudTyping = activeFocus
        Keys.onReturnPressed: function(event) { focus = false; field.submitted(); event.accepted = true }
        Keys.onEnterPressed: function(event) { focus = false; field.submitted(); event.accepted = true }
        Keys.onEscapePressed: function(event) { focus = false; event.accepted = true }
      }
    }
  }

  // All text in this plugin is plain: titles come from YouTube.
  component PlainText: Text {
    textFormat: Text.PlainText
    // Explicit, so a right-to-left title (Hebrew, Arabic) lines up with
    // the others instead of flipping to the right edge.
    horizontalAlignment: Text.AlignLeft
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }
}
