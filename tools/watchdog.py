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

Each check ends as ok, fail, or blocked. "blocked" means YouTube refused
this machine itself (a bot check, rate limiting), which happens to
data-center IPs such as CI runners and says nothing about users; it must
not raise an alarm. The overall status is:

  broken        a core check (lists, playback, clients) failed for real
  inconclusive  a core check was blocked, none failed
  ok            everything core worked

Usage: watchdog.py [--json FILE] [--report FILE]
Prints the status; writes `status=<status>` to $GITHUB_OUTPUT when set.
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


CHECKS = [("lists", check_lists), ("playback", check_playback), ("clients", check_clients),
          ("backup", check_backup), ("peakmix", check_peakmix), ("mirrors", check_mirrors)]


def overall(results):
    core = [results[name]["result"] for name in CORE if name in results]
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


def markdown(status, results, vers):
    icon = {"ok": "✅", "fail": "❌", "blocked": "⛔"}
    lines = [f"**Status: {status}**", "", "| Check | Result | Detail |", "|---|---|---|"]
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
    env = Env()
    results = {}
    try:
        for name, fn in CHECKS:
            try:
                results[name] = fn(env)
            except Exception as exc:          # a crash in a check is a failure of that check
                results[name] = outcome(False, f"{type(exc).__name__}: {exc}")
            if name == "playback":
                env.helper("stop", timeout=30)
    finally:
        env.cleanup()
    status = overall(results)
    vers = versions()
    report = markdown(status, results, vers)
    if opt("--json"):
        with open(opt("--json"), "w") as fh:
            json.dump({"status": status, "results": results, "versions": vers, "at": int(time.time())}, fh, indent=2)
    if opt("--report"):
        with open(opt("--report"), "w") as fh:
            fh.write(report)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as fh:
            fh.write(f"status={status}\n")
    print(report)
    print(status)


if __name__ == "__main__":
    main()
