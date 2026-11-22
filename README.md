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
- **Like** songs (the heart adds them to Liked Music) and **add them to any
  of your playlists**, like in YouTube Music. The add-to-playlist list comes
  from YouTube Music's own dialog: only playlists you created (YouTube
  doesn't let anyone add to playlists they only saved), with a ✓ where the
  song already is.
- Cover art for the playing song and for every track in the list.
- Apple Music-style repeat: off, repeat the playlist, or repeat one song.
- Recommendations, the YouTube Music way. These are YouTube Music's own
  recommendations, personalized to your account when cookies are used:
  - **Start radio** from any song: a queue of similar songs. Starting it from
    the song that's playing doesn't interrupt it; the radio follows it.
  - **Autoplay**: when the queue runs out (with repeat off), it keeps going
    with songs recommended for the last one, endlessly.
  - **My Supermix** pinned at the top of your playlists.

## Requirements

- Omarchy (Quattro shell)
- `python3`, `yt-dlp`, `mpv`
- Optional: `mpv-mpris` (media keys and the OSD)
- A browser signed in to YouTube Music (Chromium, Brave, Chrome, Firefox,
  Zen, Vivaldi, Edge or Opera) to read your private library. Public playlists
  work without one. The browser doesn't have to be running.
- Chromium-based browsers encrypt their cookies with a key kept in GNOME
  Keyring or KWallet. The plugin reads which one from the browser's
  `--password-store` flag (`~/.config/chromium-flags.conf`,
  `brave-flags.conf`, …), so Omarchy's Chromium and Brave work as they come.
  The keyring has to be unlocked, which it is after a normal login.

Install the packages with Omarchy's package installer if you don't have them.

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
`s` shuffle the open playlist, `Shift+R` cycle repeat, `m` start radio,
`f` like / remove like, `a` add to a playlist (all three act on the
highlighted track, or the playing one), `r` refresh, `+`/`-` volume, `Esc`
closes. Hovering a track shows like, add-to-playlist and radio buttons;
liked tracks keep a small heart.

The repeat button (next to stop) cycles like Apple Music: off (dim) →
repeat the playlist (highlighted) → repeat one song (highlighted, "1") →
off. You can set it before anything plays, and it is remembered.

IPC, for Hyprland key bindings:

```bash
omarchy-shell io.github.symonbaikov.ytmusic-mpv toggle      # open/close the panel
omarchy-shell io.github.symonbaikov.ytmusic-mpv playPause   # also: next, previous, stop
omarchy-shell io.github.symonbaikov.ytmusic-mpv cycleRepeat # off -> all -> one
omarchy-shell io.github.symonbaikov.ytmusic-mpv startRadio  # radio from the playing song
omarchy-shell io.github.symonbaikov.ytmusic-mpv toggleLike  # like the playing song
omarchy-shell io.github.symonbaikov.ytmusic-mpv addToPlaylist # pick a playlist for it
```

## Settings

Edit them in Omarchy's bar settings, or on the widget's entry in
`~/.config/omarchy/shell.json`:

| Key | Default | Meaning |
|---|---|---|
| `browser` | `chromium` | yt-dlp `--cookies-from-browser` value: `chromium`, `brave`, `chrome`, `firefox`, `vivaldi`, `edge`, `opera`, a profile such as `brave:Profile 1`, or a Firefox-fork profile folder such as `firefox:~/.config/zen/<profile>`. `none` means public playlists only. |
| `playbackCookies` | `Off` | Also send cookies when playing. Turn it on only if private uploads fail to play. Turning it off, or setting `browser` to `none`, applies to a song that's already playing from the next track on. |
| `showTitle` | `On` | Show the current track title next to the icon. |
| `defaultVolume` | `60` | Starting volume (0–100). |
| `showCovers` | `On` | Show cover art. |
| `repeat` | `off` | `off`, `all` or `one`. The repeat button saves it here. |
| `autoplay` | `On` | Keep playing recommended songs when the queue runs out (repeat off). |

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
- Liking a song and adding it to a playlist are the only requests that change
  your account, and they happen only when you press the heart or pick a
  playlist. They go to YouTube Music's own web API at
  `https://music.youtube.com/youtubei/v1/`, signed with your cookies exactly
  as music.youtube.com signs them (yt-dlp is read-only, so the helper makes
  these two requests itself). Nothing else is sent, and the cookies are never
  written to disk or logged.
- With `playbackCookies` on, the player passes the cookies to yt-dlp for
  each track it opens. Turning the setting off, or setting `browser` to
  `none`, takes the cookies away from the running player too: tracks it
  opens after that don't use them. If the plugin can't confirm the change,
  it stops the player.
- Radio, autoplay and My Supermix are read from YouTube Music with the same
  cookies as your library, so they're personalized like in the app. Autoplay
  makes one request when the last song in the queue starts, and only then.
- Cover art is YouTube's own track thumbnail from `https://i.ytimg.com`. The
  URL is built only from a validated video ID. It is fetched for the playing
  song and for the list rows on screen, and never with your cookies. Turn it
  off with `showCovers: Off`.
- Lists are cached in `~/.cache/io.github.symonbaikov.ytmusic-mpv/`. The mpv
  socket and the current queue live in
  `$XDG_RUNTIME_DIR/io.github.symonbaikov.ytmusic-mpv/`.
- All titles from YouTube are shown as plain text. IDs, sizes and lengths are
  validated before use.

## Troubleshooting

- **"Couldn't load"** or **"Not signed in"**: you aren't signed in to YouTube
  Music in the configured browser, or `browser` points at the wrong profile.
  For a Chromium-based browser without a flags file, name the keyring
  yourself, for example `chrome+gnomekeyring` or `chromium+kwallet6`. For a
  Flatpak browser, give its profile folder, for example
  `chromium:~/.var/app/org.chromium.Chromium/config/chromium/Default`. Test
  it from a terminal:
  ```bash
  ~/.config/omarchy/plugins/io.github.symonbaikov.ytmusic-mpv/bin/ytmusic-mpv \
    playlists --browser chromium --max-age 0
  ```
- **Sign-in problems** show a **Sign in** button. It opens YouTube's sign-in
  page in the browser the cookies are read from (Zen, LibreWolf and so on are
  recognized by their profile folder).
- **Like or add-to-playlist failed**: the panel shows YouTube's own reason.
  `~/.cache/io.github.symonbaikov.ytmusic-mpv/api.log` has the endpoint, HTTP
  code and YouTube's status for each failure, and never headers or cookies.
- **A track won't play**: check `~/.cache/io.github.symonbaikov.ytmusic-mpv/mpv.log`,
  and keep `yt-dlp` up to date (`omarchy update`).

## Development

```bash
node --test tests/
python3 -I -m unittest discover -s tests -p 'test_*.py'
omarchy plugin validate .
```

`bin/ytmusic-mpv` is also a small CLI: `playlists`, `tracks <id>`,
`play <id> [--index N] [--shuffle 1]`,
`radio <video-id> [--mode replace|keep|append]`, `like <video-id> [--remove 1]`,
`add <playlist-id> <video-id>`, `liked` and `stop`. Each prints JSON lines.

## License

[MIT](LICENSE) © 2026 Symon Baikov
