# Usage

## The bar

| On the bar icon | Does |
|---|---|
| Click | Open the panel |
| Right-click | Play / pause |
| Middle-click | Next song |
| Scroll | Volume ±5 |

## The panel

`j`/`k` move, `Enter` opens a list or plays a song, `h`/`Backspace` goes
back, `p` play/pause, `n` next, `b` previous, `s` shuffle the open list,
`Shift+R` cycle repeat, `m` start radio, `f` like, `a` add to a playlist,
`d` download (these act on the highlighted song, or the playing one), `,`
settings, `e` Explore, `/` search, `Shift+F` the player window, `r` refresh,
`+`/`-` volume, `Esc` closes. Hovering a song shows its buttons; liked songs
keep a small heart.

The player window has its own keys: see [the player window](player-window.md).

## Commands, for your own key bindings

```bash
omarchy-shell io.github.symonbaikov.ytmusic-mpv toggle        # open / close the panel
omarchy-shell io.github.symonbaikov.ytmusic-mpv playPause     # also: next, previous, stop
omarchy-shell io.github.symonbaikov.ytmusic-mpv cycleRepeat   # off -> all -> one
omarchy-shell io.github.symonbaikov.ytmusic-mpv startRadio    # radio from the playing song
omarchy-shell io.github.symonbaikov.ytmusic-mpv toggleLike    # like the playing song
omarchy-shell io.github.symonbaikov.ytmusic-mpv addToPlaylist # pick a playlist for it
omarchy-shell io.github.symonbaikov.ytmusic-mpv download      # download the playing song
omarchy-shell io.github.symonbaikov.ytmusic-mpv openSettings  # the settings screen
omarchy-shell io.github.symonbaikov.ytmusic-mpv explore       # Explore
omarchy-shell io.github.symonbaikov.ytmusic-mpv tab rd        # a tab: yt, sp, dz, sc, cl, rd, pc, my
omarchy-shell io.github.symonbaikov.ytmusic-mpv fullscreen    # the player window, open / close
omarchy-shell io.github.symonbaikov.ytmusic-mpv full lyrics   # the window on a page: home, browse, nowplaying, lyrics, notes, yt, sp, sc, cl, rd, pc, my
omarchy-shell io.github.symonbaikov.ytmusic-mpv cloud         # add music files or a server
omarchy-shell io.github.symonbaikov.ytmusic-mpv aiMix         # make an AI Mix
omarchy-shell io.github.symonbaikov.ytmusic-mpv signIn        # YouTube's sign-in page
```
