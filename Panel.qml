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

  // ---- look ----------------------------------------------------------------
  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool barVertical: bar ? bar.vertical === true : false

  // ---- library state -------------------------------------------------------
  property string view: "playlists"          // "playlists" | "tracks"
  property var playlists: []
  property bool playlistsLoading: false
  property string playlistsError: ""
  property var openPlaylist: null            // { id, title, count }
  property var tracks: []
  property bool tracksLoading: false
  property string tracksError: ""
  property int cursorIndex: -1
  readonly property var rows: view === "tracks" ? tracks : playlists

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

  readonly property bool connected: mpvSocket.connected
  readonly property bool playing: connected && !paused
  readonly property var currentTrack: connected && session && playlistPos >= 0 && playlistPos < session.tracks.length
    ? session.tracks[playlistPos] : null
  readonly property string nowTitle: currentTrack ? currentTrack.title : Model.cleanText(mediaTitle)
  readonly property string nowArtist: currentTrack ? currentTrack.artist : ""
  readonly property string barLabel: showTitle && connected && !barVertical && nowTitle !== "" ? Model.truncate(nowTitle, 28) : ""

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function playlistTitle(p) {
    if (!p) return ""
    return p.id === "LM" ? strings.t("list.likedMusic") : p.title
  }

  // ---- helper processes ----------------------------------------------------
  function helper(args) {
    return ["python3", "-I", root.helperPath].concat(args)
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
      if (!openPlaylist || msg.playlistId !== openPlaylist.id) return
      tracks = msg.items
      if (!msg.stale) tracksLoading = false
    } else if (msg.type === "playing") {
      starting = false
      attachAll()
    } else if (msg.type === "error") {
      if (source === "playlists") { playlistsError = msg.message; playlistsLoading = false }
      else if (source === "tracks") { tracksError = msg.message; tracksLoading = false }
      else { playError = msg.message; starting = false }
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
    onExited: root.starting = false
  }

  Process {
    id: stopProc
    command: root.helper(["stop"])
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

  function handleMpvLine(line) {
    var m = Model.parseMpvLine(line)
    if (!m) return
    if (m.event === "property-change") applyProperty(m.name, m.data)
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
    case "playlist-count": playlistCount = typeof data === "number" ? data : 0; break
    case "volume": if (typeof data === "number") volume = data; break
    }
  }

  function resetPlayer() {
    paused = false
    mediaTitle = ""
    duration = 0
    position = 0
    playlistPos = -1
    playlistCount = 0
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
    playProc.command = helper([
      "play", openPlaylist.id,
      "--index", String(Math.max(0, index)),
      "--shuffle", shuffle ? "1" : "0",
      "--browser", browser,
      "--playback-cookies", playbackCookies ? "1" : "0",
      "--volume", String(startVolume),
      "--title", playlistTitle(openPlaylist)
    ])
    playProc.running = true
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
    return session.shuffle ? t.id === currentTrack.id : index === playlistPos && t.id === currentTrack.id
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
  }

  onOpenedChanged: {
    if (!opened) return
    cursorIndex = -1
    if (playlists.length === 0 || !playlistsLoading) loadPlaylists(false)
    if (connected) requestPosition()
    else attach()
  }

  Component.onCompleted: pathsProc.running = true

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
    text: root.connected && root.paused ? Model.GLYPH.pause : Model.GLYPH.music
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
          implicitHeight: Math.max(nowIcon.implicitHeight, nowLabels.implicitHeight)

          PlainText {
            id: nowIcon
            text: root.connected && root.paused ? Model.GLYPH.pause : Model.GLYPH.music
            font.pixelSize: Style.font.display
            elide: Text.ElideNone
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: nowLabels
            anchors.left: nowIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
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
              iconText: root.playing ? Model.GLYPH.pause : Model.GLYPH.play
              tooltipText: strings.t("controls.playPause")
              foreground: root.fg
              fontFamily: root.fontFamily
              fontSize: Style.font.title
              bordered: true
              enabled: root.connected
              opacity: enabled ? 1 : 0.4
              onClicked: root.togglePause()
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
              visible: root.view === "tracks"
              anchors.verticalCenter: parent.verticalCenter
              iconText: LayoutMirroring.enabled ? Model.GLYPH.forward : Model.GLYPH.back
              tooltipText: strings.t("list.back")
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.backToPlaylists()
            }
            PanelSectionHeader {
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, headerLeft.width - (root.view === "tracks" ? Style.space(40) : 0))
              elide: Text.ElideRight
              text: root.view === "tracks" ? root.playlistTitle(root.openPlaylist) : strings.t("list.playlists")
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

            width: ListView.view.width
            height: rowLabels.implicitHeight + Style.spacing.controlPaddingY * 2
            foreground: root.fg
            hasCursor: root.cursorIndex === index
            current: isNow

            PlainText {
              id: leading
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.rowPaddingX
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(28)
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideNone
              color: rowItem.isNow ? root.fg : root.dim
              font.pixelSize: rowItem.isTrack && !rowItem.isNow ? Style.font.caption : Style.font.body
              text: {
                if (rowItem.isNow) return root.paused ? Model.GLYPH.pause : Model.GLYPH.play
                if (!rowItem.isTrack) return rowItem.modelData.id === "LM" ? Model.GLYPH.heart : Model.GLYPH.playlist
                return Commons.I18n.formatNumber(rowItem.index + 1)
              }
            }

            Column {
              id: rowLabels
              anchors.left: leading.right
              anchors.leftMargin: Style.space(8)
              anchors.right: trailing.left
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
                return d.count !== null ? strings.tn("list.tracks", d.count).arg(Commons.I18n.formatNumber(d.count)) : ""
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.cursorIndex = rowItem.index
              onClicked: root.activateRow(rowItem.index)
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
      }
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
