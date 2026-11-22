import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The whole player on the whole screen, like Apple Music's window: a
// sidebar with every service and your mixes, big covers in the middle, the
// player along the bottom, and a "Now Playing" view with the song's cover
// blurred behind it and what's up next. Everything comes from the panel
// (`p`, Panel.qml): its lists, its player and its actions, so the panel and
// this view always agree.
OverlayWindow {
  id: win
  required property var p

  // "home" | "library" (the panel's current service) | "list" (an open
  // playlist) | "browse" (Explore and search) | "nowplaying"
  property string page: "home"
  property string listFrom: "home"
  property string pageBeforeNow: "home"

  shown: p.fullOpen
  WlrLayershell.namespace: "omarchy-music-player"

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

  function serviceLabel(id) { return t("tab." + id) }

  onShownChanged: {
    if (!shown) return
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
    p.closeFull()
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
      if (item.id === "__cloudadd") p.openCloudForm()
      else showBrowse()
      return
    }
    listFrom = page === "list" ? listFrom : page
    p.openList(item)
    go("list")
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
      else if (event.text === "F") { win.p.closeFull(); event.accepted = true }
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
          Txt {
            id: appTitle
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: Model.GLYPH.music + "  " + win.t("full.appName")
            font.pixelSize: Style.font.display
            font.bold: true
          }
          PanelActionButton {
            id: exitButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: Model.GLYPH.fullscreenExit
            // As big as the title beside it: the way out should be easy to see.
            fontSize: Style.font.display
            tooltipText: win.t("full.close")
            foreground: win.fg
            fontFamily: win.fontFamily
            onClicked: win.p.closeFull()
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
            onAccepted: { win.search(text); keys.forceActiveFocus() }
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
            onClicked: win.p.openCloudForm()
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

        // Not connected yet: the panel has the form.
        Column {
          visible: win.p.service !== "yt" && win.p.svc[win.p.service].setup !== ""
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
            glyph: win.p.service === "cl" ? Model.GLYPH.cloud : Model.GLYPH.login
            label: win.t("full.connect").arg(win.serviceLabel(win.p.service))
            filled: true
            onClicked: {
              if (win.p.service === "cl") { win.p.openCloudForm(); return }
              var name = win.p.service
              win.p.closeFull()
              win.p.open()
              win.p.switchService(name)
            }
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
            var error = s === "yt" ? win.p.playlistsError : win.p.svc[s].error
            if (error !== "") return win.t("error.prefix").arg(error)
            if (win.libraryCards.length > 0) return ""
            var loading = s === "yt" ? win.p.playlistsLoading : win.p.svc[s].loading
            return loading ? win.t("list.loading") : win.t("list.emptyPlaylists")
          }
        }

        GridView {
          id: grid
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

      readonly property real artSize: Math.min(height * 0.62, width * 0.36)

      Column {
        id: nowLeft
        anchors.verticalCenter: parent.verticalCenter
        x: Math.max(win.gutter * 2, (parent.width * 0.55 - width) / 2)
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

      // Up next: the queue from the playing song on.
      Column {
        anchors.left: parent.left
        anchors.leftMargin: parent.width * 0.58
        anchors.right: parent.right
        anchors.rightMargin: win.gutter * 2
        anchors.top: parent.top
        anchors.topMargin: win.gutter * 2
        anchors.bottom: parent.bottom
        anchors.bottomMargin: win.gutter
        spacing: Style.space(12)

        Txt {
          id: upNextTitle
          text: win.t("full.upNext")
          font.pixelSize: Style.font.display
          font.bold: true
        }
        Txt {
          visible: win.p.session !== null && win.p.session.playlistTitle !== ""
          width: parent.width
          text: win.p.session ? win.t("full.playingFrom").arg(win.p.session.playlistTitle) : ""
          color: win.dim
        }
        ListView {
          id: queueView
          width: parent.width
          height: parent.height - upNextTitle.height - Style.space(40)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          spacing: Style.space(2)
          // The playing song first, then what comes after it.
          readonly property int from: Math.max(0, win.p.playlistPos)
          onFromChanged: positionViewAtBeginning()
          onVisibleChanged: if (visible) positionViewAtBeginning()
          model: win.page === "nowplaying" ? win.queue.slice(from) : []
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
          iconText: Model.GLYPH.queue
          fontSize: Style.font.title
          tooltipText: win.t("full.upNext")
          foreground: win.page === "nowplaying" ? win.accent : win.fg
          fontFamily: win.fontFamily
          enabled: win.p.connected
          onClicked: win.go(win.page === "nowplaying" ? win.pageBeforeNow : "nowplaying")
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
          iconText: Model.GLYPH.fullscreenExit
          fontSize: Style.font.display
          tooltipText: win.t("full.close")
          foreground: win.fg
          fontFamily: win.fontFamily
          onClicked: win.p.closeFull()
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

    // Drawn through the effect below, with rounded corners.
    SizedImage {
      id: img
      anchors.fill: parent
      crop: true
      url: cover.url
      visible: false
      onStatusChanged: if (status === Image.Error) cover.statusFailed()
    }
    Rectangle {
      id: mask
      anchors.fill: parent
      radius: cover.radius
      visible: false
      layer.enabled: true
    }
    MultiEffect {
      anchors.fill: parent
      source: img
      visible: cover.shown
      maskEnabled: true
      maskSource: mask
      maskThresholdMin: 0.5
      maskSpreadAtMin: 1.0
      shadowEnabled: cover.shadow
      shadowBlur: 0.8
      shadowOpacity: 0.5
      shadowVerticalOffset: Style.space(10)
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
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: tr.glyph
      color: tr.active ? win.accent : win.fg
      font.family: win.fontFamily
      font.pixelSize: tr.size
      scale: trMouse.pressed ? 0.9 : 1
      RotationAnimation on rotation {
        from: 0
        to: 360
        duration: Style.duration(900)
        loops: Animation.Infinite
        running: tr.spinning && !Style.reduceMotion
        onRunningChanged: if (!running) parent.rotation = 0
      }
    }
    MouseArea {
      id: trMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tr.clicked()
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
