# Omarchy Music Player

An Omarchy shell plugin: a music player in the bar (QML panel and window), a
Python helper (`bin/ytmusic-mpv`) and a Lua script in a headless mpv. The
plugin ID `io.github.symonbaikov.ytmusic-mpv` is permanent; never rename it.

## Read the docs before you change a part

Start with [docs/architecture.md](docs/architecture.md) for any non-trivial
change. Then the doc for the part you touch:

| You're working on | Read first |
|---|---|
| A service: YouTube, Spotify, SoundCloud, Files (local, rclone storage, Navidrome/Jellyfin/Plex), Radio, My Music | [docs/services.md](docs/services.md) |
| `PlayerWindow.qml`, Lyrics, Notes (chords, scores) | [docs/player-window.md](docs/player-window.md) |
| Listening history, taste, `ai-mix` | [docs/ai-mix.md](docs/ai-mix.md) |
| `mpv/ytmusic.lua`, fades, Peak mix, backup sources, downloads, updates | [docs/playback.md](docs/playback.md) |
| Keys, IPC functions (`ShellIpc` in Panel.qml) | [docs/usage.md](docs/usage.md) |
| A setting (`manifest.json` defaults / schema) | [docs/settings.md](docs/settings.md) |
| Anything that sends, stores or logs data | [docs/privacy.md](docs/privacy.md) |
| CI, watchdog, release | [docs/maintenance.md](docs/maintenance.md) |

**Keep the docs true.** A change in behavior updates its doc in the same
commit: a new setting goes into `docs/settings.md`, a new IPC function into
`docs/usage.md`, new network traffic or stored data into `docs/privacy.md`.
The README stays short: only the headline features and links into `docs/`.

## Rules

- **Privacy first.** No secrets on command lines (stdin or env instead), data
  files owner-only in `DATA_DIR`, every new ID or credential masked in
  `redact()` for problem reports. The marketplace review checks that turning
  a privacy setting off also takes effect in a running player.
- **Validate everything from outside**: IDs by regex (`TRACK_KEY_RE`,
  `PLAYLIST_ID_RE` in Model.js and their twins in the helper), titles shown
  as plain text, covers only from allowed hosts (`REMOTE_COVER_RE`).
- **UI strings** go into `i18n/en.json`, used as `strings.t("key")`.
- **Logic that can be pure goes into `Model.js`** and gets a node test.
- No new Python dependencies; optional tools (rclone, numpy) are offered to
  install from the UI when missing.
- `main` takes pull requests only. Bump `version` in `manifest.json` for a
  release.

## Test

```bash
node --test tests/*.test.mjs
python3 -I -m unittest discover -s tests -p 'test_*.py'
luac -p mpv/ytmusic.lua
omarchy plugin validate .
```

Then load it for real: `omarchy restart shell`, and prove the widget loaded
with an IPC call (`omarchy-shell io.github.symonbaikov.ytmusic-mpv
openSettings`). "Target not found" means the QML failed to load; the error
is in `quickshell log --pid $(pgrep -f "quickshell -n -p /usr/share/omarchy/shell")`.

**Never touch the user's running player in tests.** Don't run `play`,
`stop` or `playPause` against the real runtime dir. Use throwaway dirs:
`XDG_RUNTIME_DIR=$(mktemp -d /tmp/ytc-XXXX)` (a socket path must stay under
108 bytes), plus `XDG_CACHE_HOME` / `XDG_DATA_HOME`, and mpv with `--ao=null`.

## QML traps that broke loading before

- `Model.js` (`.pragma library`) is cached for the life of the shell: only
  `omarchy restart shell` reloads it. New `ShellIpc` functions need a
  restart too.
- Qt's V4 engine lacks newer JS built-ins (`trimEnd` …); the node tests
  delete them to catch their use.
- An inline component's `id` must not shadow a JS global (`gc`); `left` /
  `top` are FINAL on Item; pointer handlers have no default property
  (declare animations as `property NumberAnimation x: NumberAnimation {}`).
- Root functions can't reach ids inside the `KeyboardPanel` `content`
  component; pass refs up in `Component.onCompleted`.
- Never set `connected = false` on a `Socket` inside its `onError`: it
  crashes the whole shell.
- An `Image`/`SizedImage` with crop paints outside its bounds; give effects a
  clipped `layer.enabled` item, not the image, or the picture stretches.
- A `FloatingWindow` closed by the compositor can't be shown again: keep it
  in a `LazyLoader`.
