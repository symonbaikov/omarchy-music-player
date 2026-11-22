import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The whole player in its own window, like Apple Music's: a sidebar with
// every service and your mixes, big covers in the middle, the player along
// the bottom, and a "Now Playing" view with the song's cover blurred behind
// it, its lyrics and what's up next. A real window (Hyprland tiles it, moves
// it, sends it to another workspace, closes it), with a full-screen button.
// Everything comes from the panel (`p`, Panel.qml): its lists, its player
// and its actions, so the panel and the window always agree.
FloatingWindow {
  id: win
  required property var p

  title: "Omarchy Music Player"
  color: Commons.Color.background
  implicitWidth: 1440
  implicitHeight: 900
  minimumSize: Qt.size(960, 640)
  // Made by FullView.qml each time it opens; closed any way (its close
  // button, Super+W), it tells the panel, which lets it go.
  visible: true
  readonly property bool shown: visible
  onVisibleChanged: if (!visible && p.fullOpen) p.fullOpen = false

  // "home" | "library" (the panel's current service) | "list" (an open
  // playlist) | "browse" (Explore and search) | "nowplaying"
  property string page: "home"
  property string listFrom: "home"
  property string pageBeforeNow: "home"


  readonly property color fg: Commons.Color.foreground
  readonly property color bg: Commons.Color.background
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.62)
  readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.08)
  readonly property string fontFamily: Style.font.family
  readonly property int pageTitleSize: Math.round(Style.font.displayLarge * 1.3)
  readonly property int cardSize: Style.space(180)
  readonly property int gutter: Style.space(36)

  function t(key) { return p.i18n.t(key) }

  // ---- lyrics ----------------------------------------------------------------
  // What Now Playing shows beside the cover: "lyrics", "notes" or "queue".
  property string side: "queue"
  readonly property bool lyricsMode: side === "lyrics"
  readonly property bool lyricsShown: shown && page === "nowplaying" && lyricsMode
  readonly property bool notesShown: shown && page === "nowplaying" && side === "notes"
  readonly property bool chordsReady: !!p.chords && !!p.currentTrack && p.chords.key === p.currentTrack.id && p.chords.segments.length > 0
  readonly property bool scoresReady: !!p.scores && !!p.currentTrack && p.scores.key === p.currentTrack.id
  readonly property int chordLine: chordsReady ? Model.lyricIndex(p.chords.segments, lyricTime + 0.1) : -1
  readonly property string chordNow: chordLine >= 0 ? p.chords.segments[chordLine].name : ""
  readonly property bool lyricsReady: !!p.lyrics && !!p.currentTrack && p.lyrics.key === p.currentTrack.id
  readonly property bool lyricsSynced: lyricsReady && p.lyrics.synced === true
  // Big, but never more than about 14 characters across the lyrics column
  // (a small window gets smaller lines).
  readonly property int lyricSize: Math.round(Math.max(Style.font.title, Math.min(Style.font.displayLarge * 1.25, nowRight.width / 14)))
  // mpv's position arrives 4× a second; in between, it moves with the clock,
  // so the lines change right on the beat.
  property real lyricTime: 0
  property real positionAt: 0
  readonly property int lyricLine: lyricsSynced ? Model.lyricIndex(p.lyrics.lines, lyricTime + 0.2) : -1

  Binding { target: win.p; property: "fastPosition"; value: win.lyricsShown || win.notesShown }
  Connections {
    target: win.p
    function onPositionChanged() { win.positionAt = Date.now(); win.lyricTime = win.p.position }
    function onCurrentTrackChanged() {
      if (win.lyricsShown) win.p.loadLyrics(win.p.currentTrack)
      if (win.notesShown) win.p.loadNotes(win.p.currentTrack)
    }
  }
  onLyricsShownChanged: if (lyricsShown) p.loadLyrics(p.currentTrack)
  onNotesShownChanged: if (notesShown) p.loadNotes(p.currentTrack)
  Timer {
    interval: 50
    repeat: true
    running: (win.lyricsShown && win.lyricsSynced || win.notesShown && win.chordsReady) && win.p.playing
    onTriggered: win.lyricTime = win.p.position + Math.min(1.5, (Date.now() - win.positionAt) / 1000)
  }

  function showLyrics() {
    if (lyricsShown) { back(); return }
    side = "lyrics"
    go("nowplaying")
  }

  function serviceLabel(id) { return t("tab." + id) }

  Component.onCompleted: {
    page = p.view === "tracks" && p.openPlaylist ? "list" : "home"
    listFrom = "home"
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  // ---- navigation ----------------------------------------------------------
  function go(name) {
    if (name === "nowplaying" && page !== "nowplaying") pageBeforeNow = page
    page = name
    keys.forceActiveFocus()
  }

  function showService(id) {
    p.switchService(id)
    go("library")
  }

  // Connect a cloud storage right here, on the Cloud page.
  function addStorage() {
    p.cloudError = ""
    p.cloudFormOpen = true
    p.switchService("cl")
    go("library")
  }

  readonly property bool cloudFormShown: page === "library" && p.service === "cl"
    && (p.svc.cl.setup !== "" || p.cloudFormOpen)

  function showBrowse() {
    p.openExplore()
    go("browse")
  }

  function back() {
    if (page === "nowplaying") { page = pageBeforeNow; return }
    if (page === "list") {
      if (listFrom === "browse") p.view = "explore"
      page = listFrom
      return
    }
    if (page === "browse" && p.exploreMode !== "home" && p.exploreService === "yt") { p.showExploreHome(); return }
    if (page !== "home") { page = "home"; return }
    if (fullscreen) fullscreen = false
  }

  // A card or row was picked: open a list, play a song, or go deeper.
  function activate(item, from) {
    if (!item) return
    if (from === "explore" || item.kind === "song" || item.kind === "mood") {
      p.activateExplore(item)
      if (p.view === "tracks") { listFrom = "browse"; go("list") }
      else if (p.view !== "explore") { p.view = "explore"; go("browse") }
      else go("browse")
      return
    }
    if (item.kind === "explore") {
      if (item.id === "__cloudadd") addStorage()
      else showBrowse()
      return
    }
    listFrom = page === "list" ? listFrom : page
    p.openList(item)
    go("list")
  }

  // A storage was added: the form starts empty next time.
  Connections {
    target: win.p
    function onCloudFormEpochChanged() { fullCloudPath.text = ""; fullCloudName.text = "" }
  }

  function connectStorage() {
    p.connectCloud(fullCloudPath.text, fullCloudName.text)
  }

  function search(text) {
    var q = String(text || "").trim()
    if (q === "") return
    p.exploreService = p.service === "sc" ? "sc" : "yt"
    p.view = "explore"
    p.runSearch(q)
    go("browse")
  }

  function coverOf(item) {
    if (!item || !p.showCovers) return ""
    if (item.kind === "song" || item.cover || Model.TRACK_KEY_RE.test(String(item.id || ""))) return Model.trackCover(item, "small")
    return ""
  }

  function glyphOf(item) {
    var id = String(item && item.id || "")
    if (item && item.kind === "mood") return Model.GLYPH.mood
    if (item && item.kind === "song") return Model.GLYPH.music
    if (id === "LM") return Model.GLYPH.heart
    if (id === "DOWNLOADS") return Model.GLYPH.download
    if (id === "__cloudadd") return Model.GLYPH.plus
    if (/^mix:/.test(id) || id === Model.SUPERMIX_ID) return Model.GLYPH.supermix
    if (/^sp:/.test(id)) return Model.GLYPH.spotify
    if (/^sc:/.test(id)) return Model.GLYPH.soundcloud
    if (/^cl:[a-f0-9]{8}$/.test(id)) return Model.GLYPH.cloud
    if (/^cl:/.test(id)) return Model.GLYPH.album
    return Model.GLYPH.playlist
  }

  function countText(n) {
    return typeof n === "number" ? p.i18n.tn("list.tracks", n).arg(Commons.I18n.formatNumber(n)) : ""
  }

  readonly property var mixes: p.svc.my.items
  readonly property var libraryCards: p.libraryRows.filter(function(r) {
    return !(r.kind === "explore" && r.id !== "__cloudadd")
  })
  readonly property var queue: p.session && p.session.tracks ? p.session.tracks : []
  readonly property string bigCover: p.connected && p.currentTrack
    ? Model.trackCover(p.currentTrack, p.largeCoverFailedFor === p.currentTrack.id ? "small" : "large") : ""


  // ---- background ------------------------------------------------------------
  Rectangle {
    anchors.fill: parent
    color: win.bg
  }

  // The playing song's cover, blurred, behind everything: faint while
  // browsing, the whole mood of the Now Playing view.
  Item {
    id: ambient
    anchors.fill: parent
    visible: win.bigCover !== "" && ambientImage.status === Image.Ready
    Image {
      id: ambientImage
      anchors.fill: parent
      source: win.bigCover
      sourceSize.width: 160
      sourceSize.height: 160
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      visible: false
    }
    MultiEffect {
      anchors.fill: parent
      source: ambientImage
      blurEnabled: true
      blur: 1.0
      blurMax: 64
      saturation: 0.25
      opacity: win.page === "nowplaying" ? 0.9 : 0.22
      Behavior on opacity { NumberAnimation { duration: Style.duration(260); easing.type: Easing.OutCubic } }
    }
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(win.bg.r, win.bg.g, win.bg.b, win.page === "nowplaying" ? 0.35 : 0.55)
    }
  }

  FocusScope {
    id: keys
    anchors.fill: parent
    focus: true

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) { win.back(); event.accepted = true }
      else if (event.key === Qt.Key_Space) { win.p.togglePause(); event.accepted = true }
      else if (event.text === "/" ) { searchInput.forceActiveFocus(); event.accepted = true }
      else if (event.text === "n") { win.p.next(); event.accepted = true }
      else if (event.text === "b") { win.p.previous(); event.accepted = true }
      else if (event.text === "f") { win.p.toggleLike(win.p.currentTrack); event.accepted = true }
      else if (event.text === "+" || event.text === "=") { win.p.setVolume(win.p.volume + 5); event.accepted = true }
      else if (event.text === "-") { win.p.setVolume(win.p.volume - 5); event.accepted = true }
      else if (event.text === "F" || event.key === Qt.Key_F11) { win.fullscreen = !win.fullscreen; event.accepted = true }
      else if (event.text === "l") { win.showLyrics(); event.accepted = true }
      else if (event.text === "c") { win.side = "notes"; win.go("nowplaying"); event.accepted = true }
    }

    // ---- sidebar ----------------------------------------------------------------
    Rectangle {
      id: sidebar
      visible: win.page !== "nowplaying"
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: playerBar.top
      width: Style.space(270)
      color: Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.035)

      Rectangle {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        color: win.faint
      }

      Column {
        id: sideTop
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(18)
        spacing: Style.space(16)

        Item {
          width: parent.width
          height: Math.max(appTitle.implicitHeight, exitButton.height)
          // Drag the title to move the window, like a title bar.
          MouseArea {
            anchors.fill: parent
            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            onPressed: win.startSystemMove()
            onDoubleClicked: win.fullscreen = !win.fullscreen
          }
          Txt {
            id: appTitle
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: Model.GLYPH.music + "  " + win.t("full.appName")
            font.pixelSize: Style.font.display
            font.bold: true
          }
          Row {
            id: exitButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            // As big as the title beside them: easy to find.
            PanelActionButton {
              iconText: win.fullscreen ? Model.GLYPH.fullscreenExit : Model.GLYPH.fullscreen
              fontSize: Style.font.display
              tooltipText: win.fullscreen ? win.t("full.leaveFullscreen") : win.t("full.fullscreen")
              foreground: win.fg
              fontFamily: win.fontFamily
              onClicked: win.fullscreen = !win.fullscreen
            }
            PanelActionButton {
              iconText: Model.GLYPH.close
              fontSize: Style.font.display
              tooltipText: win.t("full.close")
              foreground: win.fg
              fontFamily: win.fontFamily
              onClicked: win.p.closeFull()
            }
          }
        }

        // Search: YouTube Music, or SoundCloud while its tab is chosen.
        BorderSurface {
          width: parent.width
          implicitHeight: Style.space(38)
          radius: Style.cornerRadius
          color: Style.controlFill(searchInput.activeFocus, false, win.fg, win.accent)
          borderSpec: Border.controlSpec(searchInput.activeFocus ? "focus" : "normal", win.fg, win.accent)
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.IBeamCursor
            onClicked: searchInput.forceActiveFocus()
          }
          Txt {
            id: searchGlyph
            anchors.left: parent.left
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            text: Model.GLYPH.search
            color: win.dim
          }
          TextInput {
            id: searchInput
            anchors.left: searchGlyph.right
            anchors.leftMargin: Style.space(8)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            clip: true
            color: win.fg
            font.family: win.fontFamily
            font.pixelSize: Style.font.subtitle
            selectByMouse: true
            Keys.onReturnPressed: function(event) { win.search(text); keys.forceActiveFocus(); event.accepted = true }
            Keys.onEnterPressed: function(event) { win.search(text); keys.forceActiveFocus(); event.accepted = true }
            Keys.onEscapePressed: function(event) {
              if (text !== "") text = ""
              else keys.forceActiveFocus()
              event.accepted = true
            }
          }
          Txt {
            anchors.fill: searchInput
            verticalAlignment: Text.AlignVCenter
            visible: searchInput.text === "" && !searchInput.activeFocus
            text: win.p.service === "sc" ? win.t("sc.searchField") : win.t("explore.search")
            color: win.dim
            font.pixelSize: Style.font.subtitle
          }
        }
      }

      Flickable {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: sideTop.bottom
        anchors.topMargin: Style.space(14)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.space(12)
        contentHeight: sideColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: sideColumn
          width: parent.width
          spacing: Style.space(2)

          SideItem {
            glyph: Model.GLYPH.home
            label: win.t("full.home")
            selected: win.page === "home"
            onClicked: win.go("home")
          }
          SideItem {
            glyph: Model.GLYPH.explore
            label: win.t("explore.title")
            selected: win.page === "browse"
            onClicked: win.showBrowse()
          }
          SideItem {
            glyph: Model.GLYPH.music
            label: win.t("full.nowPlaying")
            selected: win.page === "nowplaying"
            enabled: win.p.connected
            onClicked: win.go("nowplaying")
          }

          SideHeader { label: win.t("full.library") }
          Repeater {
            model: win.p.serviceTabs
            SideItem {
              required property var modelData
              glyph: modelData.glyph
              glyphColor: modelData.color
              label: modelData.label
              selected: win.page === "library" && win.p.service === modelData.id
              onClicked: win.showService(modelData.id)
            }
          }
          SideItem {
            glyph: Model.GLYPH.download
            label: win.t("list.downloads")
            selected: win.page === "list" && win.p.openPlaylist !== null && win.p.openPlaylist.id === "DOWNLOADS"
            onClicked: win.activate(win.p.downloadsEntry, "")
          }

          SideHeader {
            visible: win.mixes.length > 0
            label: win.t("full.mixes")
          }
          Repeater {
            model: win.mixes.filter(function(m) { return /^mix:/.test(m.id) })
            SideItem {
              required property var modelData
              glyph: Model.GLYPH.supermix
              label: win.p.playlistTitle(modelData)
              selected: win.page === "list" && win.p.openPlaylist !== null && win.p.openPlaylist.id === modelData.id
              onClicked: win.activate(modelData, "")
            }
          }

          SideHeader { label: win.t("full.more") }
          SideItem {
            glyph: Model.GLYPH.cloud
            label: win.t("cloud.addEntry")
            onClicked: win.addStorage()
          }
          SideItem {
            glyph: Model.GLYPH.settings
            label: win.t("settings.open")
            onClicked: win.p.openSettings()
          }
        }
      }
    }

    // ---- pages ----------------------------------------------------------------------
    Item {
      id: content
      visible: win.page !== "nowplaying"
      anchors.left: sidebar.right
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: playerBar.top

      // Listen Now: what's playing, your mixes and every service's lists.
      Flickable {
        id: homePage
        visible: win.page === "home"
        anchors.fill: parent
        contentHeight: homeColumn.implicitHeight + win.gutter * 2
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: homeColumn
          x: win.gutter
          y: win.gutter
          width: homePage.width - win.gutter * 2
          spacing: Style.space(30)

          Txt {
            text: win.t("full.home")
            font.pixelSize: win.pageTitleSize
            font.bold: true
          }

          // The song that's playing, big.
          BorderSurface {
            visible: win.p.connected && win.p.currentTrack !== null
            width: parent.width
            implicitHeight: heroRow.implicitHeight + Style.space(40)
            radius: Style.cornerRadius * 2
            color: Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.05)
            borderSpec: Border.flat(win.faint, 1)

            Row {
              id: heroRow
              x: Style.space(20)
              y: Style.space(20)
              spacing: Style.space(28)
              Cover {
                width: Style.space(200)
                height: width
                url: win.bigCover
                item: win.p.currentTrack
                radius: Style.cornerRadius * 2
                onClicked: win.go("nowplaying")
              }
              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)
                width: homeColumn.width - Style.space(268)
                Txt {
                  text: win.t("full.nowPlaying").toUpperCase()
                  color: win.accent
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  font.letterSpacing: 1.4
                }
                Txt {
                  width: parent.width
                  text: win.p.nowTitle
                  font.pixelSize: Style.font.displayLarge
                  font.bold: true
                }
                Txt {
                  width: parent.width
                  text: win.p.nowArtist
                  color: win.dim
                  font.pixelSize: Style.font.heading
                }
                Row {
                  topPadding: Style.space(10)
                  spacing: Style.space(10)
                  BigButton {
                    glyph: win.p.playing ? Model.GLYPH.pause : Model.GLYPH.play
                    label: win.p.playing ? win.t("full.pause") : win.t("full.play")
                    filled: true
                    onClicked: win.p.togglePause()
                  }
                  BigButton {
                    glyph: Model.GLYPH.queue
                    label: win.t("full.upNext")
                    onClicked: win.go("nowplaying")
                  }
                }
              }
            }
          }

          Shelf { title: win.t("full.mixes"); items: win.mixes }
          Shelf { title: win.t("list.playlists"); glyph: Model.GLYPH.youtube; glyphColor: "#FF0033"; items: win.p.playlists }
          Shelf { title: win.t("tab.sp"); glyph: Model.GLYPH.spotify; glyphColor: "#1ED760"; items: win.p.svc.sp.items }
          Shelf { title: win.t("tab.sc"); glyph: Model.GLYPH.soundcloud; glyphColor: "#FF5500"; items: win.p.svc.sc.items }
          Shelf { title: win.t("tab.cl"); glyph: Model.GLYPH.cloud; glyphColor: "#4FA3FF"; items: win.p.svc.cl.items }
          Repeater {
            model: win.p.exploreSections.slice(0, 3)
            Shelf {
              required property var modelData
              title: modelData.title
              items: modelData.items
              from: "explore"
            }
          }
        }
      }

      // One service's library as a grid of covers.
      Item {
        id: libraryPage
        visible: win.page === "library"
        anchors.fill: parent

        Item {
          id: libraryHeader
          x: win.gutter
          y: win.gutter
          width: parent.width - win.gutter * 2
          height: libraryTitle.implicitHeight
          Txt {
            id: libraryTitle
            anchors.left: parent.left
            width: parent.width - libraryRefresh.width - Style.space(12)
            text: win.serviceLabel(win.p.service)
            font.pixelSize: win.pageTitleSize
            font.bold: true
          }
          Button {
            id: libraryRefresh
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: Model.GLYPH.refresh
            iconSpinning: win.p.service === "yt" ? win.p.playlistsLoading : win.p.svc[win.p.service].loading
            tooltipText: win.t("list.refresh")
            foreground: win.fg
            fontFamily: win.fontFamily
            fontSize: Style.font.title
            onClicked: win.p.loadPlaylists(true)
          }
        }

        // Spotify or SoundCloud not connected yet: the panel has their form.
        Column {
          visible: win.p.service !== "yt" && win.p.service !== "cl" && win.p.svc[win.p.service].setup !== ""
          z: 1
          x: win.gutter
          anchors.top: libraryHeader.bottom
          anchors.topMargin: Style.space(30)
          width: Math.min(parent.width - win.gutter * 2, Style.space(560))
          spacing: Style.space(14)
          Txt {
            width: parent.width
            text: win.t("full.connectBody").arg(win.serviceLabel(win.p.service))
            color: win.dim
            font.pixelSize: Style.font.heading
            wrapMode: Text.Wrap
            elide: Text.ElideNone
          }
          BigButton {
            glyph: Model.GLYPH.login
            label: win.t("full.connect").arg(win.serviceLabel(win.p.service))
            filled: true
            onClicked: win.p.connectInPanel(win.p.service)
          }
        }

        Txt {
          visible: text !== ""
          x: win.gutter
          anchors.top: libraryHeader.bottom
          anchors.topMargin: Style.space(30)
          width: parent.width - win.gutter * 2
          color: win.dim
          font.pixelSize: Style.font.heading
          wrapMode: Text.Wrap
          elide: Text.ElideNone
          text: {
            var s = win.p.service
            if (s !== "yt" && win.p.svc[s].setup !== "") return ""
            if (win.cloudFormShown) return ""
            var error = s === "yt" ? win.p.playlistsError : win.p.svc[s].error
            if (error !== "") return win.t("error.prefix").arg(error)
            if (win.libraryCards.length > 0) return ""
            var loading = s === "yt" ? win.p.playlistsLoading : win.p.svc[s].loading
            return loading ? win.t("list.loading") : win.t("list.emptyPlaylists")
          }
        }

        GridView {
          id: grid
          visible: count > 0 && !win.cloudFormShown
          anchors.left: parent.left
          anchors.leftMargin: win.gutter - Style.space(10)
          anchors.right: parent.right
          anchors.rightMargin: win.gutter - Style.space(10)
          anchors.top: libraryHeader.bottom
          anchors.topMargin: Style.space(24)
          anchors.bottom: parent.bottom
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          readonly property int columns: Math.max(1, Math.floor(width / (win.cardSize + Style.space(20))))
          cellWidth: Math.floor(width / columns)
          cellHeight: cellWidth - Style.space(20) + Style.space(70)
          model: win.libraryCards
          delegate: Item {
            required property var modelData
            width: grid.cellWidth
            height: grid.cellHeight
            Card {
              anchors.horizontalCenter: parent.horizontalCenter
              width: grid.cellWidth - Style.space(20)
              item: modelData
              onClicked: win.activate(modelData, "")
            }
          }
        }
      }

      // Connect a cloud storage, in full screen.
      Flickable {
        id: cloudPage
        visible: win.cloudFormShown
        anchors.fill: parent
        anchors.topMargin: win.gutter + Style.space(70)
        contentHeight: cloudForm.implicitHeight + win.gutter * 2
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: cloudForm
          x: win.gutter
          width: Math.min(cloudPage.width - win.gutter * 2, Style.space(720))
          spacing: Style.space(18)

          Txt {
            width: parent.width
            text: win.t("cloud.title")
            font.pixelSize: Style.font.displayLarge
            font.bold: true
          }
          Txt {
            width: parent.width
            text: win.p.rcloneInstalled ? win.t("cloud.body") : win.t("cloud.noRclone")
            color: win.dim
            font.pixelSize: Style.font.heading
            wrapMode: Text.Wrap
            elide: Text.ElideNone
          }
          BigButton {
            visible: !win.p.rcloneInstalled
            glyph: Model.GLYPH.download
            label: win.t("cloud.installRclone")
            filled: true
            onClicked: win.p.installRclone()
          }

          Flow {
            visible: win.p.rcloneInstalled
            width: parent.width
            spacing: Style.space(10)
            Repeater {
              model: Model.CLOUD_KINDS
              Chip {
                required property var modelData
                label: modelData.label
                selected: win.p.cloudKind === modelData.id
                enabled: win.p.cloudBusy === ""
                onClicked: { win.p.cloudKind = modelData.id; win.p.cloudKindTouched = true; win.p.cloudError = "" }
              }
            }
          }
          Txt {
            visible: win.p.rcloneInstalled
            width: parent.width
            text: win.t("cloud.hint." + win.p.cloudKind)
            color: win.dim
            font.pixelSize: Style.font.subtitle
            wrapMode: Text.Wrap
            elide: Text.ElideNone
          }

          // A remote rclone already has.
          Flow {
            visible: win.p.rcloneInstalled && win.p.cloudKind === "remote" && win.p.cloudRemotes.length > 0
            width: parent.width
            spacing: Style.space(10)
            Repeater {
              model: win.p.cloudRemotes
              Chip {
                required property var modelData
                label: modelData.name + "  ·  " + modelData.type
                selected: win.p.cloudRemote === modelData.name
                onClicked: win.p.cloudRemote = modelData.name
              }
            }
          }
          Txt {
            visible: win.p.rcloneInstalled && win.p.cloudKind === "remote" && win.p.cloudRemotes.length === 0
            width: parent.width
            text: win.t("cloud.noRemotes")
            color: win.dim
            wrapMode: Text.Wrap
            elide: Text.ElideNone
          }

          Repeater {
            model: win.p.rcloneInstalled && win.p.cloudFormEpoch >= 0 ? win.p.cloudKindSpec.fields.slice() : []
            FormField {
              required property var modelData
              width: cloudForm.width
              label: win.t("cloud.field." + modelData)
              secret: Model.SECRET_FIELDS.indexOf(modelData) >= 0
              onEdited: function(value) { win.p.setCloudValue(modelData, value) }
              onSubmitted: win.connectStorage()
            }
          }
          FormField {
            id: fullCloudPath
            visible: win.p.rcloneInstalled
            width: parent.width
            label: win.t(win.p.cloudKind === "s3" ? "cloud.pathS3" : win.p.cloudKind === "smb" ? "cloud.pathSmb" : "cloud.path")
            onSubmitted: win.connectStorage()
          }
          FormField {
            id: fullCloudName
            visible: win.p.rcloneInstalled
            width: parent.width
            label: win.t("cloud.name")
            onSubmitted: win.connectStorage()
          }

          Row {
            visible: win.p.rcloneInstalled
            spacing: Style.space(12)
            BigButton {
              glyph: win.p.cloudBusy !== "" ? Model.GLYPH.loading : Model.GLYPH.cloud
              label: win.p.cloudBusy === "waiting" ? win.t("cloud.waiting")
                : win.p.cloudBusy === "checking" ? win.t("cloud.checking")
                : win.p.cloudKindSpec.oauth ? win.t("cloud.signIn").arg(win.p.cloudKindSpec.label) : win.t("cloud.connect")
              filled: true
              enabled: win.p.cloudBusy === ""
              onClicked: win.connectStorage()
            }
            BigButton {
              visible: win.p.svc.cl.setup === "" && win.p.cloudBusy === ""
              label: win.t("download.cancel")
              onClicked: win.p.cloudFormOpen = false
            }
          }
          Txt {
            visible: win.p.cloudError !== ""
            width: parent.width
            text: win.p.cloudError
            color: Commons.Color.urgent
            font.pixelSize: Style.font.subtitle
            wrapMode: Text.Wrap
            elide: Text.ElideNone
          }
          BigButton {
            visible: win.p.cloudError !== ""
            glyph: Model.GLYPH.alert
            label: win.t("report.button")
            onClicked: win.p.reportProblem(win.t("tab.cl"), win.p.cloudError)
          }
        }
      }

      // An open playlist: big artwork, Play and Shuffle, then its songs.
      ListView {
        id: listPage
        visible: win.page === "list"
        anchors.fill: parent
        anchors.leftMargin: win.gutter - Style.space(10)
        anchors.rightMargin: win.gutter - Style.space(10)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        model: win.page === "list" ? win.p.tracks : []
        spacing: Style.space(2)
        header: Item {
          width: listPage.width
          height: listHead.implicitHeight + Style.space(60)
          Row {
            id: listHead
            x: Style.space(10)
            y: win.gutter
            spacing: Style.space(30)
            Cover {
              width: Style.space(230)
              height: width
              radius: Style.cornerRadius * 2
              item: win.p.openPlaylist
              url: win.p.openPlaylist && win.p.openPlaylist.cover ? win.coverOf(win.p.openPlaylist)
                : (win.p.tracks.length > 0 ? win.coverOf(win.p.tracks[0]) : "")
              onClicked: if (win.p.tracks.length > 0) win.p.play(0, false)
            }
            Column {
              anchors.bottom: parent.bottom
              spacing: Style.space(8)
              width: listPage.width - Style.space(290)
              Txt {
                text: (win.p.openPlaylist && /^cl:[a-f0-9]{8}:/.test(win.p.openPlaylist.id) ? win.t("full.album") : win.t("full.playlist")).toUpperCase()
                color: win.accent
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                font.letterSpacing: 1.4
              }
              Txt {
                width: parent.width
                text: win.p.playlistTitle(win.p.openPlaylist)
                font.pixelSize: win.pageTitleSize
                font.bold: true
                wrapMode: Text.Wrap
                maximumLineCount: 2
              }
              Txt {
                width: parent.width
                text: [win.p.openPlaylist && win.p.openPlaylist.subtitle ? win.p.openPlaylist.subtitle : "",
                       win.countText(win.p.tracks.length)].filter(function(x) { return x !== "" }).join("  ·  ")
                color: win.dim
                font.pixelSize: Style.font.heading
              }
              Row {
                topPadding: Style.space(10)
                spacing: Style.space(10)
                BigButton {
                  glyph: Model.GLYPH.play
                  label: win.t("full.play")
                  filled: true
                  enabled: win.p.tracks.length > 0
                  onClicked: win.p.play(0, false)
                }
                BigButton {
                  glyph: Model.GLYPH.shuffle
                  label: win.t("list.shuffle")
                  enabled: win.p.tracks.length > 1
                  onClicked: win.p.play(Math.floor(Math.random() * win.p.tracks.length), true)
                }
              }
              Txt {
                visible: text !== ""
                width: parent.width
                color: win.dim
                wrapMode: Text.Wrap
                elide: Text.ElideNone
                text: win.p.tracksError !== "" ? win.t("error.prefix").arg(win.p.tracksError)
                  : win.p.tracks.length === 0 ? (win.p.tracksLoading ? win.t("list.loading") : win.t("list.emptyTracks")) : ""
              }
            }
          }
        }
        delegate: TrackRow {
          required property var modelData
          required property int index
          width: listPage.width
          track: modelData
          number: index + 1
          now: win.p.isPlayingTrack(index)
          onClicked: win.p.play(index, false)
        }
      }

      // Explore and search.
      Item {
        id: browsePage
        visible: win.page === "browse"
        anchors.fill: parent

        Item {
          id: browseHeader
          x: win.gutter
          y: win.gutter
          width: parent.width - win.gutter * 2
          height: browseTitle.implicitHeight
          PanelActionButton {
            id: browseBack
            visible: win.p.exploreMode !== "home" && win.p.exploreService === "yt"
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            iconText: Model.GLYPH.back
            fontSize: Style.font.display
            foreground: win.fg
            fontFamily: win.fontFamily
            onClicked: win.back()
          }
          Txt {
            id: browseTitle
            anchors.left: browseBack.visible ? browseBack.right : parent.left
            anchors.leftMargin: browseBack.visible ? Style.space(10) : 0
            anchors.right: parent.right
            text: win.p.exploreTitle !== "" ? win.p.exploreTitle : win.t("explore.title")
            font.pixelSize: win.pageTitleSize
            font.bold: true
          }
        }

        Txt {
          visible: text !== ""
          x: win.gutter
          anchors.top: browseHeader.bottom
          anchors.topMargin: Style.space(24)
          width: parent.width - win.gutter * 2
          color: win.dim
          font.pixelSize: Style.font.heading
          wrapMode: Text.Wrap
          elide: Text.ElideNone
          text: win.p.exploreError !== "" ? win.t("error.prefix").arg(win.p.exploreError)
            : win.p.exploreLoading && win.p.exploreRowsData.length === 0
              ? win.t(win.p.exploreMode === "search" ? "explore.searching" : "explore.loading")
            : win.p.exploreMode === "search" && win.p.exploreRowsData.length === 0 ? win.t("explore.noResults") : ""
        }

        // Explore's front page: its shelves.
        Flickable {
          id: browseShelves
          visible: win.p.exploreMode === "home"
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: browseHeader.bottom
          anchors.topMargin: Style.space(24)
          anchors.bottom: parent.bottom
          contentHeight: shelvesColumn.implicitHeight + win.gutter
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          Column {
            id: shelvesColumn
            x: win.gutter
            width: browseShelves.width - win.gutter * 2
            spacing: Style.space(30)
            Repeater {
              model: win.p.exploreSections
              Shelf {
                required property var modelData
                title: modelData.title
                items: modelData.items
                from: "explore"
              }
            }
          }
        }

        // A mood's lists, or search results.
        ListView {
          id: browseList
          visible: win.p.exploreMode !== "home"
          anchors.left: parent.left
          anchors.leftMargin: win.gutter - Style.space(10)
          anchors.right: parent.right
          anchors.rightMargin: win.gutter - Style.space(10)
          anchors.top: browseHeader.bottom
          anchors.topMargin: Style.space(24)
          anchors.bottom: parent.bottom
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          spacing: Style.space(2)
          model: win.p.exploreMode !== "home" ? win.p.exploreRowsData : []
          delegate: TrackRow {
            required property var modelData
            required property int index
            width: browseList.width
            track: modelData
            number: index + 1
            now: modelData.kind === "song" && win.p.currentTrack !== null && win.p.currentTrack.id === modelData.id
            onClicked: win.activate(modelData, "explore")
          }
        }
      }
    }

    // ---- now playing ----------------------------------------------------------------
    Item {
      id: nowPage
      visible: win.page === "nowplaying"
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: playerBar.top

      PanelActionButton {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: Style.space(24)
        iconText: Model.GLYPH.chevronDown
        fontSize: Style.font.displayLarge
        tooltipText: win.t("list.back")
        foreground: win.fg
        fontFamily: win.fontFamily
        onClicked: win.back()
      }

      // The cover as big as fits with the names and controls under it, also
      // in a small window.
      readonly property real artSize: Math.max(Style.space(96), Math.min(height - Style.space(300), width * 0.36))

      Column {
        id: nowLeft
        anchors.verticalCenter: parent.verticalCenter
        x: Math.max(win.gutter, (parent.width * 0.55 - width) / 2)
        width: nowPage.artSize
        spacing: Style.space(18)

        Cover {
          width: nowPage.artSize
          height: width
          radius: Style.cornerRadius * 3
          url: win.bigCover
          item: win.p.currentTrack
          shadow: true
          onStatusFailed: if (win.p.currentTrack && String(url).indexOf("maxresdefault") >= 0) win.p.largeCoverFailedFor = win.p.currentTrack.id
        }
        Column {
          width: parent.width
          spacing: Style.space(4)
          Txt {
            width: parent.width
            text: win.p.connected && win.p.nowTitle !== "" ? win.p.nowTitle : win.t("now.idle")
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            wrapMode: Text.Wrap
            maximumLineCount: 2
          }
          Txt {
            width: parent.width
            text: win.p.nowArtist
            color: win.dim
            font.pixelSize: Style.font.heading
          }
        }
        Column {
          width: parent.width
          spacing: Style.space(4)
          PanelSlider {
            width: parent.width
            minimum: 0
            maximum: Math.max(1, win.p.duration)
            step: 1
            value: win.p.position
            enabled: win.p.connected
            onReleased: function(value) { win.p.seek(value) }
          }
          Item {
            width: parent.width
            height: nowElapsed.implicitHeight
            Txt {
              id: nowElapsed
              text: Model.formatTime(win.p.position, Commons.I18n.formatNumber)
              color: win.dim
              font.pixelSize: Style.font.caption
            }
            Txt {
              anchors.right: parent.right
              text: win.p.duration > 0 ? "-" + Model.formatTime(Math.max(0, win.p.duration - win.p.position), Commons.I18n.formatNumber) : ""
              color: win.dim
              font.pixelSize: Style.font.caption
            }
          }
        }
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(28)
          Transport { glyph: Model.GLYPH.previous; size: Style.font.displayLarge; onClicked: win.p.previous() }
          Transport {
            glyph: win.p.loading ? Model.GLYPH.loading : (win.p.playing ? Model.GLYPH.pause : Model.GLYPH.play)
            spinning: win.p.loading
            size: Math.round(Style.font.displayLarge * 1.6)
            onClicked: win.p.togglePause()
          }
          Transport { glyph: Model.GLYPH.next; size: Style.font.displayLarge; onClicked: win.p.next() }
        }
      }

      // The right side: the song's lyrics, or what's up next.
      Item {
        id: nowRight
        anchors.left: parent.left
        anchors.leftMargin: parent.width * 0.58
        anchors.right: parent.right
        anchors.rightMargin: win.gutter * 2
        anchors.top: parent.top
        anchors.topMargin: win.gutter * 2
        anchors.bottom: parent.bottom
        anchors.bottomMargin: win.gutter

        Row {
          id: nowTabs
          spacing: Style.space(10)
          Chip {
            label: Model.GLYPH.lyrics + "  " + win.t("full.lyrics")
            selected: win.side === "lyrics"
            onClicked: win.side = "lyrics"
          }
          Chip {
            label: Model.GLYPH.notes + "  " + win.t("notes.tab")
            selected: win.side === "notes"
            onClicked: win.side = "notes"
          }
          Chip {
            label: Model.GLYPH.queue + "  " + win.t("full.upNext")
            selected: win.side === "queue"
            onClicked: win.side = "queue"
          }
        }

        // Up next: the queue from the playing song on.
        Column {
          visible: win.side === "queue"
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: nowTabs.bottom
          anchors.topMargin: Style.space(22)
          anchors.bottom: parent.bottom
          spacing: Style.space(12)

          Txt {
            id: playingFrom
            visible: win.p.session !== null && win.p.session.playlistTitle !== ""
            width: parent.width
            text: win.p.session ? win.t("full.playingFrom").arg(win.p.session.playlistTitle) : ""
            color: win.dim
          }
          ListView {
            id: queueView
            width: parent.width
            height: parent.height - (playingFrom.visible ? playingFrom.height + Style.space(12) : 0)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            spacing: Style.space(2)
            // The playing song first, then what comes after it.
            readonly property int from: Math.max(0, win.p.playlistPos)
            onFromChanged: positionViewAtBeginning()
            onVisibleChanged: if (visible) positionViewAtBeginning()
            model: win.page === "nowplaying" && win.side === "queue" ? win.queue.slice(from) : []
            delegate: TrackRow {
              required property var modelData
              required property int index
              width: queueView.width
              track: modelData
              number: queueView.from + index + 1
              now: index === 0 && win.p.playlistPos >= 0
              compact: true
              onClicked: {
                win.p.send(["playlist-play-index", queueView.from + index])
                win.p.send(["set_property", "pause", false])
              }
            }
          }
        }

        // Notes, for learning the song: its chords in time with it (heard
        // from the audio: the one playing big, on a guitar and a keyboard,
        // the next ones after it), and the sheet music and tabs found for it.
        Flickable {
          id: notesPane
          visible: win.side === "notes"
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: nowTabs.bottom
          anchors.topMargin: Style.space(22)
          anchors.bottom: parent.bottom
          contentHeight: notesColumn.implicitHeight + Style.space(20)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: notesColumn
            width: notesPane.width
            spacing: Style.space(16)

            Txt {
              visible: text !== ""
              width: parent.width
              wrapMode: Text.Wrap
              elide: Text.ElideNone
              color: win.dim
              font.pixelSize: Style.font.heading
              text: !win.p.currentTrack ? win.t("now.idle")
                : win.chordsReady ? ""
                : win.p.numpyMissing ? win.t("notes.needNumpy")
                : win.p.chordsError !== "" ? win.t("error.prefix").arg(win.p.chordsError)
                : win.p.chordsStage === "listen" ? win.t("notes.listening")
                : win.p.chordsStage === "audio" ? win.t("notes.fetching") : ""
            }
            BigButton {
              visible: win.p.numpyMissing
              glyph: Model.GLYPH.download
              label: win.t("notes.installNumpy")
              filled: true
              onClicked: win.p.installNumpy()
            }

            // The chord playing now.
            Row {
              visible: win.chordsReady
              spacing: Style.space(26)
              Column {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(150)
                spacing: Style.space(2)
                Txt {
                  text: win.t("notes.now").toUpperCase()
                  color: win.accent
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.3
                }
                Txt {
                  text: win.chordNow === "" || win.chordNow === "N" ? "–" : Model.chordLabel(win.chordNow)
                  font.pixelSize: Math.round(Style.font.displayLarge * 2.4)
                  font.bold: true
                }
                Txt {
                  text: Model.chordNoteNames(win.chordNow).join("  ·  ")
                  color: win.dim
                  font.pixelSize: Style.font.heading
                }
              }
              GuitarChord {
                anchors.verticalCenter: parent.verticalCenter
                chord: win.chordNow
              }
            }
            PianoChord {
              visible: win.chordsReady
              width: Math.min(parent.width, Style.space(460))
              chord: win.chordNow
            }

            // The chords to come: click one to go there.
            Txt {
              visible: win.chordsReady
              topPadding: Style.space(6)
              text: win.t("notes.chords").toUpperCase()
              color: win.dim
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.3
            }
            ListView {
              id: chordStrip
              visible: win.chordsReady
              width: parent.width
              height: Style.space(58)
              orientation: ListView.Horizontal
              spacing: Style.space(8)
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              model: win.chordsReady ? win.p.chords.segments.filter(function(s) { return s.name !== "N" }) : []
              function follow() {
                if (!visible || count === 0 || moving) return
                var at = 0
                for (var i = 0; i < count; i++) if (model[i].t <= win.lyricTime + 0.1) at = i
                var from = contentX
                positionViewAtIndex(at, ListView.Beginning)
                var to = contentX
                contentX = from
                stripAnim.to = to
                stripAnim.restart()
              }
              NumberAnimation { id: stripAnim; target: chordStrip; property: "contentX"; duration: 400; easing.type: Easing.OutCubic }
              Connections {
                target: win
                function onChordLineChanged() { chordStrip.follow() }
              }
              delegate: Rectangle {
                required property var modelData
                readonly property bool now: win.chordsReady && win.chordLine >= 0 && win.p.chords.segments[win.chordLine].t === modelData.t
                width: Math.max(Style.space(64), stripName.implicitWidth + Style.space(28))
                height: chordStrip.height
                radius: Style.cornerRadius * 2
                color: now ? win.accent : (stripMouse.containsMouse ? Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.16) : Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.08))
                Column {
                  anchors.centerIn: parent
                  Text {
                    id: stripName
                    anchors.horizontalCenter: parent.horizontalCenter
                    textFormat: Text.PlainText
                    text: Model.chordLabel(modelData.name)
                    color: now ? win.bg : win.fg
                    font.family: win.fontFamily
                    font.pixelSize: Style.font.display
                    font.bold: true
                  }
                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    textFormat: Text.PlainText
                    text: Model.formatTime(modelData.t, Commons.I18n.formatNumber)
                    color: now ? win.bg : win.dim
                    font.family: win.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
                MouseArea {
                  id: stripMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: win.p.seek(modelData.t)
                }
              }
            }
            Txt {
              visible: win.chordsReady
              width: parent.width
              wrapMode: Text.Wrap
              elide: Text.ElideNone
              color: win.dim
              font.pixelSize: Style.font.caption
              text: win.chordsReady ? ((win.p.chords.songKey !== "" ? win.t("notes.key").arg(Model.keyLabel(win.p.chords.songKey)) + "  ·  " : "") + win.t("notes.approx")) : ""
            }

            // Sheet music and tabs from the services.
            Txt {
              topPadding: Style.space(14)
              text: win.t("notes.scores")
              font.pixelSize: Style.font.display
              font.bold: true
            }
            Txt {
              visible: text !== ""
              width: parent.width
              wrapMode: Text.Wrap
              elide: Text.ElideNone
              color: win.dim
              text: !win.p.currentTrack ? "" : !win.scoresReady ? win.t("notes.searching")
                : win.p.scores.items.length === 0 ? win.t("notes.noScores") : ""
            }
            Repeater {
              model: win.scoresReady ? win.p.scores.items : []
              Rectangle {
                required property var modelData
                width: notesColumn.width
                height: scoreText.implicitHeight + Style.space(20)
                radius: Style.cornerRadius
                color: scoreMouse.containsMouse ? Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.10) : Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.05)
                Txt {
                  id: scoreGlyph
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(14)
                  anchors.verticalCenter: parent.verticalCenter
                  text: Model.GLYPH.guitar
                  color: win.accent
                  font.pixelSize: Style.font.display
                }
                Column {
                  id: scoreText
                  anchors.left: scoreGlyph.right
                  anchors.leftMargin: Style.space(14)
                  anchors.right: scoreOpen.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)
                  Txt {
                    width: parent.width
                    text: modelData.title + (modelData.artist !== "" ? "  —  " + modelData.artist : "")
                    font.pixelSize: Style.font.subtitle
                    font.bold: true
                  }
                  Txt {
                    width: parent.width
                    text: "Songsterr  ·  " + modelData.instruments.join(", ")
                    color: win.dim
                  }
                }
                Txt {
                  id: scoreOpen
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(16)
                  anchors.verticalCenter: parent.verticalCenter
                  text: win.t("notes.open") + "  " + Model.GLYPH.forward
                  color: win.dim
                }
                MouseArea {
                  id: scoreMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: win.p.openScore(modelData.url)
                }
              }
            }
            Flow {
              visible: win.scoresReady
              width: parent.width
              spacing: Style.space(10)
              BigButton {
                visible: win.scoresReady && win.p.scores.musescore !== ""
                glyph: Model.GLYPH.notes
                label: win.t("notes.musescore")
                onClicked: win.p.openScore(win.p.scores.musescore)
              }
              BigButton {
                visible: win.scoresReady && win.p.scores.ultimateGuitar !== ""
                glyph: Model.GLYPH.guitar
                label: win.t("notes.ultimateGuitar")
                onClicked: win.p.openScore(win.p.scores.ultimateGuitar)
              }
            }
          }
        }

        // Lyrics, like Apple Music's: big lines that light up with the song
        // and scroll by themselves; the others dim and soft. Click a line
        // to go there.
        Item {
          id: lyricsPane
          visible: win.lyricsMode
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: nowTabs.bottom
          anchors.topMargin: Style.space(22)
          anchors.bottom: parent.bottom

          Txt {
            visible: text !== ""
            width: parent.width
            y: parent.height * 0.3
            wrapMode: Text.Wrap
            elide: Text.ElideNone
            color: win.dim
            font.pixelSize: win.lyricSize
            font.bold: true
            text: !win.p.currentTrack ? win.t("now.idle")
              : !win.lyricsReady ? (win.p.lyricsLoading ? win.t("full.lyricsLoading") : "")
              : win.p.lyrics.instrumental ? Model.GLYPH.music + "  " + win.t("full.instrumental")
              : win.p.lyrics.lines.length === 0 ? win.t("full.lyricsNone") : ""
          }

          ListView {
            id: lyricView
            anchors.fill: parent
            visible: win.lyricsReady && win.p.lyrics.lines.length > 0
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            spacing: Style.space(win.lyricsSynced ? 26 : 10)
            model: visible ? win.p.lyrics.lines : []
            // Room above the first line and below the last, so either can
            // sit where the playing line does.
            header: Item { width: lyricView.width; height: win.lyricsSynced ? lyricView.height * 0.3 : 0 }
            footer: Item {
              width: lyricView.width
              height: Math.max(lyricSource.implicitHeight + Style.space(30), win.lyricsSynced ? lyricView.height * 0.6 : 0)
              Txt {
                id: lyricSource
                y: Style.space(30)
                width: parent.width
                visible: win.lyricsReady && win.p.lyrics.source !== ""
                text: win.lyricsReady ? win.t("full.lyricsSource").arg(win.p.lyrics.source) : ""
                color: win.dim
                font.pixelSize: Style.font.caption
              }
            }

            // Follow the song, unless the user is scrolling through.
            property bool userScrolled: false
            onMovementStarted: { userScrolled = true; resumeFollow.stop() }
            onMovementEnded: resumeFollow.restart()
            Timer { id: resumeFollow; interval: 3000; onTriggered: { lyricView.userScrolled = false; lyricView.follow(true) } }

            function follow(animate) {
              if (!win.lyricsSynced || userScrolled || !visible || count === 0) return
              var i = Math.max(0, win.lyricLine)
              var from = contentY
              positionViewAtIndex(i, ListView.Beginning)
              var to = Math.max(originY, contentY - height * 0.3 + (win.lyricLine < 0 ? 0 : 0))
              if (win.lyricLine < 0) to = originY
              contentY = from
              if (animate && !Style.reduceMotion) { scrollAnim.to = to; scrollAnim.restart() }
              else contentY = to
            }
            NumberAnimation { id: scrollAnim; target: lyricView; property: "contentY"; duration: 650; easing.type: Easing.OutCubic }
            Connections {
              target: win
              function onLyricLineChanged() { lyricView.follow(true) }
            }
            onVisibleChanged: if (visible) Qt.callLater(function() { lyricView.follow(false) })
            onCountChanged: Qt.callLater(function() { lyricView.follow(false) })

            delegate: Text {
              id: lyricLine
              required property var modelData
              required property int index
              readonly property bool current: win.lyricsSynced && index === win.lyricLine
              readonly property int distance: win.lyricsSynced && win.lyricLine >= 0 ? Math.abs(index - win.lyricLine) : 0
              width: lyricView.width
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: modelData.text !== "" ? modelData.text : Model.GLYPH.music
              color: win.fg
              font.family: win.fontFamily
              font.bold: true
              font.pixelSize: win.lyricsSynced ? win.lyricSize : Math.round(Style.font.heading * 1.35)
              opacity: !win.lyricsSynced ? 0.9 : current ? 1 : (index < win.lyricLine ? 0.3 : 0.42)
              transformOrigin: Item.Left
              scale: !win.lyricsSynced || current ? 1 : 0.95
              Behavior on opacity { NumberAnimation { duration: Style.duration(350) } }
              Behavior on scale { NumberAnimation { duration: Style.duration(350); easing.type: Easing.OutCubic } }
              layer.enabled: win.lyricsSynced && distance > 0 && !Style.reduceMotion
              layer.effect: MultiEffect {
                blurEnabled: true
                blurMax: 24
                blur: Math.min(0.6, lyricLine.distance * 0.12)
              }
              MouseArea {
                anchors.fill: parent
                enabled: win.lyricsSynced
                cursorShape: Qt.PointingHandCursor
                onClicked: { win.p.seek(lyricLine.modelData.t); lyricView.userScrolled = false }
              }
            }
          }
        }
      }
    }

    // ---- the player, along the bottom --------------------------------------------
    Rectangle {
      id: playerBar
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Style.space(92)
      color: Qt.rgba(win.bg.r, win.bg.g, win.bg.b, 0.82)

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 1
        color: win.faint
      }

      // The song: cover and names. The cover opens Now Playing.
      Row {
        id: barSong
        anchors.left: parent.left
        anchors.leftMargin: Style.space(18)
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(parent.width * 0.3, Style.space(380))
        spacing: Style.space(14)
        Cover {
          width: Style.space(60)
          height: width
          url: win.p.nowCoverUrl
          item: win.p.currentTrack
          onClicked: win.go(win.page === "nowplaying" ? win.pageBeforeNow : "nowplaying")
        }
        Column {
          anchors.verticalCenter: parent.verticalCenter
          width: barSong.width - Style.space(74)
          spacing: Style.space(2)
          Txt {
            width: parent.width
            text: win.p.starting ? win.t("now.loading") : (win.p.connected && win.p.nowTitle !== "" ? win.p.nowTitle : win.t("now.idle"))
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Txt {
            width: parent.width
            text: win.p.connected ? win.p.nowArtist : win.t("full.idleHint")
            color: win.dim
          }
        }
      }

      // Transport and progress, in the middle.
      Column {
        anchors.centerIn: parent
        width: Math.min(parent.width * 0.4, Style.space(620))
        spacing: Style.space(4)
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(18)
          Transport {
            glyph: win.p.repeatMode === "one" ? Model.GLYPH.repeatOne : Model.GLYPH.repeat
            size: Style.font.heading
            active: win.p.repeatMode !== "off"
            onClicked: win.p.cycleRepeat()
          }
          Transport { glyph: Model.GLYPH.previous; size: Style.font.display; enabled: win.p.connected; onClicked: win.p.previous() }
          Transport {
            glyph: win.p.loading ? Model.GLYPH.loading : (win.p.playing ? Model.GLYPH.pause : Model.GLYPH.play)
            spinning: win.p.loading
            size: Math.round(Style.font.display * 1.35)
            enabled: win.p.connected
            onClicked: win.p.togglePause()
          }
          Transport { glyph: Model.GLYPH.next; size: Style.font.display; enabled: win.p.connected; onClicked: win.p.next() }
          Transport {
            glyph: Model.GLYPH.radio
            size: Style.font.heading
            enabled: win.p.connected && win.p.currentTrack !== null && Model.isYouTube(win.p.currentTrack.id) && !win.p.radioBusy
            onClicked: { win.p.startRadio(win.p.currentTrack); win.listFrom = win.page === "list" ? win.listFrom : win.page; win.go("list") }
          }
        }
        Row {
          width: parent.width
          spacing: Style.space(10)
          Txt {
            id: barElapsed
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(44)
            horizontalAlignment: Text.AlignRight
            text: win.p.connected ? Model.formatTime(win.p.position, Commons.I18n.formatNumber) : ""
            color: win.dim
            font.pixelSize: Style.font.caption
          }
          PanelSlider {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(108)
            minimum: 0
            maximum: Math.max(1, win.p.duration)
            step: 1
            value: win.p.position
            enabled: win.p.connected
            onReleased: function(value) { win.p.seek(value) }
          }
          Txt {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(44)
            text: win.p.duration > 0 ? Model.formatTime(win.p.duration, Commons.I18n.formatNumber) : ""
            color: win.dim
            font.pixelSize: Style.font.caption
          }
        }
      }

      // Like, Now Playing, volume, leave full screen.
      Row {
        anchors.right: parent.right
        anchors.rightMargin: Style.space(18)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(8)

        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          visible: win.p.currentTrack !== null && Model.isYouTube(win.p.currentTrack.id)
          readonly property bool liked: win.p.currentTrack !== null && win.p.isLiked(win.p.currentTrack.id)
          iconText: liked ? Model.GLYPH.heart : Model.GLYPH.heartOutline
          fontSize: Style.font.title
          tooltipText: liked ? win.t("controls.unlike") : win.t("controls.like")
          foreground: liked ? win.accent : win.fg
          fontFamily: win.fontFamily
          onClicked: win.p.toggleLike(win.p.currentTrack)
        }
        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.GLYPH.lyrics
          fontSize: Style.font.title
          tooltipText: win.t("full.lyricsButton")
          foreground: win.lyricsShown ? win.accent : win.fg
          fontFamily: win.fontFamily
          enabled: win.p.connected
          onClicked: win.showLyrics()
        }
        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.GLYPH.queue
          fontSize: Style.font.title
          tooltipText: win.t("full.upNext")
          foreground: win.page === "nowplaying" && win.side === "queue" ? win.accent : win.fg
          fontFamily: win.fontFamily
          enabled: win.p.connected
          onClicked: {
            if (win.page === "nowplaying" && win.side === "queue") win.back()
            else { win.side = "queue"; win.go("nowplaying") }
          }
        }
        Txt {
          anchors.verticalCenter: parent.verticalCenter
          text: win.p.volume <= 0 ? Model.GLYPH.volumeOff : Model.GLYPH.volume
          font.pixelSize: Style.font.title
          color: win.dim
        }
        PanelSlider {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(120)
          minimum: 0
          maximum: 100
          step: 1
          integer: true
          value: win.p.volume
          onMoved: function(value) { win.p.setVolume(value) }
        }
        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: win.fullscreen ? Model.GLYPH.fullscreenExit : Model.GLYPH.fullscreen
          fontSize: Style.font.display
          tooltipText: win.fullscreen ? win.t("full.leaveFullscreen") : win.t("full.fullscreen")
          foreground: win.fg
          fontFamily: win.fontFamily
          onClicked: win.fullscreen = !win.fullscreen
        }
      }
    }
  }

  // ---- components -------------------------------------------------------------

  // Plain text: every title here comes from a service.
  component Txt: Text {
    textFormat: Text.PlainText
    horizontalAlignment: Text.AlignLeft
    color: win.fg
    font.family: win.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  component SideHeader: Txt {
    property string label: ""
    width: parent ? parent.width : 0
    leftPadding: Style.space(24)
    topPadding: Style.space(18)
    bottomPadding: Style.space(6)
    color: win.dim
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1.3
    text: label.toUpperCase()
  }

  component SideItem: Item {
    id: side
    property string glyph: ""
    property color glyphColor: win.accent
    property string label: ""
    property bool selected: false
    signal clicked()
    width: parent ? parent.width : 0
    height: Style.space(38)
    opacity: enabled ? 1 : 0.4

    Rectangle {
      anchors.fill: parent
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      radius: Style.cornerRadius
      color: side.selected ? Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.12)
        : sideMouse.containsMouse ? Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.06) : "transparent"
    }
    Txt {
      id: sideGlyph
      x: Style.space(22)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(24)
      horizontalAlignment: Text.AlignHCenter
      text: side.glyph
      color: side.glyphColor
      font.pixelSize: Style.font.title
      elide: Text.ElideNone
    }
    Txt {
      anchors.left: sideGlyph.right
      anchors.leftMargin: Style.space(12)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(18)
      anchors.verticalCenter: parent.verticalCenter
      text: side.label
      font.pixelSize: Style.font.subtitle
      font.bold: side.selected
    }
    MouseArea {
      id: sideMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: side.clicked()
    }
  }

  // Artwork: the cover when there is one, else a colored tile with the
  // list's glyph (each list keeps its color).
  component Cover: Item {
    id: cover
    property url url: ""
    property var item: null
    property real radius: Style.cornerRadius
    property bool shadow: false
    signal clicked()
    signal statusFailed()

    readonly property real hue: Model.tileHue(item ? item.id : "")
    readonly property bool isMood: !!item && item.kind === "mood"
    readonly property bool shown: cover.url != "" && img.status === Image.Ready

    Rectangle {
      anchors.fill: parent
      radius: cover.radius
      visible: !cover.shown
      gradient: Gradient {
        GradientStop { position: 0; color: Qt.hsla(cover.hue, 0.55, 0.50, 1) }
        GradientStop { position: 1; color: Qt.hsla((cover.hue + 0.08) % 1, 0.60, 0.28, 1) }
      }
      Text {
        visible: !cover.isMood
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: win.glyphOf(cover.item)
        color: Qt.rgba(1, 1, 1, 0.9)
        font.family: win.fontFamily
        font.pixelSize: Math.max(Style.font.title, Math.round(cover.height * 0.34))
      }
      // A mood (Chill, Focus …) is its name, big, like Apple Music's.
      Text {
        visible: cover.isMood
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Math.round(cover.width * 0.08)
        textFormat: Text.PlainText
        text: cover.item ? cover.item.title : ""
        color: "white"
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
        font.family: win.fontFamily
        font.bold: true
        font.pixelSize: Math.max(Style.font.title, Math.round(cover.width * 0.13))
      }
    }

    // A soft shadow under the cover (Now Playing): drawn from a plain shape
    // of the cover's size, under it.
    Rectangle {
      id: shadowShape
      anchors.fill: parent
      radius: cover.radius
      color: "black"
      visible: false
    }
    MultiEffect {
      anchors.fill: parent
      source: shadowShape
      visible: cover.shadow && cover.shown
      shadowEnabled: true
      shadowBlur: 0.8
      shadowOpacity: 0.5
      shadowVerticalOffset: Style.space(10)
    }

    // The cover itself, cropped square by clipping. Rounded corners come
    // from an effect on this item's own layer, which holds exactly what
    // it shows (an effect taking the image as its source would get the
    // whole, uncropped 16:9 thumbnail and stretch it).
    Item {
      id: imgBox
      anchors.fill: parent
      visible: cover.shown
      clip: true
      layer.enabled: cover.radius > 0
      layer.effect: MultiEffect {
        maskEnabled: true
        maskSource: mask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
      }
      SizedImage {
        id: img
        anchors.fill: parent
        crop: true
        url: cover.url
        onStatusChanged: if (status === Image.Error) cover.statusFailed()
      }
    }
    Rectangle {
      id: mask
      anchors.fill: parent
      radius: cover.radius
      visible: false
      layer.enabled: true
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: cover.clicked()
    }
  }

  // A list or song as a big square card with its name under it.
  component Card: Column {
    id: card
    property var item: null
    signal clicked()
    spacing: Style.space(8)
    Item {
      width: card.width
      height: card.width
      Cover {
        id: cardCover
        anchors.fill: parent
        radius: Style.cornerRadius * 2
        item: card.item
        url: win.coverOf(card.item)
        onClicked: card.clicked()
        scale: cardHover.hovered ? 1.03 : 1
        Behavior on scale { NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }
      }
      HoverHandler { id: cardHover }
      // A play button over the cover while hovered, like Apple Music's.
      Rectangle {
        visible: cardHover.hovered && card.item && card.item.kind !== "explore" && card.item.kind !== "mood"
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: Style.space(10)
        width: Style.space(40)
        height: width
        radius: width / 2
        color: win.accent
        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: Model.GLYPH.play
          color: win.bg
          font.family: win.fontFamily
          font.pixelSize: Style.font.title
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: card.clicked()
        }
      }
    }
    Txt {
      width: card.width
      visible: !(card.item && card.item.kind === "mood")
      text: card.item ? (card.item.kind === "list" || !card.item.kind ? win.p.playlistTitle(card.item) : card.item.title) : ""
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }
    Txt {
      width: card.width
      visible: text !== ""
      color: win.dim
      text: !card.item ? "" : (card.item.artist || card.item.subtitle || win.countText(card.item.count))
    }
  }

  // A titled row of cards that scrolls sideways.
  component Shelf: Column {
    id: shelf
    property string title: ""
    property string glyph: ""
    property color glyphColor: win.accent
    property var items: []
    property string from: ""
    visible: items && items.length > 0
    width: parent ? parent.width : 0
    spacing: Style.space(14)
    Row {
      spacing: Style.space(10)
      Txt {
        visible: shelf.glyph !== ""
        anchors.verticalCenter: parent.verticalCenter
        text: shelf.glyph
        color: shelf.glyphColor
        font.pixelSize: Style.font.display
      }
      Txt {
        anchors.verticalCenter: parent.verticalCenter
        text: shelf.title
        font.pixelSize: Style.font.display
        font.bold: true
      }
    }
    ListView {
      id: shelfList
      width: shelf.width
      height: win.cardSize + Style.space(64)
      orientation: ListView.Horizontal
      spacing: Style.space(20)
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      model: shelf.items ? shelf.items.slice(0, 40) : []
      ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }
      delegate: Card {
        required property var modelData
        width: win.cardSize
        item: modelData
        onClicked: win.activate(modelData, shelf.from)
      }
    }
  }

  // A song (or an Explore row) in a list: number or playing mark, cover,
  // names, album, length.
  component TrackRow: Item {
    id: row
    property var track: null
    property int number: 0
    property bool now: false
    property bool past: false
    property bool compact: false
    signal clicked()
    height: Style.space(compact ? 52 : 58)
    opacity: past ? 0.5 : 1

    readonly property bool isSong: !track || !track.kind || track.kind === "song"

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: row.now ? Qt.rgba(win.accent.r, win.accent.g, win.accent.b, 0.16)
        : rowMouse.containsMouse ? Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.07) : "transparent"
    }
    Txt {
      id: rowNumber
      visible: !row.compact
      x: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(32)
      horizontalAlignment: Text.AlignRight
      text: row.now ? (win.p.paused ? Model.GLYPH.pause : Model.GLYPH.play) : Commons.I18n.formatNumber(row.number)
      color: row.now ? win.accent : win.dim
      elide: Text.ElideNone
    }
    Cover {
      id: rowCover
      anchors.left: row.compact ? parent.left : rowNumber.right
      anchors.leftMargin: Style.space(row.compact ? 8 : 16)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(row.compact ? 40 : 44)
      height: width
      item: row.track
      url: win.coverOf(row.track)
      onClicked: row.clicked()
    }
    Column {
      anchors.left: rowCover.right
      anchors.leftMargin: Style.space(14)
      anchors.right: albumText.visible ? albumText.left : rowTime.left
      anchors.rightMargin: Style.space(16)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)
      Txt {
        width: parent.width
        text: row.track ? (row.track.kind === "list" ? win.p.playlistTitle(row.track) : row.track.title) : ""
        color: row.now ? win.accent : win.fg
        font.pixelSize: Style.font.subtitle
        font.bold: row.now
      }
      Txt {
        width: parent.width
        visible: text !== ""
        text: row.track ? (row.track.artist || row.track.subtitle || "") : ""
        color: win.dim
      }
    }
    Txt {
      id: albumText
      visible: !row.compact && row.width > Style.space(900) && text !== ""
      anchors.right: rowTime.left
      anchors.rightMargin: Style.space(24)
      anchors.verticalCenter: parent.verticalCenter
      width: row.width * 0.25
      text: row.track && row.track.album ? row.track.album : ""
      color: win.dim
    }
    Txt {
      id: rowTime
      anchors.right: parent.right
      anchors.rightMargin: Style.space(16)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(56)
      horizontalAlignment: Text.AlignRight
      color: win.dim
      elide: Text.ElideNone
      text: {
        var t = row.track
        if (!t) return ""
        if (t.kind === "mood" || t.kind === "list") return Model.GLYPH.forward
        return t.duration ? Model.formatTime(t.duration, Commons.I18n.formatNumber) : ""
      }
    }
    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: row.clicked()
    }
    // Like and radio for a YouTube song, over the row's time while hovered.
    Row {
      visible: rowMouse.containsMouse && row.isSong && row.track && Model.isYouTube(row.track.id) && !row.compact
      anchors.right: rowTime.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)
      PanelActionButton {
        readonly property bool liked: row.track !== null && win.p.isLiked(row.track.id)
        iconText: liked ? Model.GLYPH.heart : Model.GLYPH.heartOutline
        tooltipText: liked ? win.t("controls.unlike") : win.t("controls.like")
        foreground: liked ? win.accent : win.fg
        fontFamily: win.fontFamily
        onClicked: win.p.toggleLike(row.track)
      }
      PanelActionButton {
        iconText: Model.GLYPH.radio
        tooltipText: win.t("list.startRadio")
        foreground: win.fg
        fontFamily: win.fontFamily
        enabled: !win.p.radioBusy
        onClicked: { win.p.startRadio(row.track); win.listFrom = win.page === "list" ? win.listFrom : win.page; win.go("list") }
      }
    }
  }

  // A chord on the guitar: six strings (low E on the left), five frets, a
  // dot where each finger goes, o for an open string, × for one not played.
  component GuitarChord: Item {
    id: guitar
    property string chord: ""
    readonly property var diagram: Model.guitarDiagram(chord)
    visible: diagram !== null
    width: Style.space(150)
    height: Style.space(180)
    readonly property real padLeft: Style.space(30)
    readonly property real padTop: Style.space(26)
    readonly property real stringGap: (width - padLeft - Style.space(10)) / 5
    readonly property real fretGap: (height - padTop - Style.space(8)) / 5

    Txt {
      visible: guitar.diagram !== null && guitar.diagram.base > 1
      x: 0
      y: guitar.padTop + guitar.fretGap * 0.5 - height / 2
      text: guitar.diagram ? guitar.diagram.base + "fr" : ""
      color: win.dim
      font.pixelSize: Style.font.caption
    }
    Repeater {
      model: 6
      Rectangle {
        required property int index
        x: guitar.padLeft
        y: guitar.padTop + index * guitar.fretGap - (index === 0 && guitar.diagram && guitar.diagram.base === 1 ? 2 : 0)
        width: guitar.stringGap * 5
        height: index === 0 && guitar.diagram && guitar.diagram.base === 1 ? 5 : 1
        color: index === 0 ? win.fg : win.dim
      }
    }
    Repeater {
      model: 6
      Rectangle {
        required property int index
        x: guitar.padLeft + index * guitar.stringGap
        y: guitar.padTop
        width: 1.5
        height: guitar.fretGap * 5
        color: win.dim
      }
    }
    Repeater {
      model: guitar.diagram ? guitar.diagram.strings : []
      Item {
        required property var modelData
        required property int index
        x: guitar.padLeft + index * guitar.stringGap
        y: modelData > 0 ? guitar.padTop + (modelData - 0.5) * guitar.fretGap : guitar.padTop - Style.space(12)
        Rectangle {
          visible: modelData > 0
          anchors.centerIn: parent
          width: guitar.stringGap * 0.72
          height: width
          radius: width / 2
          color: win.accent
        }
        Rectangle {
          visible: modelData === 0
          anchors.centerIn: parent
          width: Style.space(11)
          height: width
          radius: width / 2
          color: "transparent"
          border.color: win.fg
          border.width: 1.5
        }
        Text {
          visible: modelData < 0
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: "×"
          color: win.dim
          font.family: win.fontFamily
          font.pixelSize: Style.font.subtitle
        }
      }
    }
  }

  // A chord on the keyboard: two octaves from C, its notes lit, from the root up.
  component PianoChord: Item {
    id: piano
    property string chord: ""
    readonly property var tones: Model.chordTones(chord)
    // Absolute keys (0-23) of the chord in root position.
    readonly property var lit: tones.length === 3
      ? [tones[0], tones[0] + ((tones[1] - tones[0] + 12) % 12), tones[0] + 7] : []
    readonly property var whites: [0, 2, 4, 5, 7, 9, 11]
    readonly property real keyWidth: width / 14
    height: Style.space(96)

    Repeater {
      model: 14
      Rectangle {
        required property int index
        readonly property int note: Math.floor(index / 7) * 12 + piano.whites[index % 7]
        x: index * piano.keyWidth
        width: piano.keyWidth - 2
        height: piano.height
        radius: 3
        color: piano.lit.indexOf(note) >= 0 ? win.accent : Qt.rgba(1, 1, 1, 0.88)
      }
    }
    Repeater {
      model: [1, 3, 6, 8, 10, 13, 15, 18, 20, 22]
      Rectangle {
        required property var modelData
        readonly property int white: Math.floor(modelData / 12) * 7 + [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6][modelData % 12]
        x: (white + 1) * piano.keyWidth - width / 2 - 1
        width: piano.keyWidth * 0.62
        height: piano.height * 0.6
        radius: 2
        color: piano.lit.indexOf(modelData) >= 0 ? Qt.darker(win.accent, 1.15) : "#151515"
      }
    }
  }

  // A glyph button for the transport, bigger than the panel's.
  component Transport: Item {
    id: tr
    property string glyph: ""
    property real size: Style.font.display
    property bool active: false
    property bool spinning: false
    signal clicked()
    width: size * 1.5
    height: size * 1.5
    opacity: enabled ? (trMouse.containsMouse ? 1 : 0.88) : 0.35
    Text {
      id: trGlyph
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: tr.glyph
      color: tr.active ? win.accent : win.fg
      font.family: win.fontFamily
      font.pixelSize: tr.size
      scale: trMouse.pressed ? 0.9 : 1
      RotationAnimation on rotation {
        id: trSpin
        from: 0
        to: 360
        duration: Style.duration(900)
        loops: Animation.Infinite
        running: tr.spinning && !Style.reduceMotion
      }
    }
    // A stopped spin leaves the glyph wherever it was: stand it up again.
    onSpinningChanged: if (!spinning) { trSpin.stop(); trGlyph.rotation = 0 }
    MouseArea {
      id: trMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tr.clicked()
    }
  }

  // A choice among several, as a pill (kinds of storage, rclone remotes).
  component Chip: Rectangle {
    id: chip
    property string label: ""
    property bool selected: false
    signal clicked()
    implicitWidth: chipText.implicitWidth + Style.space(32)
    implicitHeight: Style.space(38)
    radius: height / 2
    opacity: enabled ? 1 : 0.45
    color: selected ? win.accent
      : chipMouse.containsMouse ? Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.16) : Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.08)
    Text {
      id: chipText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: chip.label
      color: chip.selected ? win.bg : win.fg
      font.family: win.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: chip.selected
    }
    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked()
    }
  }

  // A labelled text field; Enter submits, Esc hands the keys back.
  component FormField: Column {
    id: field
    property string label: ""
    property bool secret: false
    property alias text: input.text
    signal edited(string value)
    signal submitted()
    spacing: Style.space(6)
    Txt {
      width: field.width
      text: field.label
      color: win.dim
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.1
    }
    BorderSurface {
      width: field.width
      implicitHeight: Style.space(44)
      radius: Style.cornerRadius
      color: Style.controlFill(input.activeFocus, false, win.fg, win.accent)
      borderSpec: Border.controlSpec(input.activeFocus ? "focus" : "normal", win.fg, win.accent)
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.IBeamCursor
        onClicked: input.forceActiveFocus()
      }
      TextInput {
        id: input
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Style.space(14)
        anchors.verticalCenter: parent.verticalCenter
        clip: true
        color: win.fg
        font.family: win.fontFamily
        font.pixelSize: Style.font.heading
        selectByMouse: true
        echoMode: field.secret ? TextInput.Password : TextInput.Normal
        onTextEdited: field.edited(text)
        Keys.onReturnPressed: function(event) { keys.forceActiveFocus(); field.submitted(); event.accepted = true }
        Keys.onEnterPressed: function(event) { keys.forceActiveFocus(); field.submitted(); event.accepted = true }
        Keys.onEscapePressed: function(event) { keys.forceActiveFocus(); event.accepted = true }
      }
    }
  }

  // A pill button with a glyph: filled in the accent for the main action.
  component BigButton: Rectangle {
    id: big
    property string glyph: ""
    property string label: ""
    property bool filled: false
    signal clicked()
    implicitWidth: bigRow.implicitWidth + Style.space(40)
    implicitHeight: Style.space(44)
    radius: height / 2
    opacity: enabled ? 1 : 0.4
    color: filled ? (bigMouse.containsMouse ? Qt.lighter(win.accent, 1.12) : win.accent)
      : (bigMouse.containsMouse ? Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.16) : Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.09))
    Row {
      id: bigRow
      anchors.centerIn: parent
      spacing: Style.space(8)
      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: big.glyph
        color: big.filled ? win.bg : win.fg
        font.family: win.fontFamily
        font.pixelSize: Style.font.title
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: big.label
        color: big.filled ? win.bg : win.fg
        font.family: win.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }
    }
    MouseArea {
      id: bigMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: big.clicked()
    }
  }
}
