# AI Mix

A playlist the AI already on your Omarchy makes for you from what you listen
to. My Music → **Make an AI Mix** (or
`omarchy-shell io.github.symonbaikov.ytmusic-mpv aiMix`).

1. Optionally say what you're in the mood for: "epic for work", "calmer",
   "music from games I haven't heard".
2. **Make my AI Mix**. About half a minute later a notification says it's
   ready, with **Play** and **Open**.
3. Once turned on, it's made again each day by itself. Turn it off in
   settings (AI Mix).

## How it works

- **Listening history.** The player notes every song that played: how long
  of how long, whether it ran to its end or you moved on early. Radio
  stations aren't counted. The history stays on your computer
  (`~/.local/share/io.github.symonbaikov.ytmusic-mpv/history.jsonl`).
- **Taste.** From the history and your likes in every service, the helper
  sums up your top artists, most played songs, likes, and the artists you
  keep skipping.
- **The AI.** That summary goes to Omarchy's default agent
  (`omarchy default agent`: Claude, Codex or OpenCode), on your own
  subscription, with no extra keys. It runs without tools, without your
  settings and without saving a session, and gets its question on stdin.
  It answers with about 30 songs: a third close to your favorites, the rest
  new to you, each with a short reason, which shows under the song.
- **No invented songs.** Every pick is looked up on YouTube Music; one that
  can't be found is dropped.

## What is sent

Only while AI Mix is on, and only to your agent's provider (Anthropic for
Claude, OpenAI for Codex …): the artists and songs you play most, your liked
songs, the artists you skip, and your mood if you typed one. Never the
history itself, your accounts or anything else.
