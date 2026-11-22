# Services

Each service is a tab at the top of the panel (and in the player window's
sidebar). The `+` tab picks which ones you see; YouTube Music and My Music
are always there.

| Tab | What you get | Setup |
|---|---|---|
| <img src="icons/youtubemusic.svg" width="20" height="20" alt="" align="center" />&nbsp;YouTube&nbsp;Music | Your playlists, Liked Music, My Supermix, Explore, search, radio, likes, add to playlist | The browser you're signed in with ([settings](settings.md)) |
| <img src="icons/spotify.svg" width="20" height="20" alt="" align="center" />&nbsp;Spotify | Your Liked Songs and the playlists you own or collaborate on | Once: your own Spotify app (below) |
| <img src="icons/deezer.svg" width="20" height="20" alt="" align="center" />&nbsp;Deezer | Your favorite tracks and playlists, Deezer's charts, search | Your profile link |
| <img src="icons/soundcloud.svg" width="20" height="20" alt="" align="center" />&nbsp;SoundCloud | Your likes and playlists, and search across SoundCloud | Your profile name or link |
| <img src="icons/cloud.svg" width="20" height="20" alt="" align="center" />&nbsp;Files | Your Music folder, your music server and your own storage, with covers | One click for ~/Music; a server's address and sign-in; or a storage |
| <img src="icons/radio.svg" width="20" height="20" alt="" align="center" />&nbsp;Radio | About 50,000 stations: top, most liked, a country's, genres, search, favorites | Nothing |
| <img src="icons/podcasts.svg" width="20" height="20" alt="" align="center" />&nbsp;Podcasts | Apple Podcasts' directory or any feed: top shows, search, subscriptions, new episodes | Nothing |
| <img src="icons/mymusic.svg" width="20" height="20" alt="" align="center" />&nbsp;My&nbsp;Music | AI Mix, My Mix, your own mixes, Recently played, Downloads | Nothing |

A search field sits under the tabs: `Enter` (or `/` to get there) searches
YouTube Music, or Deezer, SoundCloud, radio stations or podcasts on their tabs. Back returns
to where you were.

## YouTube Music

- `yt-dlp` reads your library (your playlists plus Liked Music) and each
  playlist's songs. To see your private library it reads your browser's
  saved YouTube login from disk; the browser doesn't have to run. Public
  playlists work without it (`browser: none`).
- **Like** songs (the heart adds them to Liked Music) and **add them to
  your playlists**, like in YouTube Music. The add-to-playlist list is
  YouTube Music's own: only playlists you created, with a ✓ where the song
  already is.
- **Explore**, at the top of your playlists: new albums and singles,
  trending songs, new music videos, charts, and moods & genres. A song plays
  with its radio after it; albums, charts and moods open as playlists.
- **My Supermix**, **Start radio** and **Autoplay** are YouTube Music's own
  recommendations, personalized to your account: see [playback](playback.md).

## Spotify

Spotify keeps its audio locked to its own apps, so its songs play from their
**YouTube Music match** (found by ISRC, then title, artist and length).
Reading your library needs a Spotify app of your own, and its owner needs
**Premium** (Spotify's 2026 rules):

1. Open [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard)
   and create an app with the **Web API**.
2. Add the redirect URI `http://127.0.0.1/callback` (any port is allowed on a
   loopback address).
3. Paste its **Client ID** into the Spotify tab and press **Connect Spotify**;
   you sign in to Spotify in your browser.

Only playlists you own or collaborate on can be read: Spotify doesn't give
apps the songs of other people's playlists.

## Deezer

Read from Deezer's public API, no account or app needed. Like Spotify,
Deezer keeps its audio to its own apps, so songs play from their **YouTube
Music match** (title, artist and length). Paste your profile link into the
Deezer tab (in Deezer: your profile → Share → Copy link); the profile has to
be public. You get your **Favorite tracks**, your playlists, Deezer's **Top
tracks** and chart playlists, and search across Deezer. The tab is off until
you switch it on in the `+` tab.

## SoundCloud

Read with `yt-dlp`, like YouTube. Enter your profile name or link in the
SoundCloud tab. Private likes need you signed in to SoundCloud in the
browser the plugin reads.

## Files

**Your Music folder**: one click adds `~/Music`, or pick any folder on this
computer. Played straight from its files, offline.

**Your music server**:

- **Navidrome**, or any server with the Subsonic API (Airsonic, Gonic …): its
  address, your user name and password.
- **Jellyfin**: its address, your user name and password.
- **Plex**: your browser opens Plex's sign-in; allow it, and the server with
  your music is found by itself.

Each brings its newest albums with covers, your playlists, your favorites
(starred songs; not on Plex) and a random mix. Only a token is kept, never
your password.

**Your own storage**, through [rclone](https://rclone.org) (the tab offers to
install it):

- **Google Drive, Dropbox, OneDrive**: your browser opens the provider's
  sign-in; Google Drive gets read-only access.
- **S3** (Amazon, or S3-compatible: Cloudflare R2, Backblaze B2, MinIO,
  Wasabi): access key, secret key, and the endpoint unless it's Amazon. The
  folder is `bucket/path`.
- **SFTP, SMB, WebDAV** (Nextcloud, ownCloud, a NAS), **FTP**: host or URL,
  user and password. SFTP without a password uses your SSH key.
- **rclone**: a remote you already set up with `rclone config` (offered first).

A storage is checked once before it's added. Each folder with music becomes
an album (named after the folder; the artist from the parent folder or an
"Artist - Title" file name) with `cover.jpg` / `folder.jpg` / `front.png` as
its cover, plus an "all songs" list per storage. The listing is kept for 6
hours; refresh to read new files at once. Removing a storage (settings)
never touches its files.

Songs from Files stream with seeking, and work with fades, Peak mix, mixes
and downloads.

## Radio

About 50,000 internet radio stations from [Radio Browser](https://www.radio-browser.info),
an open directory: the top stations, the most liked, a country's, 22 genres,
search, and your **favorite stations** (the heart on a station).
**Choose a country** lists every country with how many stations it has;
type to narrow it. It starts with the one your language setting names. The
song on air shows when the station announces it; a dropped stream reopens
by itself.

## Podcasts

Shows come from [Apple Podcasts](https://podcasts.apple.com)' public
directory (no account): the top shows in your country, and search. Paste a
feed link into the search to add any podcast that has an RSS feed.

- **Subscribe** on a show's page; its new episodes (from the last 30 days)
  gather in **New episodes**, newest first.
- **Each episode goes on where you stopped**, even after a restart; the list
  says how much is left, or *Played*. An episode you finish starts from the
  beginning next time.
- Episodes play straight from the podcast's own server. Peak mix leaves them
  alone, and they don't count towards your music taste (AI Mix).

## My Music

- **AI Mix**: see [AI Mix](ai-mix.md).
- **My Mix**: your likes from every service (YouTube Music, Spotify, Deezer,
  SoundCloud), alternating between them; the order stays the same all day.
- **Your mixes**: the add button beside any song adds it to one of your
  mixes or starts a new one. In a mix, the stop-square button on a row
  removes that song.
- **Recently played**, from your local listening history.
- **Downloads**: every song you saved, newest first, played from your disk.
