# Troubleshooting

The player's log is `~/.cache/io.github.symonbaikov.ytmusic-mpv/mpv.log`.
Most playback trouble is an old yt-dlp: `omarchy update`. When something
breaks, **Report the problem** in the panel files it for you.

- **"Couldn't load" or "Not signed in"**: you aren't signed in to YouTube
  Music in the configured browser, or `browser` points at the wrong profile.
  For a Chromium-based browser without a flags file, name the keyring, for
  example `chrome+gnomekeyring` or `chromium+kwallet6`. For a Flatpak
  browser, give its profile folder, for example
  `chromium:~/.var/app/org.chromium.Chromium/config/chromium/Default`. Test
  it from a terminal:
  ```bash
  ~/.config/omarchy/plugins/io.github.symonbaikov.ytmusic-mpv/bin/ytmusic-mpv \
    playlists --browser chromium --max-age 0
  ```
  Sign-in problems show a **Sign in** button: it opens YouTube's sign-in in
  the browser the login is read from.
- **Like or add-to-playlist failed**: the panel shows YouTube's reason;
  `~/.cache/io.github.symonbaikov.ytmusic-mpv/api.log` has the details.
- **A song is skipped**: the panel says which and why. If your account can
  play it, **Play with my account** turns `playbackCookies` on and plays it
  again.
- **The music pauses for a moment when you switch the keyboard layout**:
  Omarchy's push-to-talk dictation is on Right Alt, which `Alt+Alt` also
  presses, and the dictation tool pauses music while it records. Give the
  key back to the layout switch in `~/.config/hypr/bindings.lua`:
  `hl.unbind("ALT + Alt_R")` (dictation stays on `Alt+Space`). Or set
  `pause_media = false` in `~/.config/voxtype/config.toml`.
- **The sound drops out for a moment** under load: the player keeps 100 ms
  of sound in PipeWire's buffer. A player started by an older version has
  the small one: start any playlist again.
- **Peak mix doesn't switch**: a song needs a minute or so to have a climax
  to leave from, and the next song is prepared as the current one starts.
  `mpv.log` has a "peak mix" line per song saying why when one is skipped.
- **Which mirrors work from here**:
  ```bash
  ~/.config/omarchy/plugins/io.github.symonbaikov.ytmusic-mpv/bin/ytmusic-mpv mirrors --check
  ```
- **A storage, server or radio station won't open**: the panel shows the
  reason. A storage's listing is kept for 6 hours: refresh to read new files.
- **No chords in Notes**: install `python-numpy` (the view offers it).
- **AI Mix: "Listen to a few more songs first"**: it needs some history or
  likes; it gets better the more you listen.
