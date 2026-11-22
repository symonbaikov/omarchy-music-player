#!/usr/bin/env python3
"""Watchdog: does YouTube Music playback through this plugin still work?

Runs the plugin's own helper the way the widget does, on public songs and
without any cookies, in throwaway cache and runtime directories, with mpv
playing to a null audio output:

  lists     a song radio's tracks (yt-dlp reading YouTube Music)
  playback  `radio`: mpv starts and the first song actually plays
  clients   which of YouTube's clients still serve a song's audio
  backup    `fallback`: a song downloaded for the backup path
  peakmix   `mixprep`: two songs downloaded, analyzed and mixed
  mirrors   which backup mirrors answer (for information only)

and every other service that works without an account, each through the
helper's own commands: its lists (with covers) and a stream that opens.

  apple       Apple Music's chart, search, a song's YouTube Music match
  deezer      Deezer's chart and a song's YouTube Music match
  soundcloud  a public profile's likes (covers from oEmbed), search, a stream
  mixcloud    popular mixes in a genre and a mix's stream
  audius      trending songs (covers) and a song's stream
  radio       the top stations and a station's stream
  podcasts    Apple Podcasts' search, a feed's episodes and an episode's file
  explore     YouTube Music's Explore without an account
  lyrics      LRCLIB's timed lyrics for a song
  scores      Songsterr's tabs for a song

(Spotify, your files, servers, scrobbling and AI Mix need an account or
your own setup; the unit tests cover them.)

Each check ends as ok, fail, or blocked. "blocked" means YouTube refused
this machine itself (a bot check, rate limiting), which happens to
data-center IPs such as CI runners and says nothing about users; it must
not raise an alarm. The overall status is:

  broken        a core check (lists, playback, clients) failed for real
  inconclusive  a core check was blocked, none failed
  ok            everything core worked

The services get a status of their own the same way (broken if one of
them failed for real), so a service that breaks is reported without
calling YouTube playback broken.

Usage: watchdog.py [--json FILE] [--report FILE] [--only NAME,NAME]
Prints the status; writes `status=`, `services=` and `broken=` (the broken
services) to $GITHUB_OUTPUT when set.
"""

import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
HELPER = os.path.join(ROOT, "bin", "ytmusic-mpv")
PLUGIN_ID = "io.github.symonbaikov.ytmusic-mpv"

# Public, long-lived songs.
SONG_A = "dQw4w9WgXcQ"
SONG_B = "kJQP7kiw5Fk"
CORE = ("lists", "playback", "clients")
BLOCKED_RE = re.compile(r"confirm you.?re not a bot|too many requests|http error 429|rate.?limit", re.I)


class Env:
    """Throwaway cache, runtime and PATH, so nothing touches a real player."""

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="ytw-")
        self.runtime = tempfile.mkdtemp(prefix="ytw", dir="/tmp")   # unix sockets need a short path
        bindir = os.path.join(self.dir, "bin")
        os.makedirs(bindir)
        mpv = shutil.which("mpv") or "mpv"
        with open(os.path.join(bindir, "mpv"), "w") as fh:
            fh.write(f"#!/bin/sh\nexec {mpv} --ao=null --load-scripts=no \"$@\"\n")
        os.chmod(os.path.join(bindir, "mpv"), 0o755)
        self.vars = dict(os.environ, XDG_CACHE_HOME=os.path.join(self.dir, "cache"),
                         XDG_RUNTIME_DIR=self.runtime, XDG_CONFIG_HOME=os.path.join(self.dir, "config"),
                         PATH=bindir + os.pathsep + os.environ.get("PATH", ""))

    def helper(self, *args, timeout=180):
        proc = subprocess.run([sys.executable, "-I", HELPER, *args], capture_output=True, text=True,
                              timeout=timeout, env=self.vars, stdin=subprocess.DEVNULL)
        lines = []
        for line in proc.stdout.splitlines():
            try:
                lines.append(json.loads(line))
            except ValueError:
                pass
        return proc, lines

    @property
    def socket_path(self):
        return os.path.join(self.runtime, PLUGIN_ID, "mpv.sock")

    @property
    def mpv_log(self):
        return os.path.join(self.dir, "cache", PLUGIN_ID, "mpv.log")

    def cleanup(self):
        try:
            self.helper("stop", timeout=30)
        except Exception:
            pass
        shutil.rmtree(self.dir, ignore_errors=True)
        shutil.rmtree(self.runtime, ignore_errors=True)


def outcome(ok, detail):
    if ok:
        return {"result": "ok", "detail": detail}
    return {"result": "blocked" if BLOCKED_RE.search(detail or "") else "fail", "detail": detail}


def last_error(lines, proc):
    for msg in reversed(lines):
        if msg.get("type") == "error":
            return msg.get("message", "")
    return (proc.stderr or "").strip()[-400:] or f"exit {proc.returncode}"


def check_lists(env):
    proc, lines = env.helper("tracks", f"RDAMVM{SONG_A}", "--browser", "none", "--max-age", "0")
    items = next((m.get("items") for m in reversed(lines) if m.get("type") == "tracks"), None) or []
    if len(items) >= 5:
        return outcome(True, f"{len(items)} tracks")
    return outcome(False, last_error(lines, proc) if not items else f"only {len(items)} tracks")


def mpv_get(path, prop):
    try:
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(2)
            s.connect(path)
            s.sendall((json.dumps({"command": ["get_property", prop], "request_id": 1}) + "\n").encode())
            buf = b""
            while b"\n" not in buf or b'"request_id":1' not in buf:
                buf += s.recv(65536)
            for line in buf.split(b"\n"):
                msg = json.loads(line or b"{}")
                if msg.get("request_id") == 1:
                    return msg.get("data")
    except (OSError, ValueError):
        return None


def log_errors(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = [l.rstrip() for l in fh if "][e][" in l or "ERROR:" in l or "][w][ytmusic]" in l]
        return "\n".join(lines[-8:])
    except OSError:
        return ""


def check_playback(env):
    proc, lines = env.helper("radio", SONG_A, "--mode", "replace", "--browser", "none", "--title", "Watchdog")
    if not any(m.get("type") == "playing" for m in lines):
        return outcome(False, last_error(lines, proc))
    deadline = time.time() + 75
    while time.time() < deadline:
        pos = mpv_get(env.socket_path, "time-pos")
        if isinstance(pos, (int, float)) and pos > 3:
            via = mpv_get(env.socket_path, "stream-open-filename") or ""
            backup = " (through a backup source)" if "/mix/audio-" in via else ""
            return outcome(True, f"playing at {pos:.1f} s{backup}")
        time.sleep(2)
    return outcome(False, log_errors(env.mpv_log) or "mpv never got past the start")


def check_clients(env):
    from importlib.machinery import SourceFileLoader
    helper = SourceFileLoader("ytmusic_helper", HELPER).load_module()
    results, details = {}, []
    for client in helper.AUDIO_CLIENTS:
        cmd = ["yt-dlp", "--ignore-config", "--no-warnings", "-J", "-f", "bestaudio/best", "--no-playlist"]
        if client:
            cmd += ["--extractor-args", f"youtube:player_client={client}"]
        proc = subprocess.run(cmd + ["--", f"https://music.youtube.com/watch?v={SONG_B}"],
                              capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
        ok = proc.returncode == 0 and '"url"' in proc.stdout
        err = "" if ok else ([l for l in proc.stderr.splitlines() if l.startswith("ERROR")] or [proc.stderr[-200:]])[-1]
        results[client or "default"] = "ok" if ok else ("blocked" if BLOCKED_RE.search(err) else "fail")
        details.append(f"{client or 'default'}: {'ok' if ok else err[:160]}")
    working = [c for c, r in results.items() if r == "ok"]
    if working:
        return {"result": "ok", "detail": "working: " + ", ".join(working), "clients": results, "log": details}
    blocked = all(r == "blocked" for r in results.values())
    return {"result": "blocked" if blocked else "fail", "detail": "no client serves audio",
            "clients": results, "log": details}


def check_backup(env):
    proc, lines = env.helper("fallback", SONG_B)
    msg = next((m for m in reversed(lines) if m.get("type") == "fallback"), None)
    if msg and msg.get("ok"):
        return outcome(True, f"via {msg.get('via')}")
    return outcome(False, (msg or {}).get("reason") or last_error(lines, proc))


def check_peakmix(env):
    proc, lines = env.helper("mixprep", f"https://music.youtube.com/watch?v={SONG_A}",
                             f"https://music.youtube.com/watch?v={SONG_B}", "--xfade", "6", "--min-exit", "0")
    msg = next((m for m in reversed(lines) if m.get("type") == "mix"), None)
    if msg and msg.get("ok"):
        return outcome(True, f"leaves song A at {msg.get('exit')} s")
    return outcome(False, (msg or {}).get("reason") or last_error(lines, proc))


def check_mirrors(env):
    proc, lines = env.helper("mirrors", "--check", "--refresh", timeout=240)
    mirrors = [m for m in lines if m.get("type") == "mirror"]
    up = [m["url"] for m in mirrors if m.get("ok")]
    return {"result": "ok" if up else "fail", "detail": f"{len(up)}/{len(mirrors)} answer: " + ", ".join(up[:5]),
            "informational": True}


# ---- other services ------------------------------------------------------------

def last_of(lines, kind):
    return next((m for m in reversed(lines) if m.get("type") == kind), None)


def items_of(env, *args, kind="tracks", timeout=180):
    proc, lines = env.helper(*args, timeout=timeout)
    msg = last_of(lines, kind)
    return (msg or {}).get("items") or [], ("" if msg else last_error(lines, proc))


def covered(items):
    return sum(1 for t in items if t.get("cover")) / max(1, len(items))


def resolve(env, key):
    proc, lines = env.helper("resolve", key, timeout=120)
    msg = last_of(lines, "resolved")
    return (msg or {}).get("url") or "", ("" if msg else last_error(lines, proc))


def stream_opens(url, timeout=60):
    """ffprobe reads the start of the stream: it's reachable and has audio."""
    try:
        proc = subprocess.run(["ffprobe", "-v", "error", "-rw_timeout", "20000000", "-show_entries",
                               "stream=codec_type", "-of", "csv=p=0", url],
                              capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return False, "the stream didn't answer in time"
    ok = proc.returncode == 0 and "audio" in proc.stdout
    return ok, "" if ok else ((proc.stderr or "").strip()[-200:] or "no audio in it")


def ytdlp_stream(url):
    proc = subprocess.run(["yt-dlp", "--ignore-config", "--no-warnings", "-g", "-f", "bestaudio/best", "--", url],
                          capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
    ok = proc.returncode == 0 and proc.stdout.strip().startswith("http")
    err = "" if ok else ([l for l in proc.stderr.splitlines() if l.startswith("ERROR")] or [proc.stderr[-200:]])[-1]
    return ok, err


def need(items, least, what, err, cover=None):
    """None when the list is fine, else why not."""
    if len(items) < least:
        return err or f"only {len(items)} {what}"
    if cover is not None and covered(items) < cover:
        return f"{what}: only {covered(items):.0%} have a cover"
    return None


def helper_module():
    from importlib.machinery import SourceFileLoader
    return SourceFileLoader("ytmusic_helper", HELPER).load_module()


def check_apple(env):
    items, err = items_of(env, "tracks", "am:top", "--max-age", "0")
    bad = need(items, 50, "chart songs", err, cover=0.8)
    if bad:
        return outcome(False, bad)
    found, err = items_of(env, "search", "Ghost Love Score Nightwish", "--service", "am", kind="search")
    if not found:
        return outcome(False, err or "search found nothing")
    url, err = resolve(env, found[0]["id"])
    if "music.youtube.com/watch?v=" not in url:
        return outcome(False, err or "no YouTube Music match")
    return outcome(True, f"chart {len(items)}, search {len(found)}, matched")


def check_deezer(env):
    items, err = items_of(env, "tracks", "dz:chart", "--max-age", "0")
    bad = need(items, 50, "chart songs", err, cover=0.8)
    if bad:
        return outcome(False, bad)
    url, err = resolve(env, items[0]["id"])
    if "music.youtube.com/watch?v=" not in url:
        return outcome(False, err or "no YouTube Music match")
    return outcome(True, f"chart {len(items)}, matched")


def check_soundcloud(env):
    items, err = items_of(env, "tracks", "sc:likes:skrillex", "--browser", "none", "--max-age", "0")
    bad = need(items, 5, "liked songs", err, cover=0.6)
    if bad:
        return outcome(False, bad)
    found, err = items_of(env, "search", "lofi hip hop", "--service", "sc", "--browser", "none", kind="search")
    if len(found) < 5:
        return outcome(False, err or f"search found {len(found)}")
    ok, err = ytdlp_stream(helper_module().sc_url(found[0]["id"]))
    if not ok:
        return outcome(False, err)
    return outcome(True, f"likes {len(items)} ({covered(items):.0%} covers), search {len(found)}, stream ok")


def check_mixcloud(env):
    items, err = items_of(env, "tracks", "mc:hot:house", "--max-age", "0")
    bad = need(items, 10, "mixes", err, cover=0.6)
    if bad:
        return outcome(False, bad)
    ok, err = ytdlp_stream(helper_module().mc_url(items[0]["id"]))
    return outcome(ok, f"{len(items)} mixes, stream ok" if ok else err)


def check_audius(env):
    items, err = items_of(env, "tracks", "au:trending", "--max-age", "0")
    bad = need(items, 10, "songs", err, cover=0.6)
    if bad:
        return outcome(False, bad)
    url, err = resolve(env, items[0]["id"])
    if not url:
        return outcome(False, err)
    ok, err = stream_opens(url)
    return outcome(ok, f"{len(items)} songs, stream ok" if ok else err)


def check_radio(env):
    items, err = items_of(env, "tracks", "rd:top", "--max-age", "0")
    bad = need(items, 10, "stations", err)
    if bad:
        return outcome(False, bad)
    last = ""
    for station in items[:4]:          # stations come and go; one of the top must play
        url, err = resolve(env, station["id"])
        if url:
            ok, err = stream_opens(url, timeout=40)
            if ok:
                return outcome(True, f"{len(items)} stations, a stream plays")
        last = err
    return outcome(False, "none of the top 4 stations opened: " + last)


def check_podcasts(env):
    shows, err = items_of(env, "search", "The Rest Is History", "--service", "pc", kind="search")
    if not shows:
        return outcome(False, err or "search found nothing")
    eps, err = items_of(env, "tracks", shows[0]["id"], "--max-age", "0")
    if not eps:
        return outcome(False, err or "the feed has no episodes")
    url, err = resolve(env, eps[0]["id"])
    if not url:
        return outcome(False, err)
    ok, err = stream_opens(url)
    return outcome(ok, f"{len(shows)} shows, {len(eps)} episodes, an episode opens" if ok else err)


def check_explore(env):
    proc, lines = env.helper("explore", "--max-age", "0")
    sections = (last_of(lines, "explore") or {}).get("sections") or []
    if len(sections) >= 3:
        return outcome(True, f"{len(sections)} sections")
    return outcome(False, last_error(lines, proc) if not sections else f"only {len(sections)} sections")


def check_lyrics(env):
    proc, lines = env.helper("lyrics", SONG_A, "--title", "Never Gonna Give You Up", "--artist", "Rick Astley",
                             "--duration", "213")
    msg = last_of(lines, "lyrics")
    synced = (msg or {}).get("synced") or []
    if len(synced) >= 10:
        return outcome(True, f"{len(synced)} timed lines from {msg.get('source')}")
    return outcome(False, last_error(lines, proc) if not msg else "no timed lyrics")


def check_scores(env):
    proc, lines = env.helper("scores", SONG_A, "--title", "Never Gonna Give You Up", "--artist", "Rick Astley")
    msg = last_of(lines, "scores")
    items = (msg or {}).get("items") or []
    if items:
        return outcome(True, f"{len(items)} tabs")
    return outcome(False, last_error(lines, proc) if not msg else "no tabs found")


CHECKS = [("lists", check_lists), ("playback", check_playback), ("clients", check_clients),
          ("backup", check_backup), ("peakmix", check_peakmix), ("mirrors", check_mirrors)]
SERVICE_CHECKS = [("apple", check_apple), ("deezer", check_deezer), ("soundcloud", check_soundcloud),
                  ("mixcloud", check_mixcloud), ("audius", check_audius), ("radio", check_radio),
                  ("podcasts", check_podcasts), ("explore", check_explore), ("lyrics", check_lyrics),
                  ("scores", check_scores)]
SERVICES = [name for name, _ in SERVICE_CHECKS]


def overall(results, names=CORE):
    core = [results[name]["result"] for name in names if name in results]
    if "fail" in core:
        return "broken"
    if "blocked" in core:
        return "inconclusive"
    return "ok"


def versions():
    out = {"python": platform.python_version()}
    for name, cmd in (("yt-dlp", ["yt-dlp", "--version"]), ("mpv", ["mpv", "--version"]), ("ffmpeg", ["ffmpeg", "-version"])):
        try:
            out[name] = subprocess.run(cmd, capture_output=True, text=True, timeout=20).stdout.splitlines()[0][:80]
        except (OSError, IndexError, subprocess.TimeoutExpired):
            out[name] = "missing"
    try:
        out["plugin"] = json.load(open(os.path.join(ROOT, "manifest.json")))["version"]
    except (OSError, ValueError, KeyError):
        out["plugin"] = "?"
    return out


def markdown(status, results, vers, services="ok"):
    icon = {"ok": "✅", "fail": "❌", "blocked": "⛔"}
    lines = [f"**YouTube Music playback: {status}** · **Other services: {services}**", "",
             "| Check | Result | Detail |", "|---|---|---|"]
    for name, r in results.items():
        detail = str(r.get("detail", "")).replace("|", "\\|").replace("\n", " ")[:300]
        extra = " (info)" if r.get("informational") else ""
        lines.append(f"| {name}{extra} | {icon.get(r['result'], '')} {r['result']} | {detail} |")
    if "clients" in results and results["clients"].get("log"):
        lines += ["", "<details><summary>YouTube clients</summary>", "", "```"] + results["clients"]["log"] + ["```", "</details>"]
    lines += ["", "Versions: " + ", ".join(f"{k} {v}" for k, v in vers.items())]
    return "\n".join(lines) + "\n"


def main():
    args = sys.argv[1:]
    def opt(name):
        return args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else None
    only = set((opt("--only") or "").split(",")) - {""}
    env = Env()
    results = {}
    try:
        for name, fn in CHECKS + SERVICE_CHECKS:
            if only and name not in only:
                continue
            try:
                results[name] = fn(env)
            except Exception as exc:          # a crash in a check is a failure of that check
                results[name] = outcome(False, f"{type(exc).__name__}: {exc}")
            if name == "playback":
                env.helper("stop", timeout=30)
    finally:
        env.cleanup()
    status = overall(results)
    services = overall(results, SERVICES)
    broken = [name for name in SERVICES if results.get(name, {}).get("result") == "fail"]
    vers = versions()
    report = markdown(status, results, vers, services)
    if opt("--json"):
        with open(opt("--json"), "w") as fh:
            json.dump({"status": status, "services": services, "broken": broken, "results": results,
                       "versions": vers, "at": int(time.time())}, fh, indent=2)
    if opt("--report"):
        with open(opt("--report"), "w") as fh:
            fh.write(report)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as fh:
            fh.write(f"status={status}\nservices={services}\nbroken={','.join(broken)}\n")
    print(report)
    print(status, "/ services:", services)


if __name__ == "__main__":
    main()
