# YouTube Music (mpv) for Omarchy

![YouTube Music (mpv) panel](preview.png)

An Omarchy bar widget that lists your **YouTube Music playlists** and plays them
through a headless `mpv`. You don't need a browser window, browser extension or
web app open while it plays.

- `yt-dlp` reads your library (your playlists plus Liked Music) and each
  playlist's tracks. To see your private library it reads your browser's
  saved YouTube login cookies from disk. The browser doesn't have to be
  running.
- `mpv --no-video` plays a queue built from the playlist. With `mpv-mpris`
  installed it shows up on MPRIS, so media keys and Omarchy's OSD control it.
- The widget follows playback live over mpv's JSON IPC socket.

## Requirements

- Omarchy (Quattro shell)
- `python3`, `yt-dlp`, `mpv`
- Optional: `mpv-mpris` (media keys and the OSD)
- A browser signed in to YouTube Music (Chromium, Brave, Chrome, Firefox,
  Zen, Vivaldi, Edge or Opera) to read your private library. Public playlists
  work without one.

```bash
omarchy pkg add yt-dlp mpv mpv-mpris
```

## Install

```bash
omarchy plugin add https://github.com/symonbaikov/omarchy-ytmusic-mpv --enable
```

Then set the browser you're signed in with: see [Settings](#settings).

## Remove

```bash
omarchy plugin remove io.github.symonbaikov.ytmusic-mpv
```

Removal doesn't touch the cached lists. Delete them yourself if you like:
`~/.cache/io.github.symonbaikov.ytmusic-mpv/`.

## Use

| On the bar | Does |
|---|---|
| Click | Open the panel |
| Right-click | Play / pause |
| Middle-click | Next track |
| Scroll | Volume ±5 |

In the panel: `j`/`k` move, `Enter` opens a playlist or plays a track,
`h`/`Backspace` goes back, `p` play/pause, `n` next, `b` previous,
`s` shuffle the open playlist, `r` refresh, `+`/`-` volume, `Esc` closes.

IPC, for Hyprland key bindings:

```bash
omarchy-shell io.github.symonbaikov.ytmusic-mpv toggle      # open/close the panel
omarchy-shell io.github.symonbaikov.ytmusic-mpv playPause   # also: next, previous, stop
```

## Settings

Edit them in Omarchy's bar settings, or on the widget's entry in
`~/.config/omarchy/shell.json`:

| Key | Default | Meaning |
|---|---|---|
| `browser` | `chromium` | yt-dlp `--cookies-from-browser` value: `chromium`, `brave`, `chrome`, `firefox`, `vivaldi`, `edge`, `opera`, a profile such as `brave:Profile 1`, or a Firefox-fork profile folder such as `firefox:~/.config/zen/<profile>`. `none` means public playlists only. |
| `playbackCookies` | `Off` | Also send cookies when playing. Turn it on only if private uploads fail to play. |
| `showTitle` | `On` | Show the current track title next to the icon. |
| `defaultVolume` | `60` | Starting volume (0–100). |

```json
{ "id": "io.github.symonbaikov.ytmusic-mpv", "browser": "brave" }
```

## Privacy and network use

- The cookies never leave your machine except to YouTube. yt-dlp uses them
  to request your library from `youtube.com`, and the plugin never stores or
  logs them.
- The plugin contacts YouTube only when you open the panel and a cached list
  is older than one hour, when you press refresh, or while it plays. It has
  no background polling.
- Lists are cached in `~/.cache/io.github.symonbaikov.ytmusic-mpv/`. The mpv
  socket and the current queue live in
  `$XDG_RUNTIME_DIR/io.github.symonbaikov.ytmusic-mpv/`.
- All titles from YouTube are shown as plain text. IDs, sizes and lengths are
  validated before use.

## Troubleshooting

- **"Couldn't load"**: you aren't signed in to YouTube Music in the
  configured browser, or `browser` points at the wrong profile. Test it from
  a terminal:
  ```bash
  ~/.config/omarchy/plugins/io.github.symonbaikov.ytmusic-mpv/bin/ytmusic-mpv \
    playlists --browser chromium --max-age 0
  ```
- **A track won't play**: check `~/.cache/io.github.symonbaikov.ytmusic-mpv/mpv.log`,
  and keep `yt-dlp` up to date (`omarchy update`).

## Development

```bash
node --test tests/
omarchy plugin validate .
```

`bin/ytmusic-mpv` is also a small CLI: `playlists`, `tracks <id>`,
`play <id> [--index N] [--shuffle 1]` and `stop`. Each prints JSON lines.

## License

[MIT](LICENSE) © 2026 Symon Baikov
