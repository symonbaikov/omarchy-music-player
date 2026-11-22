# Playback

`mpv --no-video` plays a queue built from the list, driven by the panel over
mpv's JSON IPC socket. With `mpv-mpris` installed it shows up on MPRIS, so
media keys and Omarchy's OSD control it.

## Repeat, radio, autoplay

- **Repeat**, like Apple Music: off (dim) → repeat the playlist → repeat one
  song ("1"). It can be set before anything plays, and is remembered.
- **Start radio** from any YouTube song: a queue of similar songs, YouTube
  Music's own. From the song that's playing, it keeps playing and the radio
  follows it.
- **Autoplay**: when the queue runs out (repeat off), it keeps going with
  songs recommended for the last one.

## Fades

- **Fade in / fade out**: each song rises at its start and fades at its end.
- **Fade on pause**: pausing fades the song away (0.6 s by default) instead
  of cutting it off, and playing again brings it back. Media keys pause at
  once.

## Peak mix

Like a DJ, or Apple Music's AutoMix taken further. At a song's climax it
crossfades into the next song's climax: the next song comes in with its
build-up while the first fades, and its climax lands as the crossfade ends.
Each song plays from its build-up through its best part. The climax comes
from YouTube's "most replayed" graph where a song has one, and from the
audio's loudness: the loudest stretch, entered at its sharpest rise. The
transition is rendered with `ffmpeg` into one file that mpv joins without a
gap. Not for live radio.

## Scrobbling

Settings → **Last.fm** / **ListenBrainz** → Connect. Every song you play
long enough (half of it, or 4 minutes; songs over 30 seconds) is
scrobbled, from any service, including each time round on repeat one. Radio
and podcasts aren't. Names are tidied first: "Band - Song (Official Video)"
becomes the band and the song.

- **ListenBrainz**: paste your user token from
  [listenbrainz.org/settings](https://listenbrainz.org/settings/).
- **Last.fm**: create a free [API account](https://www.last.fm/api/account/create)
  (any name; leave the callback empty), paste its API key and shared secret,
  and allow it on the page Connect opens.

## Downloads

The arrow beside the heart (or `d`): pick MP3, M4A, Opus, FLAC or WAV and a
folder. Title and artist go into the file, and the cover too for MP3, M4A
and FLAC. It uses the same sources as playback, so it works when the usual
stream doesn't. **Downloads** (My Music) plays them from your disk, offline;
a file you delete or move drops out of the list. Live radio can't be
downloaded.

## When YouTube acts up

- **A song's stream won't open**: mpv asks the helper for a backup source:
  the song's cached audio, or a download through YouTube's other clients
  (mobile web, TV, Safari, iOS). The panel says when a song came from one.
  Songs that can't play for a reason about the song (members-only, private,
  removed) are skipped at once, with the reason; if your account can play
  it, **Play with my account** turns playback cookies on and plays it again.
- **Backup mirrors** (off until you turn them on): when no YouTube client
  works either, the song comes from independent front ends
  ([Invidious](https://invidious.io), [Piped](https://github.com/TeamPiped/Piped)),
  your own list or the healthiest public ones. When a song won't play at all
  and mirrors could help, a card offers to turn them on.
- **A stream drops mid-song**: mpv reconnects, or opens the song again where
  it stopped. A radio stream is reopened.
- **Lists or recommendations can't be read**: the saved copies stay in use;
  autoplay falls back to your Liked Music and My Supermix.
- **Nothing plays**: a **Report the problem** button (and a notification if
  the panel is closed) opens a GitHub issue with everything filled in, with
  personal details removed. You only press Submit.

## Updates

Once a day, and right away when songs stop playing, the panel checks this
plugin's repository for a newer version. When there is one, it shows what
changed and an **Update now** button; the music keeps playing through it.
