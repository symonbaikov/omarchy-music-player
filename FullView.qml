import QtQuick
import Quickshell

// The player window (PlayerWindow.qml), made each time it opens and let go
// when it closes: a window the compositor closed can't be shown again, so a
// fresh one opens every time. Pages asked for before it exists are opened
// as soon as it does.
Scope {
  id: host
  required property var p

  property var pending: null

  function withWindow(fn) {
    if (loader.item) fn(loader.item)
    else pending = fn
  }
  function go(page) { withWindow(function(w) { w.go(page) }) }
  function showService(id) { withWindow(function(w) { w.showService(id) }) }
  function showBrowse() { withWindow(function(w) { w.showBrowse() }) }
  function addStorage() { withWindow(function(w) { w.addStorage() }) }
  function showLyrics() { withWindow(function(w) { w.side = "lyrics"; w.go("nowplaying") }) }
  function showNotes() { withWindow(function(w) { w.side = "notes"; w.go("nowplaying") }) }

  LazyLoader {
    id: loader
    active: host.p.fullOpen
    onItemChanged: {
      if (!item) { host.pending = null; return }
      var fn = host.pending
      host.pending = null
      if (fn) Qt.callLater(function() { if (loader.item) fn(loader.item) })
    }

    PlayerWindow { p: host.p }
  }
}
