# Architecture

An Omarchy shell (Quickshell) bar widget, a Python helper and a Lua script
inside a headless mpv. No build step, no third-party Python packages
(numpy only for chords, optional).

```
 bar widget ──► Panel.qml ──────────────┐  QML (Quickshell, Qt 6)
    │            │  FullView.qml          │  Model.js: pure logic, tested in node
    │            │   └─ PlayerWindow.qml  │
    │            │                        │
    │   Process: python3 -I bin/ytmusic-mpv <cmd> …  → JSON lines on stdout
    │            │
    │   Socket: mpv JSON IPC ($XDG_RUNTIME_DIR/<id>/mpv.sock)
    ▼            ▼
  mpv --no-video  +  mpv/ytmusic.lua  ──► helper again (fallback, mixprep,
                                            history-add, cloud-stop)
```

## Files

| File | What it is |
|---|---|
| `manifest.json` | Plugin manifest: id, version (bump it to release), bar widget defaults and the settings schema |
| `Panel.qml` | The bar widget and its keyboard panel: every view (lists, search, settings, download, cloud form, AI Mix …), all state, helper processes, the mpv socket, IPC (`ShellIpc` functions) |
| `FullView.qml` | A `LazyLoader` around the player window plus forwarding functions, so the window is created fresh each time it opens |
| `PlayerWindow.qml` | The Apple-Music-like window (`FloatingWindow`): sidebar, home, lists, Now Playing with Lyrics / Notes / Up Next. Reads and drives everything through `p` (the panel root) |
| `Model.js` | `.pragma library`: parsing and sanitizing helper output, IDs and regexes, service and storage kinds, chord theory, glyphs. No QML imports |
| `bin/ytmusic-mpv` | The helper: one Python file, a CLI with a subcommand per action (`main()` → `handlers`) |
| `mpv/ytmusic.lua` | Loaded into the plugin's own mpv: custom URL schemes, fades, pause fade, Peak mix, backup sources, history |
| `i18n/en.json` | Every UI string. Use `strings.t("key")` in QML (`p.i18n.t` in the window); never hard-code text |
| `tools/watchdog.py` | Scheduled end-to-end playback check (CI) |
| `tests/` | `model.test.mjs` (node, Model.js) and `test_helper.py` (unittest, the helper with fake servers and stub binaries) |

## The helper

`python3 -I bin/ytmusic-mpv <command> [args]` prints one JSON object per
line. The panel runs it with `Process` and parses lines in `Model.js`.
Commands: `playlists`, `tracks`, `play`, `radio`, `search`, `explore`,
`mood`, `like`, `add`, `download`, `lyrics`, `chords`, `scores`, `cloud*`,
`radio-*`, `mix-*`, `history-add`, `taste`, `ai-mix`, `report`, … (the
`handlers` table in `main()`, and the docstring at the top).

- **Paths**: `CACHE_DIR` (`~/.cache/<id>`: lists, covers, mix audio,
  lyrics, chords), `DATA_DIR` (`~/.local/share/<id>`, owner-only: tokens,
  `mixes.json`, `cloud.json`, `servers.json`, `radio.json`,
  `history.jsonl`, `ai-mix.json`), `RUNTIME_DIR` (socket, `session.json`,
  queue, pid, the cloud server's state).
- **Playing**: `play` builds a queue (`queue.m3u`) and `session.json`
  (the tracks with titles, for the panel and history), then starts mpv
  (`start_player`) with the Lua script and settings as `--script-opts`.
  One player at a time; a new list replaces it.
- **Track keys and list IDs** are validated by regex on both sides
  (`TRACK_KEY_RE`, `PLAYLIST_ID_RE` in Model.js; the same in the helper):
  - YouTube: an 11-character video ID; playlists by their own IDs.
  - `sp:<id>` Spotify (played from the YouTube match), `sc:…` SoundCloud.
  - `cl:<8 hex>/<16 hex>` a file in a storage or local folder; lists `cl:<8>` and `cl:<8>:<16>`.
  - `ms:<8>/<id>` a media server song; lists `ms:<8>:fav|rnd|al:<id>|pl:<id>`.
  - `rd:<uuid>` a radio station; lists `rd:fav|top|vote|search|country:XX|tag:<x>`.
  - `mix:<8 hex>` your mixes, `mix:all` My Mix, `ai:mix`, `hist:recent`, `DOWNLOADS`.
- **Custom schemes**: non-YouTube songs go into the queue as
  `ytmusic-spotify://`, `ytmusic-cloud://`, `ytmusic-radio://`,
  `ytmusic-server://` URLs. The Lua `on_load` hook asks the helper
  (`resolve`) for the real stream and checks it (`resolved_ok`) before mpv
  opens it.
- **Secrets** never go on a command line: forms come on stdin, rclone gets
  credentials through environment variables, passwords are obscured or
  exchanged for tokens.
- **Problem reports** (`report`) go through `redact()`; any new kind of
  URL, ID or credential must be masked there.

## The mpv script

- Settings arrive as `--script-opts=ytmusic-<key>=<value>`, and later as
  `script-message ytmusic-set <key> <value>`.
- Results for the panel go to `user-data/ytmusic/*` (observed over IPC; the
  list is `OBSERVED` in Model.js).
- Fades use `volume-gain` (dB), never the user's `volume`. Pause fade:
  `script-message ytmusic-toggle-pause`; the panel checks
  `user-data/ytmusic/features` before using it.
- Peak mix: `mixprep` renders the transition with ffmpeg; the script swaps
  it in as the next entry and cuts the playing song with
  `file-local-options/end`.
- Backup sources: the `on_load_fail` hook asks `fallback`.
- History: `end-file` → `note_play` → a **detached** `history-add`
  subprocess (it must outlive mpv, which quits when a new list starts).

## The panel and the window

- `Panel.qml` is the single source of state. `PlayerWindow.qml` reads
  `p.<property>` and calls `p.<function>()`; it doesn't run helpers itself.
- The window is an xdg toplevel (`FloatingWindow`) inside a `LazyLoader`
  keyed on `fullOpen`: a window closed by the compositor (`Super+W`) can't
  be shown again, so each opening makes a new one.
- Views inside the `KeyboardPanel` `content` component can't be reached by
  id from root functions. Refs (`searchInput`, `cloudPathInput`, …) are
  handed to the root in `Component.onCompleted`.
- Text fields stop `Enter` from reaching the panel's key catcher with
  `Keys.onReturnPressed` / `Keys.onEnterPressed` and `event.accepted = true`.
- Settings are the widget's entry in `~/.config/omarchy/shell.json`; the
  panel saves its own with `bar.shell.updateEntryInline`. Every monitor has
  its own widget instance; peers are told through `bar.moduleWidgets()`.

## Release

Bump `version` in `manifest.json`; on `main`, the release workflow tags it
and asks the marketplace to verify the commit. `main` takes pull requests
only. See [maintenance](maintenance.md).
