# Privacy and network use

Your data lives in `~/.local/share/io.github.symonbaikov.ytmusic-mpv/`
(owner-only: tokens, mixes, favorites, history), caches in
`~/.cache/io.github.symonbaikov.ytmusic-mpv/`, and the player's socket and
queue in `$XDG_RUNTIME_DIR/io.github.symonbaikov.ytmusic-mpv/`. Titles from
any service are shown as plain text; IDs, sizes and lengths are validated
before use.

## YouTube Music

- Your login (browser cookies) never leaves your machine except to YouTube.
  yt-dlp uses it to read your library; the plugin never stores or logs it.
- YouTube is contacted when you open the panel and a saved list is older
  than an hour, when you refresh, or while it plays. No background polling.
- Liking a song and adding it to a playlist are the only requests that
  change your account, and only when you press the heart or pick a
  playlist. They go to YouTube Music's own web API, signed exactly as
  music.youtube.com signs them (`api.log` keeps failures, never headers or
  cookies).
- With `playbackCookies` on, the player passes the login to yt-dlp for each
  song it opens. Turning it off (or `browser: none`) takes it away from the
  running player too; if that can't be confirmed, the player stops.
- Radio, autoplay and My Supermix use the same login, so they're
  personalized. Autoplay makes one request, when the last song starts.
- Explore and search use YouTube Music's web API without an account: no
  cookies, the same results as anyone in your region. Cached for 6 hours.
- Covers come from `https://i.ytimg.com` by validated ID, never with your
  login (`showCovers: Off` turns them off).

## Other services

- **Spotify**: Spotify's Authorization Code flow with PKCE, answered on a
  one-shot server on `127.0.0.1`. Tokens owner-only in `spotify.json`, sent
  only to `accounts.spotify.com` and `api.spotify.com`. Songs are matched on
  YouTube Music without an account; matches are cached. Disconnect in
  settings.
- **SoundCloud**: read by yt-dlp with the same browser login as YouTube.
  Album art from Spotify's and SoundCloud's image hosts.
- **Music servers**: only your server (and plex.tv for Plex's sign-in and to
  find your server). Never the password: Subsonic keeps a salted token,
  Jellyfin and Plex the token they hand out, owner-only in `servers.json`,
  deleted with the server.
- **Cloud storage**: only through rclone, only the storage you connected. A
  new storage's settings go into rclone's own config (passwords obscured as
  rclone stores them), passed to the helper over stdin, never on a command
  line. Songs reach mpv through `rclone serve http` on `127.0.0.1`:
  read-only, a random user and password each run (in the environment, kept
  owner-only), stopped with the player.
- **Radio**: Radio Browser's servers (`*.api.radio-browser.info`) for lists
  and search; they count a listen when a station plays. Station logos are
  fetched once by the helper and cached; the stream comes from the station.
  Favorites in `radio.json`.

## Features

- **Lyrics**: only while the Lyrics view is open: the song's title, artist
  and length to `lrclib.net`, or its ID to YouTube Music without an account.
  Cached.
- **Notes**: chords are worked out on your machine from the song's audio.
  Only while Notes is open, the title and artist go to `songsterr.com`; the
  MuseScore and Ultimate Guitar buttons only open their search in your
  browser.
- **Listening history** stays in `history.jsonl`. With **AI Mix** on, a
  summary (top artists and songs, likes, skipped artists, your mood) goes to
  your AI agent's provider through the agent, run without tools. Nothing
  while it's off.
- **Your mixes** are in `mixes.json`.
- **Downloads** go only to the folder you picked.
- **Backup sources** download a song's audio only when its usual stream
  fails, into the cache.
- **Backup mirrors**, only when on and only for a song nothing else could
  play: the mirror (someone else's server) is asked for that song's ID.
  Never cookies or your login. To find mirrors, `api.invidious.io` and
  `piped-instances.kavin.rocks` are read once a day, unless you list your
  own.
- **Peak mix** downloads the playing and the next song's audio (with the
  same login as playback, so none unless `playbackCookies` is on) to the
  cache and renders the transition with ffmpeg. It keeps the 12 newest
  downloads and 4 newest renders. Nothing while it's off.
- **Updates**: a `git fetch` of the plugin's own checkout; nothing about you.
- **Problem reports** are opened in your browser for you to read and submit.
  Song IDs, paths, user names, browser profiles, emails, tokens and sign-ins
  in URLs are removed first; storages are named only by kind. Nothing is
  sent before you press Submit.
