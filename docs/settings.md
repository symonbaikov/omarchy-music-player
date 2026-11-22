# Settings

Most are on the panel's settings screen (the gear). All can be set with
`omarchy bar set`, or on the widget's entry in `~/.config/omarchy/shell.json`
(the bar picks up changes right away):

```bash
omarchy bar set io.github.symonbaikov.ytmusic-mpv browser brave
omarchy bar set io.github.symonbaikov.ytmusic-mpv playbackCookies On
```

| Key | Default | Meaning |
|---|---|---|
| `browser` | `chromium` | Where your YouTube login is read from: `chromium`, `brave`, `chrome`, `firefox`, `vivaldi`, `edge`, `opera`, a profile such as `brave:Profile 1`, or a Firefox-fork profile folder such as `firefox:~/.config/zen/<profile>`. Chromium-based browsers' keyring comes from their `--password-store` flag; add `+gnomekeyring` or `+kwallet6` to name it. `none`: public playlists only. |
| `playbackCookies` | `Off` | Also use the login when playing. Only if private uploads or members-only songs fail. Turning it off applies to a playing song from the next one on. |
| `showTitle` | `On` | The song's title next to the bar icon. |
| `defaultVolume` | `60` | Starting volume (0–100). |
| `showCovers` | `On` | Cover art. |
| `repeat` | `off` | `off`, `all` or `one`. The repeat button saves it. |
| `autoplay` | `On` | Keep playing recommended songs when the queue runs out. |
| `fadeIn` / `fadeOut` | `0` | Seconds each song fades in / out over. `0` is off. |
| `pauseFade` | `600` | Milliseconds a pause fades over, and playing again comes back over. `0` pauses at once. |
| `transition` | `Off` | `Peak mix`: switch songs climax to climax. |
| `crossfade` | `6` | How long the two climaxes overlap in a peak mix, 2–16 seconds. |
| `aiMix` | `Off` | `On`: your AI agent makes you a mix each day ([AI Mix](ai-mix.md)). |
| `tabs` | `yt,sp,sc,cl,rd,my` | The tabs shown (the `+` tab sets it). |
| `radioCountry` | (empty) | The Radio tab's country, e.g. `DE`. Empty: from your language setting. |
| `soundcloudUser` | (empty) | Your SoundCloud name or profile link (the SoundCloud tab sets it). |
| `spotifyClientId` | (empty) | Your Spotify app's Client ID (the Spotify tab sets it). |
| `downloadDir` | `~/Music` | Where downloads go. |
| `downloadFormat` | `mp3` | `mp3`, `m4a`, `opus`, `flac` or `wav`. |
| `downloadCover` | `On` | Embed the cover in downloads (MP3, M4A, FLAC) and show it in Downloads. |
| `updateCheck` | `On` | Check this plugin's repository for a newer version. |
| `backupMirrors` | `Off` | `On`: independent mirrors (Invidious, Piped) as the last resort for a song. |
| `mirrors` | (empty) | Your own mirrors, e.g. `invidious:https://inv.example.org piped:https://pipedapi.example.org`. Empty: from the public directories. |

```json
{ "id": "io.github.symonbaikov.ytmusic-mpv", "browser": "brave" }
```
