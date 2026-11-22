# Run: python3 -I -m unittest discover -s tests -p 'test_*.py'
# No network and no browser cookies: only the helper's pure parts.
import json
import os
import urllib.parse
import pathlib
import sys
import tempfile
import time
import unittest
from importlib.machinery import SourceFileLoader

sys.dont_write_bytecode = True
HELPER = pathlib.Path(__file__).resolve().parent.parent / "bin" / "ytmusic-mpv"
h = SourceFileLoader("ytmusic_mpv_helper", str(HELPER)).load_module()


def flags_dir(files):
    d = tempfile.TemporaryDirectory()
    for name, text in files.items():
        pathlib.Path(d.name, name).write_text(text)
    return d


class BrowserSpec(unittest.TestCase):
    def test_keyring_from_omarchy_chromium_flags(self):
        with flags_dir({"chromium-flags.conf": "--ozone-platform=wayland\n--password-store=gnome-libsecret\n"}) as d:
            self.assertEqual(h.browser_parts("chromium", d), ("chromium", "gnomekeyring", None))

    def test_keyring_per_browser_and_store(self):
        with flags_dir({"brave-flags.conf": "--password-store=kwallet6", "chrome-flags.conf": "--password-store basic"}) as d:
            self.assertEqual(h.browser_parts("brave", d)[1], "kwallet6")
            self.assertEqual(h.browser_parts("chrome", d)[1], "basictext")
            self.assertIsNone(h.browser_parts("vivaldi", d)[1])   # no flags file: yt-dlp decides

    def test_last_flag_wins_and_unknown_store_is_ignored(self):
        with flags_dir({"chromium-flags.conf": "--password-store=basic\n--password-store=gnome-libsecret\n"}) as d:
            self.assertEqual(h.browser_parts("chromium", d)[1], "gnomekeyring")
        with flags_dir({"chromium-flags.conf": "--password-store=mystery"}) as d:
            self.assertIsNone(h.browser_parts("chromium", d)[1])

    def test_explicit_keyring_wins_and_firefox_never_gets_one(self):
        with flags_dir({"chromium-flags.conf": "--password-store=gnome-libsecret"}) as d:
            self.assertEqual(h.browser_parts("chromium+KWallet6", d)[1], "kwallet6")
            self.assertIsNone(h.browser_parts("firefox:~/.config/zen/x", d)[1])

    def test_profile_paths_expand(self):
        name, keyring, profile = h.browser_parts("firefox:~/.config/zen/29yzqria.Default (release)", "/nonexistent")
        self.assertEqual(profile, os.path.expanduser("~/.config/zen/29yzqria.Default (release)"))
        self.assertEqual(h.browser_parts("brave:Profile 1", "/nonexistent")[2], "Profile 1")

    def test_yt_dlp_accepts_what_we_produce(self):
        from yt_dlp import parse_options
        from yt_dlp.cookies import _parse_browser_specification
        with flags_dir({"chromium-flags.conf": "--password-store=gnome-libsecret"}) as d:
            old = os.environ.get("XDG_CONFIG_HOME")
            os.environ["XDG_CONFIG_HOME"] = d
            try:
                spec = h.cookie_spec("chromium:Profile 1")
                tup = h.browser_spec_tuple("chromium:Profile 1")
            finally:
                if old is None:
                    os.environ.pop("XDG_CONFIG_HOME")
                else:
                    os.environ["XDG_CONFIG_HOME"] = old
        self.assertEqual(spec, "chromium+gnomekeyring:Profile 1")
        self.assertEqual(tup, ("chromium", "Profile 1", "GNOMEKEYRING", None))
        _parse_browser_specification(*tup)   # raises on an unsupported keyring
        self.assertEqual(parse_options(["--cookies-from-browser", spec]).ydl_opts["cookiesfrombrowser"][:3],
                         ("chromium", "Profile 1", "GNOMEKEYRING"))


class Signing(unittest.TestCase):
    def test_sapisidhash_matches_yt_dlp(self):
        from yt_dlp.extractor.youtube._base import YoutubeBaseInfoExtractor as Y
        real = time.time
        time.time = lambda: 1795300000.4
        try:
            ours = h.sid_authorization({"SAPISID": "s/1", "__Secure-1PAPISID": "p1", "__Secure-3PAPISID": "p3"})
            theirs = " ".join(Y._make_sid_authorization(s, v, h.MUSIC_ORIGIN, {})
                              for s, v in (("SAPISIDHASH", "s/1"), ("SAPISID1PHASH", "p1"), ("SAPISID3PHASH", "p3")))
        finally:
            time.time = real
        self.assertEqual(ours, theirs)

    def test_no_sid_cookie_means_no_header(self):
        self.assertEqual(h.sid_authorization({}), "")


def option(pid, title, contains="NONE"):
    return {"playlistAddToOptionRenderer": {"playlistId": pid, "title": {"simpleText": title},
                                            "containsSelectedVideos": contains}}


class AddTargets(unittest.TestCase):
    def test_parses_nested_dialog(self):
        response = {"contents": [{"addToPlaylistRenderer": {"playlists": [
            option("PLmine1", "Road trip"),
            option("VLPLmine2", "Gym", "ALL"),
            option("PLmine1", "dupe"),
            option("LM", "Liked"),
            option("bad id!", "x"),
        ]}}]}
        items = h.parse_add_targets(response)
        self.assertEqual([(i["id"], i["title"], i["contains"]) for i in items],
                         [("PLmine1", "Road trip", False), ("PLmine2", "Gym", True)])

    def test_runs_titles_and_markup_stay_plain_text(self):
        response = {"addToPlaylistRenderer": {"playlists": [
            {"playlistAddToOptionRenderer": {"playlistId": "PLx1", "title": {"runs": [{"text": "A "}, {"text": "<b>B</b>\n"}]}}}]}}
        self.assertEqual(h.parse_add_targets(response)[0]["title"], "A <b>B</b>")

    def test_empty_dialog_is_valid_unknown_shape_is_not(self):
        self.assertEqual(h.parse_add_targets({"addToPlaylistRenderer": {"playlists": []}}), [])
        self.assertIsNone(h.parse_add_targets({"something": "else"}))


class ApiErrors(unittest.TestCase):
    def run_failure(self, code, status, action):
        import contextlib
        import io
        import json
        out = io.StringIO()
        with contextlib.redirect_stdout(out), tempfile.TemporaryDirectory() as d:
            h.API_LOG = os.path.join(d, "api.log")
            with self.assertRaises(SystemExit):
                h.api_failure("browse/edit_playlist", code, status, "The caller does not have permission", action)
            logged = pathlib.Path(h.API_LOG).read_text()
        return json.loads(out.getvalue()), logged

    def test_permission_denied_on_add_is_not_a_sign_in_problem(self):
        msg, logged = self.run_failure(403, "PERMISSION_DENIED", "add")
        self.assertNotIn("auth", msg)
        self.assertIn("playlists you created", msg["message"])
        self.assertIn("HTTP 403 PERMISSION_DENIED", logged)

    def test_unauthenticated_asks_to_sign_in(self):
        msg, _ = self.run_failure(401, "UNAUTHENTICATED", "add")
        self.assertTrue(msg.get("auth"))

    def test_other_errors_show_youtubes_reason(self):
        msg, _ = self.run_failure(400, "INVALID_ARGUMENT", "add")
        self.assertNotIn("auth", msg)
        self.assertIn("The caller does not have permission", msg["message"])


class SignIn(unittest.TestCase):
    def test_signs_in_with_the_cookies_browser(self):
        import shutil
        real = shutil.which
        installed = {"zen-browser", "firefox", "chromium", "xdg-open"}
        shutil.which = lambda name: f"/usr/bin/{name}" if name in installed else None
        try:
            self.assertEqual(h.browser_command("firefox:~/.config/zen/abc.Default (release)"), ["/usr/bin/zen-browser"])
            self.assertEqual(h.browser_command("firefox"), ["/usr/bin/firefox"])
            self.assertEqual(h.browser_command("chromium"), ["/usr/bin/chromium"])
            self.assertEqual(h.browser_command("brave"), ["/usr/bin/xdg-open"])   # not installed: default browser
        finally:
            shutil.which = real

    def test_sign_in_url_is_fixed_https(self):
        self.assertTrue(h.SIGNIN_URL.startswith("https://accounts.google.com/"))


class FakeMpv:
    """Answers get/set of ytdl-raw-options on a unix socket, like mpv's IPC."""

    def __init__(self, path, options, honor_set=True):
        import json, socket, threading
        self.json, self.options, self.honor_set = json, dict(options), honor_set
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(8)
        self.server.settimeout(0.2)
        self.running = True
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while self.running:
            try:
                conn, _ = self.server.accept()
            except OSError:
                continue
            with conn:
                buf = b""
                conn.settimeout(1)
                try:
                    while True:
                        chunk = conn.recv(65536)
                        if not chunk:
                            break
                        buf += chunk
                        while b"\n" in buf:
                            line, buf = buf.split(b"\n", 1)
                            conn.sendall((self.json.dumps(self.reply(self.json.loads(line))) + "\n").encode())
                except OSError:
                    pass

    def reply(self, msg):
        cmd, rid = msg["command"], msg.get("request_id")
        if cmd[:2] == ["get_property", "ytdl-raw-options"]:
            return {"request_id": rid, "error": "success", "data": dict(self.options)}
        if cmd[:2] == ["set_property", "ytdl-raw-options"]:
            if self.honor_set:
                self.options = dict(cmd[2])
            return {"request_id": rid, "error": "success"}
        return {"request_id": rid, "error": "success"}

    def close(self):
        self.running = False
        self.thread.join()
        self.server.close()


class PlayerCookies(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        d = self.dir.name
        self.saved = (h.SOCKET_PATH, h.SESSION_PATH, h.PID_PATH, h.our_mpv_pid, h.widget_settings, h.SessionLock)
        h.SOCKET_PATH, h.SESSION_PATH, h.PID_PATH = (os.path.join(d, n) for n in ("s", "session.json", "pid"))
        pathlib.Path(h.SESSION_PATH).write_text("{}")
        # The widget's settings in shell.json, as the user has them now.
        self.settings = {}
        h.widget_settings = lambda: self.settings
        self.alive = True
        h.our_mpv_pid = lambda: 4242 if self.alive else None
        self.mpv = None

    def tearDown(self):
        if self.mpv:
            self.mpv.close()
        h.SOCKET_PATH, h.SESSION_PATH, h.PID_PATH, h.our_mpv_pid, h.widget_settings, h.SessionLock = self.saved
        self.dir.cleanup()

    def options(self, browser, cookies):
        return {"browser": browser, "playback_cookies": cookies, "volume": 60, "repeat": "off"}

    def test_turning_cookies_off_revokes_them_and_keeps_other_options(self):
        self.mpv = FakeMpv(h.SOCKET_PATH, {"cookies-from-browser": "firefox", "x": "1"})
        self.assertEqual(h.apply_player_cookies(self.options("firefox", False)), "applied")
        self.assertEqual(self.mpv.options, {"x": "1"})
        self.assertTrue(os.path.exists(h.SESSION_PATH))

    def test_browser_none_revokes_them(self):
        self.mpv = FakeMpv(h.SOCKET_PATH, {"cookies-from-browser": "firefox"})
        self.assertEqual(h.apply_player_cookies(self.options("none", True)), "applied")
        self.assertEqual(self.mpv.options, {})

    def test_turning_cookies_on_uses_the_current_browser(self):
        self.mpv = FakeMpv(h.SOCKET_PATH, {"cookies-from-browser": "chromium"})
        self.assertEqual(h.apply_player_cookies(self.options("firefox", True)), "applied")
        self.assertEqual(self.mpv.options, {"cookies-from-browser": "firefox"})

    def test_settings_changed_while_loading_win(self):
        # A radio started with cookies On (and Firefox) that finishes after
        # the user turned them off, or picked another browser, must not use them.
        self.mpv = FakeMpv(h.SOCKET_PATH, {"cookies-from-browser": "firefox"})
        self.settings = {"browser": "firefox", "playbackCookies": "Off"}
        self.assertIsNone(h.playback_cookie_spec(self.options("firefox", True)))
        self.assertEqual(h.apply_player_cookies(self.options("firefox", True)), "applied")
        self.assertEqual(self.mpv.options, {})
        self.settings = {"browser": "chromium", "playbackCookies": "On"}
        self.assertIsNone(h.playback_cookie_spec(self.options("firefox", True)))
        self.settings = {"browser": "firefox", "playbackCookies": "On"}
        self.assertEqual(h.playback_cookie_spec(self.options("firefox", True)), "firefox")

    def test_revoking_does_not_wait_for_the_session_lock(self):
        # A radio holding the lock while it loads must not delay revocation.
        self.mpv = FakeMpv(h.SOCKET_PATH, {"cookies-from-browser": "firefox"})

        class Held:
            def __enter__(self):
                raise AssertionError("revocation waited for the lock")

            def __exit__(self, *exc):
                return False
        h.SessionLock = Held
        out = capture(h.cmd_cookies, ["--browser", "firefox", "--playback-cookies", "0"])
        self.assertEqual(out[-1], {"type": "cookies", "state": "applied"})
        self.assertEqual(self.mpv.options, {})

    def test_unconfirmed_revocation_stops_the_player(self):
        self.mpv = FakeMpv(h.SOCKET_PATH, {"cookies-from-browser": "firefox"}, honor_set=False)
        self.assertEqual(h.apply_player_cookies(self.options("firefox", False)), "stopped")
        self.assertFalse(os.path.exists(h.SESSION_PATH))

    def test_unreachable_player_is_stopped(self):
        # A pid but no socket answering: nothing can be confirmed.
        pathlib.Path(h.SOCKET_PATH).write_text("")
        self.assertEqual(h.apply_player_cookies(self.options("firefox", False)), "stopped")
        self.assertFalse(os.path.exists(h.SESSION_PATH))

    def test_no_player_is_left_alone(self):
        self.alive = False
        self.assertEqual(h.apply_player_cookies(self.options("firefox", False)), "idle")
        self.assertTrue(os.path.exists(h.SESSION_PATH))


class PeakMix(unittest.TestCase):
    FPS = 10

    def env(self, parts):
        """Loudness envelope from (seconds, dB) parts."""
        out = []
        for seconds, db in parts:
            out += [float(db)] * int(seconds * self.FPS)
        return out

    def test_climax_lands_on_the_loud_section_and_its_rise(self):
        env = self.env([(60, -30), (50, -10), (70, -24), (20, -30)])
        c = h.find_climax(env, None, 6.0)
        self.assertAlmostEqual(c["entry"], 60.0, delta=1.0)     # where it gets loud
        self.assertGreaterEqual(c["exit"], c["entry"] + 30)
        self.assertLessEqual(c["exit"], 115.0)                  # leaves around the climax's end
        self.assertAlmostEqual(c["level"], -10.0, delta=0.5)

    def test_heatmap_picks_between_equal_choruses_but_not_the_start(self):
        env = self.env([(30, -30), (30, -10), (30, -30), (30, -10), (60, -30)])
        heat = [{"start_time": i * 1.8, "end_time": (i + 1) * 1.8, "value": 0.0} for i in range(100)]
        for b in heat:
            if b["start_time"] < 5 or 90 <= b["start_time"] < 120:
                b["value"] = 1.0                                  # everyone starts at 0:00; the 2nd chorus is replayed
        c = h.find_climax(env, heat, 6.0)
        self.assertAlmostEqual(c["entry"], 90.0, delta=1.0)
        self.assertEqual(h.heatmap_bins(heat, 180)[0][0] >= 18, True)

    def test_too_short_to_mix(self):
        self.assertIsNone(h.find_climax(self.env([(40, -10)]), None, 6.0))

    def test_entries_are_watch_urls_or_our_own_segments(self):
        with tempfile.TemporaryDirectory() as d:
            saved = h.MIX_DIR
            h.MIX_DIR = d
            try:
                self.assertEqual(h.mix_entry("https://music.youtube.com/watch?v=dQw4w9WgXcQ"), ("dQw4w9WgXcQ", None))
                self.assertEqual(h.mix_entry("https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=x"), (None, None))
                seg = os.path.join(d, "seg-dQw4w9WgXcQ-kJQP7kiw5Fk.flac")
                pathlib.Path(seg).write_bytes(b"")
                self.assertEqual(h.mix_entry(seg), (None, None))     # no sidecar
                h.write_json_atomic(seg[:-5] + ".json", {"id": "kJQP7kiw5Fk", "offset": 123.4, "gain": -5.5})
                self.assertEqual(h.mix_entry(seg)[0], "kJQP7kiw5Fk")
                elsewhere = tempfile.TemporaryDirectory()
                other = os.path.join(elsewhere.name, "seg-dQw4w9WgXcQ-kJQP7kiw5Fk.flac")
                pathlib.Path(other).write_bytes(b"")
                self.assertEqual(h.mix_entry(other), (None, None))   # only files in the mix cache
                self.assertEqual(h.mix_entry("/etc/passwd"), (None, None))
                elsewhere.cleanup()
            finally:
                h.MIX_DIR = saved

    def test_render_joins_sample_exact_and_crossfades(self):
        import shutil, subprocess, array
        if not shutil.which("ffmpeg"):
            self.skipTest("ffmpeg not installed")
        with tempfile.TemporaryDirectory() as d:
            saved = h.MIX_DIR
            h.MIX_DIR = d
            try:
                for name, freq in (("a.flac", 440), ("b.flac", 660)):
                    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", f"sine=frequency={freq}:duration=30:sample_rate=48000",
                                    "-ac", "2", os.path.join(d, name)], check=True)
                a = {"audio": "a.flac", "climax": {"entry": 5.0, "exit": 12.0, "level": -10}}
                b = {"audio": "b.flac", "climax": {"entry": 10.0, "exit": 25.0, "level": -10}}
                out = os.path.join(d, "seg-aaaaaaaaaaa-bbbbbbbbbbb.flac")
                h.render_segment(a, 0.0, "bbbbbbbbbbb", b, 0.0, 4.0, out)
                self.assertEqual(h.read_json(out[:-5] + ".json"), {"id": "bbbbbbbbbbb", "offset": 6.0, "gain": 0.0})
                pcm = subprocess.run(["ffmpeg", "-v", "error", "-i", out, "-ac", "1", "-f", "s16le", "-"], capture_output=True).stdout
                seg = array.array("h"); seg.frombytes(pcm)
                ref = subprocess.run(["ffmpeg", "-v", "error", "-i", os.path.join(d, "a.flac"), "-ac", "1",
                                      "-af", "atrim=start=12", "-f", "s16le", "-"], capture_output=True).stdout
                a_at_exit = array.array("h"); a_at_exit.frombytes(ref)
                # It opens with A exactly where A is cut off ...
                self.assertEqual(list(seg[:3]), list(a_at_exit[:3]))
                # ... and is the rest of B from its build-up: 30 - 6 seconds.
                self.assertAlmostEqual(len(seg) / 48000, 24.0, delta=0.05)
            finally:
                h.MIX_DIR = saved


class BackupSources(unittest.TestCase):
    def setUp(self):
        import yt_dlp
        self.yt_dlp = yt_dlp
        self.saved = (h.MIX_DIR, yt_dlp.YoutubeDL, h.CACHE_DIR)
        self.dir = tempfile.TemporaryDirectory()
        h.MIX_DIR = os.path.join(self.dir.name, "mix")
        self.tried = []

    def tearDown(self):
        h.MIX_DIR, self.yt_dlp.YoutubeDL, h.CACHE_DIR = self.saved
        self.dir.cleanup()

    def fake_ydl(self, works_for, error="Sign in to confirm you're not a bot"):
        test = self

        class FakeYDL:
            def __init__(self, opts):
                self.opts = opts
            def __enter__(self):
                return self
            def __exit__(self, *a):
                return False
            def extract_info(self, url, download):
                client = (self.opts.get("extractor_args") or {}).get("youtube", {}).get("player_client", [None])[0]
                test.tried.append(client)
                if client != works_for:
                    raise Exception(f"ERROR: [youtube] dQw4w9WgXcQ: {error}")
                path = self.opts["outtmpl"].replace("%(id)s", "dQw4w9WgXcQ").replace("%(ext)s", "webm")
                pathlib.Path(path).write_bytes(b"audio")
                return {"requested_downloads": [{"filepath": path}], "heatmap": []}
        self.yt_dlp.YoutubeDL = FakeYDL

    def test_tries_youtubes_other_clients_until_one_works(self):
        self.fake_ydl(works_for="web_safari")
        meta, via = h.download_audio("dQw4w9WgXcQ", {})
        self.assertEqual(via, "web_safari")
        self.assertEqual(self.tried, [None, "mweb", "tv", "web_safari"])
        self.assertIsNotNone(h.audio_meta("dQw4w9WgXcQ"))       # cached for next time

    def test_a_reason_about_the_song_stops_at_once(self):
        self.fake_ydl(works_for="ios", error="This video is available to this channel's members on level: X")
        with self.assertRaises(RuntimeError) as ctx:
            h.download_audio("dQw4w9WgXcQ", {})
        self.assertEqual(self.tried, [None])
        self.assertIn("members", str(ctx.exception))

    def test_every_client_failing_reports_youtubes_reason(self):
        self.fake_ydl(works_for="nothing")
        with self.assertRaises(RuntimeError) as ctx:
            h.download_audio("dQw4w9WgXcQ", {})
        self.assertEqual(self.tried, h.AUDIO_CLIENTS)
        self.assertIn("not a bot", str(ctx.exception))

    def test_cached_audio_must_be_ours(self):
        os.makedirs(h.MIX_DIR)
        h.write_json_atomic(os.path.join(h.MIX_DIR, "dQw4w9WgXcQ.json"), {"audio": "../../etc/passwd"})
        self.assertIsNone(h.audio_meta("dQw4w9WgXcQ"))
        h.write_json_atomic(os.path.join(h.MIX_DIR, "dQw4w9WgXcQ.json"), {"audio": "audio-dQw4w9WgXcQ.webm"})
        self.assertIsNone(h.audio_meta("dQw4w9WgXcQ"))           # listed but not on disk
        pathlib.Path(h.MIX_DIR, "audio-dQw4w9WgXcQ.webm").write_bytes(b"x")
        self.assertIsNotNone(h.audio_meta("dQw4w9WgXcQ"))

    def test_lists_fall_back_to_an_old_copy_and_autoplay_to_saved_lists(self):
        h.CACHE_DIR = self.dir.name
        saved_fetch = h.fetch_tracks
        def broken(*a):
            raise RuntimeError("YouTube is down")
        h.fetch_tracks = broken
        try:
            song = lambda i: {"id": f"song{i:07d}", "title": f"S{i}", "artist": "", "duration": 100}
            old = {"title": "Radio", "items": [song(1), song(2)], "fetchedAt": 0}
            os.makedirs(os.path.dirname(h.tracks_cache_path("LM", "none")), exist_ok=True)
            h.write_json_atomic(h.tracks_cache_path("RDAMVMdQw4w9WgXcQ", "none"), old)
            self.assertEqual(h.load_tracks("RDAMVMdQw4w9WgXcQ", "none", max_age=60)["items"], old["items"])
            with self.assertRaises(RuntimeError):
                h.load_tracks("RDAMVMkJQP7kiw5Fk", "none", max_age=60, raise_errors=True)
            h.write_json_atomic(h.tracks_cache_path("LM", "none"), {"items": [song(1), song(3), song(4)]})
            ids = {t["id"] for t in h.backup_tracks("none", {"song0000001"})}
            self.assertEqual(ids, {"song0000003", "song0000004"})
        finally:
            h.fetch_tracks = saved_fetch


class Mirrors(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.saved = {k: getattr(h, k) for k in ("MIX_DIR", "MIRRORS_PATH", "http_json", "http_get", "decodes", "download_audio")}
        h.MIX_DIR = os.path.join(self.dir.name, "mix")
        h.MIRRORS_PATH = os.path.join(self.dir.name, "mirrors.json")
        self.old_config = os.environ.get("XDG_CONFIG_HOME")
        os.environ["XDG_CONFIG_HOME"] = self.dir.name
        os.makedirs(os.path.join(self.dir.name, "omarchy"))

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(h, k, v)
        if self.old_config is None:
            os.environ.pop("XDG_CONFIG_HOME", None)
        else:
            os.environ["XDG_CONFIG_HOME"] = self.old_config
        self.dir.cleanup()

    def settings(self, **entry):
        entry["id"] = h.PLUGIN_ID
        h.write_json_atomic(os.path.join(self.dir.name, "omarchy", "shell.json"),
                            {"bar": {"layout": {"left": [{"id": "omarchy.menu"}, entry]}}})

    def test_off_by_default_and_read_from_shell_json(self):
        self.assertFalse(h.mirrors_enabled())
        self.settings(backupMirrors="On")
        self.assertTrue(h.mirrors_enabled())

    def test_own_mirrors_parse_and_only_https(self):
        got = h.parse_mirrors("invidious:https://inv.example.org/, piped:https://api.example.net;"
                              " piped:http://insecure.example foo:https://x.example invidious:javascript:alert(1) invidious:https://x.example/?q=<b>")
        self.assertEqual(got, [{"kind": "invidious", "url": "https://inv.example.org"},
                               {"kind": "piped", "url": "https://api.example.net"}])

    def test_directories_parse_healthy_api_instances(self):
        inv = [["a", {"type": "https", "api": True, "uri": "https://a.example"}],
               ["b", {"type": "onion", "api": True, "uri": "http://b.onion"}],
               ["c", {"type": "https", "api": False, "uri": "https://c.example"}],
               ["d", {"type": "https", "api": None, "uri": "https://d.example"}]]
        self.assertEqual([m["url"] for m in h.parse_invidious_directory(inv)], ["https://a.example"])
        piped = [{"api_url": "https://p1.example", "uptime_24h": 50, "up_to_date": True},
                 {"api_url": "https://p2.example", "uptime_24h": 99.9, "up_to_date": True},
                 {"api_url": "https://p3.example", "uptime_24h": 100, "up_to_date": False}]
        self.assertEqual([m["url"] for m in h.parse_piped_directory(piped)], ["https://p2.example", "https://p1.example"])

    def test_own_list_wins_over_directories(self):
        self.settings(backupMirrors="On", mirrors="piped:https://mine.example")
        h.http_json = lambda *a, **k: self.fail("directories must not be fetched")
        self.assertEqual(h.mirror_list(), [{"kind": "piped", "url": "https://mine.example"}])

    def test_invidious_audio_must_come_through_the_mirror(self):
        formats = {"adaptiveFormats": [
            {"type": "video/mp4; codecs=avc1", "bitrate": "900000", "url": "/videoplayback?v"},
            {"type": "audio/mp4; codecs=\"mp4a\"", "bitrate": "128000", "url": "/videoplayback?m4a"},
            {"type": "audio/webm; codecs=\"opus\"", "bitrate": "160000", "url": "/videoplayback?opus"}]}
        h.http_json = lambda url, **k: formats
        url, ext = h.mirror_stream({"kind": "invidious", "url": "https://inv.example"}, "dQw4w9WgXcQ")
        self.assertEqual((url, ext), ("https://inv.example/videoplayback?opus", "webm"))
        formats["adaptiveFormats"][2]["url"] = "https://elsewhere.example/videoplayback?opus"
        with self.assertRaises(RuntimeError):
            h.mirror_stream({"kind": "invidious", "url": "https://inv.example"}, "dQw4w9WgXcQ")

    def test_piped_picks_best_https_audio(self):
        h.http_json = lambda url, **k: {"audioStreams": [
            {"mimeType": "audio/mp4", "bitrate": 130000, "url": "https://proxy.example/a"},
            {"mimeType": "audio/webm", "bitrate": 140000, "url": "http://proxy.example/b"}]}
        with self.assertRaises(RuntimeError):     # the best one isn't https
            h.mirror_stream({"kind": "piped", "url": "https://api.example"}, "dQw4w9WgXcQ")

    def test_tries_mirrors_in_turn_and_rejects_what_does_not_decode(self):
        calls = []
        def stream(m, vid):
            calls.append(m["url"])
            if m["url"] == "https://down.example":
                raise RuntimeError("timed out")
            return m["url"] + "/audio", "webm"
        saved_stream = h.mirror_stream
        h.mirror_stream = stream
        h.http_get = lambda url, *a, **k: (b"junk" if "junk" in url else b"audio", None)
        h.decodes = lambda path: open(path, "rb").read() == b"audio"
        try:
            mirrors = [{"kind": "piped", "url": u} for u in ("https://down.example", "https://junk.example", "https://good.example")]
            meta, via = h.download_from_mirrors("dQw4w9WgXcQ", mirrors)
        finally:
            h.mirror_stream = saved_stream
        self.assertEqual(via, "mirror:good.example")
        self.assertEqual(calls, ["https://down.example", "https://junk.example", "https://good.example"])
        self.assertEqual(os.listdir(h.MIX_DIR).count("audio-dQw4w9WgXcQ.webm.part"), 0)
        self.assertIsNotNone(h.audio_meta("dQw4w9WgXcQ"))

    def last_json(self, out):
        import json
        return json.loads(out.strip().splitlines()[-1])

    def run_fallback(self, youtube_reason):
        import io, contextlib
        def youtube_fails(*a, **k):
            raise RuntimeError(youtube_reason)
        h.download_audio = youtube_fails
        used = []
        saved = h.download_from_mirrors
        def from_mirrors(vid, *a, **k):
            used.append(vid)
            raise RuntimeError("all down")
        h.download_from_mirrors = from_mirrors
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out):
                h.cmd_fallback(["dQw4w9WgXcQ"])
        finally:
            h.download_from_mirrors = saved
        return used, out.getvalue()

    def test_fallback_uses_mirrors_only_when_on_and_not_hopeless(self):
        used, out = self.run_fallback("Sign in to confirm you're not a bot")
        self.assertEqual(used, [])                                 # off by default
        self.assertEqual(self.last_json(out)["mirrors"], "off")    # so the panel offers them
        self.settings(backupMirrors="On")
        used, out = self.run_fallback("The uploader has not made this video available in your country")
        self.assertEqual(used, ["dQw4w9WgXcQ"])                    # a region block: worth a mirror
        self.assertIn("mirrors: all down", out)
        used, out = self.run_fallback("This video is available to this channel's members on level: X")
        self.assertEqual(used, [])                                 # nothing serves members-only
        self.assertTrue(self.last_json(out)["hopeless"])


class Updates(unittest.TestCase):
    def setUp(self):
        import shutil
        if not shutil.which("git"):
            self.skipTest("git not installed")
        self.dir = tempfile.TemporaryDirectory()
        self.saved = (h.PLUGIN_DIR, h.UPDATE_CHECK_PATH)
        h.UPDATE_CHECK_PATH = os.path.join(self.dir.name, "update-check.json")

    def tearDown(self):
        h.PLUGIN_DIR, h.UPDATE_CHECK_PATH = self.saved
        self.dir.cleanup()

    def sh(self, *cmd, cwd=None):
        import subprocess
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
                   GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid")
        subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, env=env)

    def commit_version(self, repo, version, subject):
        pathlib.Path(repo, "manifest.json").write_text(json.dumps({"version": version}))
        self.sh("git", "add", "manifest.json", cwd=repo)
        self.sh("git", "commit", "-qm", subject, cwd=repo)

    def check(self):
        import io, contextlib
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            h.cmd_update_check(["--max-age", "0"])
        return json.loads(out.getvalue().strip().splitlines()[-1])

    def test_offers_a_newer_version_with_its_changes(self):
        d = self.dir.name
        origin, dev, user = (os.path.join(d, n) for n in ("origin.git", "dev", "user"))
        self.sh("git", "init", "-q", "--bare", "-b", "main", origin)
        self.sh("git", "clone", "-q", origin, dev)
        self.commit_version(dev, "0.5.0", "First")
        self.sh("git", "push", "-q", "origin", "HEAD:main", cwd=dev)
        self.sh("git", "clone", "-q", origin, user)          # what `omarchy plugin add` does
        h.PLUGIN_DIR = user
        self.assertEqual(self.check()["state"], "current")
        self.commit_version(dev, "0.5.1", "Fix playback after a YouTube change")
        self.sh("git", "push", "-q", "origin", "HEAD:main", cwd=dev)
        got = self.check()
        self.assertEqual((got["state"], got["version"], got["current"]), ("available", "0.5.1", "0.5.0"))
        self.assertEqual(got["notes"], ["Fix playback after a YouTube change"])

    def test_not_a_git_checkout(self):
        h.PLUGIN_DIR = self.dir.name
        self.assertEqual(self.check()["state"], "unmanaged")

    def test_versions_compare_numerically(self):
        self.assertGreater(h.version_tuple("0.10.0"), h.version_tuple("0.9.9"))
        self.assertEqual(h.version_tuple("1.2"), (1, 2, 0))


class ExploreAndDownload(unittest.TestCase):
    def runs(self, text):
        return {"runs": [{"text": text}]}

    def test_explore_items_normalize(self):
        song = {"musicResponsiveListItemRenderer": {
            "playlistItemData": {"videoId": "dQw4w9WgXcQ"},
            "flexColumns": [{"musicResponsiveListItemFlexColumnRenderer": {"text": self.runs("Never Gonna Give You Up")}},
                            {"musicResponsiveListItemFlexColumnRenderer": {"text": self.runs("Song • Rick Astley • Whenever • 3:33")}}]}}
        self.assertEqual(h.explore_item(song), {"kind": "song", "id": "dQw4w9WgXcQ", "title": "Never Gonna Give You Up",
                                                "artist": "Rick Astley", "duration": 213})
        album = {"musicTwoRowItemRenderer": {"title": self.runs("Album"), "subtitle": self.runs("Album • Band"),
                 "navigationEndpoint": {"browseEndpoint": {"browseId": "MPREb_x"}},
                 "thumbnailOverlay": {"x": {"playNavigationEndpoint": {"watchPlaylistEndpoint": {"playlistId": "OLAK5uy_abc"}}}}}}
        self.assertEqual(h.explore_item(album)["id"], "OLAK5uy_abc")
        chart = {"musicTwoRowItemRenderer": {"title": self.runs("Top 100"), "navigationEndpoint": {"browseEndpoint": {"browseId": "VLPL4fGSI1pDJn"}}}}
        self.assertEqual((h.explore_item(chart)["kind"], h.explore_item(chart)["id"]), ("list", "PL4fGSI1pDJn"))
        mood = {"musicNavigationButtonRenderer": {"buttonText": self.runs("Chill"),
                "clickCommand": {"browseEndpoint": {"browseId": "FEmusic_moods_and_genres_category", "params": "ggMPOg1uX1JOQWZFeDBy"}}}}
        self.assertEqual(h.explore_item(mood)["kind"], "mood")
        bad = {"musicNavigationButtonRenderer": {"buttonText": self.runs("X"),
               "clickCommand": {"browseEndpoint": {"browseId": "FEmusic_moods_and_genres_category", "params": "a b;rm"}}}}
        self.assertIsNone(h.explore_item(bad))
        self.assertIsNone(h.explore_item({"musicResponsiveListItemRenderer": {"playlistItemData": {"videoId": "short"}}}))

    def test_safe_filenames(self):
        self.assertEqual(h.safe_filename("AC/DC - Back in Black"), "AC DC - Back in Black")
        self.assertNotIn("/", h.safe_filename("../../etc/passwd"))
        self.assertFalse(h.safe_filename("../../etc/passwd").startswith("."))
        self.assertEqual(h.safe_filename("\x00\x07"), "song")
        self.assertLessEqual(len(h.safe_filename("й" * 500).encode()), 180)

    def test_download_refuses_bad_input(self):
        import io, contextlib
        for args in (["bad"], ["dQw4w9WgXcQ", "--format", "exe"], ["dQw4w9WgXcQ", "--dir", "/nonexistent/folder"]):
            out = io.StringIO()
            with contextlib.redirect_stdout(out), self.assertRaises(SystemExit):
                h.cmd_download(args)
            self.assertIn('"error"', out.getvalue())


class Downloads(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.saved = (h.DOWNLOADS_PATH, h.COVERS_DIR)
        h.DOWNLOADS_PATH = os.path.join(self.dir.name, "downloads.json")
        h.COVERS_DIR = os.path.join(self.dir.name, "covers")
        os.makedirs(h.COVERS_DIR)

    def tearDown(self):
        h.DOWNLOADS_PATH, h.COVERS_DIR = self.saved
        self.dir.cleanup()

    def test_lists_files_that_still_exist_newest_first_and_plays_them(self):
        a = os.path.join(self.dir.name, "A.mp3")
        b = os.path.join(self.dir.name, "B.opus")
        pathlib.Path(a).write_bytes(b"x")
        pathlib.Path(b).write_bytes(b"x")
        cover = os.path.join(h.COVERS_DIR, "dQw4w9WgXcQ.jpg")
        pathlib.Path(cover).write_bytes(b"x")
        h.record_download({"id": "dQw4w9WgXcQ", "title": "A", "artist": "X", "duration": 200, "path": a, "cover": cover})
        h.record_download({"id": "kJQP7kiw5Fk", "title": "B", "artist": "Y", "duration": 100, "path": b, "cover": None})
        h.record_download({"id": "kJQP7kiw5Fk", "title": "Gone", "artist": "", "duration": None,
                           "path": os.path.join(self.dir.name, "deleted.mp3"), "cover": "/etc/passwd"})
        got = h.downloaded_tracks()
        self.assertEqual([t["title"] for t in got], ["B", "A"])          # newest first, deleted file gone
        self.assertEqual(got[1]["cover"], cover)
        self.assertIsNone(got[0]["cover"])
        self.assertEqual(h.track_url(got[1]), a)                         # plays the file
        self.assertTrue(h.track_url({"id": "dQw4w9WgXcQ"}).startswith("https://music.youtube.com/"))
        h.record_download({"id": "dQw4w9WgXcQ", "title": "A again", "artist": "X", "duration": 200, "path": a, "cover": cover})
        self.assertEqual([t["title"] for t in h.downloaded_tracks()], ["A again", "B"])   # same file, one entry


class Services(unittest.TestCase):
    def test_track_keys_and_lists(self):
        for key in ("dQw4w9WgXcQ", "sc:forss/flickermood", "sc:417474360", "sp:4uLU6hMCjMI75M1A2tKUQC"):
            self.assertTrue(h.TRACK_KEY_RE.match(key), key)
        for bad in ("sc:../etc", "sp:short", "sc:a/b/c", "yt:dQw4w9WgXcQ"):
            self.assertFalse(h.TRACK_KEY_RE.match(bad), bad)
        for lid in ("LM", "sc:likes:forss", "sc:set:forss/ecclesia", "sp:liked", "sp:pl:37i9dQZF1DXcBWIGoYBM5M", "mix:all", "mix:fa9e05eb"):
            self.assertTrue(h.is_list_id(lid), lid)
        self.assertFalse(h.is_list_id("sc:set:a/b/../c"))
        self.assertEqual(h.source_of("sp:4uLU6hMCjMI75M1A2tKUQC"), "sp")

    def test_soundcloud_urls(self):
        self.assertEqual(h.sc_user("https://soundcloud.com/forss"), "forss")
        self.assertEqual(h.sc_user("forss"), "forss")
        self.assertEqual(h.sc_user("https://evil.example/forss"), "")
        self.assertEqual(h.sc_track_key("https://soundcloud.com/joeypecoraro/warm"), "sc:joeypecoraro/warm")
        self.assertEqual(h.sc_track_key("https://soundcloud.com/lordafi/sets/acid-jazz"), "")       # a set, not a track
        self.assertEqual(h.sc_track_key("https://api.soundcloud.com/tracks/soundcloud%3Atracks%3A417474360"), "sc:417474360")
        self.assertEqual(h.track_url({"id": "sc:417474360"}), "https://api.soundcloud.com/tracks/417474360")
        self.assertEqual(h.track_url({"id": "sp:4uLU6hMCjMI75M1A2tKUQC"}), "ytmusic-spotify://4uLU6hMCjMI75M1A2tKUQC")

    def test_spotify_track_objects(self):
        obj = {"type": "track", "id": "4uLU6hMCjMI75M1A2tKUQC", "name": "Never Gonna Give You Up",
               "artists": [{"name": "Rick Astley"}], "duration_ms": 213573, "external_ids": {"isrc": "GBARL9300135"},
               "album": {"images": [{"url": "https://i.scdn.co/image/ab67616d0000b273", "width": 640},
                                    {"url": "https://i.scdn.co/image/ab67616d00001e02", "width": 300}]}}
        saved = h.SP_TRACKS_PATH
        with tempfile.TemporaryDirectory() as d:
            h.SP_TRACKS_PATH = os.path.join(d, "t.json")
            try:
                t = h.sp_track(obj)
            finally:
                h.SP_TRACKS_PATH = saved
        self.assertEqual((t["id"], t["artist"], t["duration"], t["isrc"]), ("sp:4uLU6hMCjMI75M1A2tKUQC", "Rick Astley", 213, "GBARL9300135"))
        self.assertEqual(t["cover"], "https://i.scdn.co/image/ab67616d00001e02")
        self.assertIsNone(h.sp_track({"type": "episode", "id": "4uLU6hMCjMI75M1A2tKUQC"}))

    def test_matching_prefers_the_same_song(self):
        want = {"title": "Never Gonna Give You Up", "artist": "Rick Astley", "duration": 213}
        right = {"title": "Never Gonna Give You Up", "artist": "Rick Astley", "duration": 214}
        cover = {"title": "Never Gonna Give You Up (Cover)", "artist": "Some Band", "duration": 180}
        live = {"title": "Never Gonna Give You Up (Live)", "artist": "Rick Astley", "duration": 290}
        self.assertGreater(h.match_score(want, right), h.match_score(want, cover))
        self.assertGreater(h.match_score(want, right), h.match_score(want, live))

    def test_mixes_and_my_mix(self):
        with tempfile.TemporaryDirectory() as d:
            saved = (h.MIXES_PATH, h.DATA_DIR, h.CACHE_DIR, h.widget_settings)
            h.MIXES_PATH, h.DATA_DIR, h.CACHE_DIR = os.path.join(d, "mixes.json"), d, d
            h.widget_settings = lambda: {"soundcloudUser": "forss"}
            os.makedirs(os.path.join(d, "tracks"))
            try:
                import io, contextlib
                def run(fn, args):
                    out = io.StringIO()
                    with contextlib.redirect_stdout(out):
                        fn(args)
                    return json.loads(out.getvalue().strip().splitlines()[-1])
                made = run(h.cmd_mix_add, ["new", "--title", "Road trip", "--track",
                                           json.dumps({"id": "dQw4w9WgXcQ", "title": "A", "cover": "https://evil.example/x.jpg"})])
                mix = made["id"]
                self.assertTrue(h.MIX_ID_RE.match(mix))
                run(h.cmd_mix_add, [mix, "--track", json.dumps({"id": "sc:joeypecoraro/warm", "title": "Warm"})])
                again = run(h.cmd_mix_add, [mix, "--track", json.dumps({"id": "sc:joeypecoraro/warm", "title": "Warm"})])
                self.assertTrue(again["already"])
                items = h.mix_tracks(mix, "none")["items"]
                self.assertEqual([t["id"] for t in items], ["dQw4w9WgXcQ", "sc:joeypecoraro/warm"])
                self.assertNotIn("cover", items[0])                                  # only known cover hosts
                run(h.cmd_mix_remove, [mix, "dQw4w9WgXcQ"])
                self.assertEqual([t["id"] for t in h.mix_tracks(mix, "none")["items"]], ["sc:joeypecoraro/warm"])
                with self.assertRaises(SystemExit), contextlib.redirect_stdout(io.StringIO()):
                    h.cmd_mix_add([mix, "--track", json.dumps({"id": "../../etc"})])
                # My Mix alternates the services and keeps its order all day.
                h.write_json_atomic(h.tracks_cache_path("LM", "none"), {"items": [{"id": f"yt{i:09d}", "title": str(i)} for i in range(3)]})
                h.write_json_atomic(h.tracks_cache_path("sc:likes:forss", "none"), {"items": [{"id": f"sc:u/t{i}", "title": str(i)} for i in range(3)]})
                first = [t["id"] for t in h.liked_everywhere("none")]
                self.assertEqual(len(first), 6)
                self.assertEqual([h.source_of(k) for k in first], ["yt", "sc"] * 3)
                self.assertEqual(first, [t["id"] for t in h.liked_everywhere("none")])
            finally:
                h.MIXES_PATH, h.DATA_DIR, h.CACHE_DIR, h.widget_settings = saved


@unittest.skipUnless(h.shutil_which("rclone") and h.shutil_which("ffmpeg"), "needs rclone and ffmpeg")
class Cloud(unittest.TestCase):
    """Your own storage through rclone, against a local folder remote."""

    def setUp(self):
        import subprocess
        self.dir = tempfile.TemporaryDirectory()
        d = self.dir.name
        self.store = os.path.join(d, "store")
        album = os.path.join(self.store, "Artist A", "Album One")
        os.makedirs(album)
        os.makedirs(os.path.join(self.store, "Artist B - Two"))
        for path, freq in ((os.path.join(album, "01 - Song One.mp3"), 440),
                           (os.path.join(album, "02 Song Two.flac"), 550),
                           (os.path.join(self.store, "Artist B - Two", "Track Three.ogg"), 660)):
            subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", f"sine=frequency={freq}:duration=3", path],
                           check=True)
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "color=c=red:s=64x64:d=1",
                        "-frames:v", "1", os.path.join(album, "cover.jpg")], check=True)
        pathlib.Path(self.store, "notes.txt").write_text("not music")
        self.conf = os.path.join(d, "rclone.conf")
        pathlib.Path(self.conf).write_text("[lib]\ntype = local\n")
        self.env_saved = os.environ.get("RCLONE_CONFIG")
        os.environ["RCLONE_CONFIG"] = self.conf
        self.saved = {k: getattr(h, k) for k in ("CLOUD_PATH", "CLOUD_DIR", "COVERS_DIR", "CLOUD_SERVER_PATH",
                                                 "CLOUD_LOG", "DATA_DIR", "MIX_DIR", "PID_PATH")}
        h.DATA_DIR = os.path.join(d, "data")
        h.CLOUD_PATH = os.path.join(d, "data", "cloud.json")
        h.CLOUD_DIR = os.path.join(d, "cloud")
        h.COVERS_DIR = os.path.join(d, "covers")
        h.CLOUD_SERVER_PATH = os.path.join(d, "server.json")
        h.CLOUD_LOG = os.path.join(d, "rclone.log")
        h.MIX_DIR = os.path.join(d, "mix")
        h.PID_PATH = os.path.join(d, "mpv.pid")
        h.write_cloud([{"id": "0a1b2c3d", "remote": "lib", "path": self.store, "kind": "remote", "title": "Lib", "created": False}])

    def tearDown(self):
        h.stop_cloud_server()
        for k, v in self.saved.items():
            setattr(h, k, v)
        if self.env_saved is None:
            os.environ.pop("RCLONE_CONFIG", None)
        else:
            os.environ["RCLONE_CONFIG"] = self.env_saved
        self.dir.cleanup()

    def test_keys_and_lists(self):
        self.assertTrue(h.TRACK_KEY_RE.match("cl:0a1b2c3d/0123456789abcdef"))
        self.assertFalse(h.TRACK_KEY_RE.match("cl:0a1b2c3d/../etc"))
        for lid in ("cl:0a1b2c3d", "cl:0a1b2c3d:0123456789abcdef"):
            self.assertTrue(h.is_list_id(lid), lid)
        self.assertEqual(h.source_of("cl:0a1b2c3d/0123456789abcdef"), "cl")
        self.assertEqual(h.track_url({"id": "cl:0a1b2c3d/0123456789abcdef"}), "ytmusic-cloud://0a1b2c3d/0123456789abcdef")
        self.assertEqual(h.mix_entry("ytmusic-cloud://0a1b2c3d/0123456789abcdef")[0], "cl:0a1b2c3d/0123456789abcdef")

    def test_names_from_paths(self):
        self.assertEqual(h.cloud_names("Artist A/Album One/01 - Song One.mp3"), ("Song One", "Artist A", "Album One"))
        self.assertEqual(h.cloud_names("Artist A/Album One/02 Song Two.flac"), ("Song Two", "Artist A", "Album One"))
        self.assertEqual(h.cloud_names("Mixed/Daft Punk - One More Time.mp3"), ("One More Time", "Daft Punk", "Mixed"))
        self.assertEqual(h.cloud_names("Band - Album/1-03 Intro.m4a"), ("Intro", "Band", "Band - Album"))
        self.assertEqual(h.cloud_names("song.mp3"), ("song", "", ""))

    def test_index_lists_and_tracks(self):
        src = h.read_cloud()[0]
        index = h.cloud_index(src)
        self.assertEqual(sorted(t["title"] for t in index["tracks"]), ["Song One", "Song Two", "Track Three"])
        lists = h.cloud_lists(src, index)
        self.assertEqual(lists[0]["id"], "cl:0a1b2c3d")
        self.assertEqual(lists[0]["count"], 3)
        album = next(l for l in lists if l["title"] == "Album One")
        self.assertTrue(os.path.isfile(album["cover"]))             # the folder's cover.jpg, copied
        self.assertEqual(os.path.dirname(album["cover"]), h.COVERS_DIR)
        got = h.cloud_tracks(album["id"])
        self.assertEqual([t["title"] for t in got["items"]], ["Song One", "Song Two"])
        self.assertEqual(got["items"][0]["cover"], album["cover"])
        for t in got["items"]:
            self.assertTrue(h.TRACK_KEY_RE.match(t["id"]))

    def test_served_read_only_with_a_password_and_stopped(self):
        import urllib.request, urllib.error, base64
        src = h.read_cloud()[0]
        key = next(t["id"] for t in h.cloud_index(src)["tracks"] if t["title"] == "Track Three")
        url = h.cloud_stream_url(key)
        parts = urllib.parse.urlsplit(url)
        self.assertEqual(parts.hostname, "127.0.0.1")
        state = h.read_json(h.CLOUD_SERVER_PATH)
        self.assertEqual(os.stat(h.CLOUD_SERVER_PATH).st_mode & 0o777, 0o600)
        with open(f"/proc/{state['pid']}/cmdline", "rb") as fh:
            self.assertNotIn(state["pass"].encode(), fh.read())        # never on a command line
        plain = urllib.parse.urlunsplit((parts.scheme, f"127.0.0.1:{parts.port}", parts.path, "", ""))
        with self.assertRaises(urllib.error.HTTPError) as err:
            urllib.request.urlopen(plain, timeout=10)
        self.assertEqual(err.exception.code, 401)
        req = urllib.request.Request(plain, headers={"Authorization": "Basic " + base64.b64encode(
            f"{parts.username}:{parts.password}".encode()).decode()})
        with urllib.request.urlopen(req, timeout=10) as r:
            self.assertEqual(r.read(4), b"OggS")
        put = urllib.request.Request(plain.rsplit("/", 1)[0] + "/new.mp3", data=b"x", method="PUT",
                                     headers=dict(req.header_items()))
        with self.assertRaises(urllib.error.HTTPError):
            urllib.request.urlopen(put, timeout=10)
        self.assertEqual(h.cloud_stream_url(key), url)                 # reused while it runs
        h.stop_cloud_server()
        time.sleep(0.3)
        self.assertFalse(h.pid_is_rclone_server(state["pid"]))

    def test_peak_mix_and_download_copy_the_file(self):
        src = h.read_cloud()[0]
        key = h.cloud_index(src)["tracks"][0]["id"]
        meta, via = h.download_audio(key, {})
        self.assertEqual(via, "cloud")
        self.assertTrue(os.path.isfile(os.path.join(h.MIX_DIR, meta["audio"])))
        self.assertNotIn("-", h.cache_name(key))       # segment names stay unambiguous
        self.assertNotIn("-", h.cache_name("sc:forss/flickermood"))

    def test_new_remote_is_written_safely(self):
        h.write_remote("omarchy-music-sftp", "sftp", {"host": "nas.local", "user": "me", "pass": "hunter2"})
        text = pathlib.Path(self.conf).read_text()
        self.assertIn("[omarchy-music-sftp]\ntype = sftp\nhost = nas.local\nuser = me\npass = ", text)
        self.assertNotIn("hunter2", text)                              # stored obscured, like rclone does
        with self.assertRaises(RuntimeError):
            h.write_remote("x", "webdav", {"url": "http://a\n[evil]\ntype = local"})
        with self.assertRaises(RuntimeError):
            h.write_remote("x", "sftp", {"user": "me"})                # host is needed
        h.write_remote("omarchy-music-s3", "s3", {"access_key_id": "AK", "secret_access_key": "SK"})
        self.assertIn("provider = AWS", pathlib.Path(self.conf).read_text())
        pathlib.Path(self.conf).write_text("# Encrypted rclone configuration File\n\nRCLONE_ENCRYPT_V0:\nabc")
        with self.assertRaises(RuntimeError):
            h.write_remote("y", "ftp", {"host": "a"})

    def test_add_and_remove_through_the_command(self):
        import subprocess
        d = self.dir.name
        env = dict(os.environ, XDG_DATA_HOME=os.path.join(d, "xdata"), XDG_CACHE_HOME=os.path.join(d, "xcache"),
                   XDG_RUNTIME_DIR=os.path.join(d, "xrun"), RCLONE_CONFIG=self.conf)
        def run(*args, stdin=""):
            proc = subprocess.run([sys.executable, "-I", str(HELPER), *args], input=stdin, capture_output=True,
                                  text=True, env=env, timeout=120)
            return [json.loads(l) for l in proc.stdout.splitlines()]
        out = run("cloud-add", stdin=json.dumps({"kind": "remote", "remote": "lib", "path": self.store, "title": "Mine"}) + "\n")
        self.assertEqual(out[-1]["state"], "added")
        src = out[-1]["id"]
        lists = [m for m in run("playlists", "--service", "cl") if m["type"] == "playlists"][-1]["items"]
        self.assertEqual(lists[0]["id"], f"cl:{src}")
        bad = run("cloud-add", stdin=json.dumps({"kind": "remote", "remote": "lib", "path": self.store + "/missing"}) + "\n")
        self.assertEqual(bad[-1]["type"], "error")
        self.assertIn("storage", bad[-1]["message"])
        self.assertEqual(run("cloud-remove", src)[-1]["state"], "removed")
        self.assertEqual(run("playlists", "--service", "cl")[-1].get("setup"), "cl")
        self.assertIn("[lib]", pathlib.Path(self.conf).read_text())   # a remote we didn't make stays

    def test_redact_hides_the_server_and_files(self):
        out = h.redact("open http://u12ab:deadbeefcafe@127.0.0.1:43210/0a1b2c3d/My%20Band/Song.flac failed; "
                       "ytmusic-cloud://0a1b2c3d/0123456789abcdef")
        for leak in ("deadbeefcafe", "My%20Band", "0123456789abcdef"):
            self.assertNotIn(leak, out)


class Lyrics(unittest.TestCase):
    def test_lrc_lines_in_time_order(self):
        text = "[ar:Someone]\n[00:20.21] First\n[00:05.5][01:02.00]Twice\n[1:03.250]Last\x07one\nno stamp"
        self.assertEqual(h.parse_lrc(text), [[5.5, "Twice"], [20.21, "First"], [62.0, "Twice"], [63.25, "Last one"]])

    def test_names_from_youtube_titles(self):
        self.assertEqual(h.lyric_names("Luis Fonsi - Despacito (Official Music Video) ft. Daddy Yankee", "LuisFonsiVEVO")[0],
                         ("Luis Fonsi", "Despacito ft. Daddy Yankee"))
        self.assertEqual(h.lyric_names("Herr Mannelig", "SKÁLD - Topic"), [("SKÁLD", "Herr Mannelig")])
        self.assertEqual(h.lyric_names("Sinklars Vise in Middle Scots | Norwegian folk song", "The Skaldic Bard"),
                         [("The Skaldic Bard", "Sinklars Vise in Middle Scots")])

    def test_picks_the_same_song(self):
        results = [{"trackName": "Despacito", "artistName": "Someone Else", "duration": 100, "syncedLyrics": "[00:01.00]x"},
                   {"trackName": "Despacito", "artistName": "Luis Fonsi", "duration": 229, "syncedLyrics": "[00:01.00]y"},
                   {"trackName": "Other", "artistName": "Luis Fonsi", "duration": 229}]
        self.assertEqual(h.best_lyrics(results, "Luis Fonsi", "Despacito", 228)["artistName"], "Luis Fonsi")
        self.assertIsNone(h.best_lyrics([{"trackName": "Nope", "artistName": "Nobody", "duration": 10}], "Luis Fonsi", "Despacito", 228))



def has_numpy():
    try:
        import numpy  # noqa: F401
        return True
    except ImportError:
        return False


@unittest.skipUnless(has_numpy() and h.shutil_which("ffmpeg"), "needs numpy and ffmpeg")
class Chords(unittest.TestCase):
    def test_hears_the_chords_of_a_synthetic_song(self):
        import subprocess
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "song.wav")
            # 6 s of C major (C4 E4 G4 and a C3 bass), then 6 s of A minor.
            def triad(freqs):
                return "+".join(f"0.25*sin(2*PI*{f}*t)" for f in freqs)
            expr = f"if(lt(t,6),{triad([130.81, 261.63, 329.63, 392.0])},{triad([110.0, 220.0, 261.63, 329.63])})"
            subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i",
                            f"aevalsrc='{expr}':s=22050:d=12", path], check=True)
            segments, key = h.detect_chords(*h.chroma_of(path))
        names = [s[2] for s in segments if s[1] - s[0] > 2]
        self.assertEqual(names, ["C", "Am"])
        self.assertAlmostEqual([s for s in segments if s[2] == "Am"][0][0], 6.0, delta=1.0)
        self.assertIn(key, ("C major", "A minor"))

    def test_score_links_are_only_the_three_sites(self):
        for good in ("https://www.songsterr.com/a/wsa/sabaton-berserker-tab-s7835130",
                     "https://musescore.com/sheetmusic?text=Sabaton%20Berserker",
                     "https://www.ultimate-guitar.com/search.php?search_type=title&value=Sabaton%20Berserker"):
            self.assertTrue(h.SCORE_URL_RE.match(good), good)
        for bad in ("https://evil.example/tab-s1", "file:///etc/passwd", "https://musescore.com/sheetmusic?text=a b;rm"):
            self.assertFalse(h.SCORE_URL_RE.match(bad), bad)



class Radio(unittest.TestCase):
    UUID = "1c6dcd6f-88c6-4fd4-8191-078435168e85"

    def test_station_as_a_track(self):
        track, url = h.radio_station({"stationuuid": self.UUID, "name": "BBC Radio 6 Music\n", "url_resolved": "https://a.example/live.aac",
                                      "tags": "indie,rock,alt,extra", "countrycode": "GB", "codec": "AAC", "bitrate": 128,
                                      "favicon": "https://a.example/logo.png"})
        self.assertEqual(track["id"], "rd:" + self.UUID)
        self.assertEqual(track["title"], "BBC Radio 6 Music")
        self.assertEqual(track["artist"], "indie, rock, alt · GB · AAC 128")
        self.assertEqual(url, "https://a.example/live.aac")
        self.assertTrue(h.TRACK_KEY_RE.match(track["id"]))
        for bad in ({"stationuuid": "x", "url_resolved": "https://a"}, {"stationuuid": self.UUID, "url_resolved": "javascript:x"},
                    {"stationuuid": self.UUID, "url_resolved": "https://a b"}):
            self.assertEqual(h.radio_station(bad), (None, None))

    def test_lists(self):
        for lid in ("rd:fav", "rd:top", "rd:vote", "rd:search", "rd:country:DE", "rd:tag:hip-hop"):
            self.assertTrue(h.is_list_id(lid), lid)
        self.assertFalse(h.is_list_id("rd:tag:../x"))
        self.assertEqual(h.radio_list_query("rd:tag:hip-hop")[1]["tag"], "hip hop")
        self.assertEqual(h.radio_list_query("rd:country:DE")[1]["countrycode"], "DE")
        self.assertEqual(h.track_url({"id": "rd:" + self.UUID}), "ytmusic-radio://" + self.UUID)
        self.assertEqual(h.source_of("rd:" + self.UUID), "rd")


def capture(fn, args):
    import contextlib
    import io
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        fn(args)
    return [json.loads(line) for line in out.getvalue().splitlines()]


class SoundCloudCovers(unittest.TestCase):
    def test_covers_from_search_thumbnails(self):
        items = h.sc_items({"entries": [{"url": "https://api.soundcloud.com/tracks/soundcloud%3Atracks%3A945191926",
                                         "title": "X", "uploader": "Lucabn't", "thumbnails": [
                                             {"id": "mini", "url": "https://i1.sndcdn.com/artworks-Gz-HoUyKA-mini.jpg"},
                                             {"id": "t300x300", "url": "https://i1.sndcdn.com/artworks-Gz-HoUyKA-t300x300.jpg"}]},
                                        {"url": "https://soundcloud.com/kggn/skytearer", "title": "skytearer",
                                         "thumbnails": [{"id": "t300x300", "url": "https://evil.example/x.jpg"}]}]})
        self.assertEqual(items[0]["cover"], "https://i1.sndcdn.com/artworks-Gz-HoUyKA-t300x300.jpg")
        self.assertNotIn("cover", items[1])

    def test_likes_get_cover_and_artist_from_oembed_once(self):
        calls = []
        saved = (h.SC_META_PATH, h.http_json)
        with tempfile.TemporaryDirectory() as d:
            h.SC_META_PATH = os.path.join(d, "meta.json")
            h.http_json = lambda url, max_bytes=0, timeout=0: calls.append(url) or {
                "author_name": "kuru", "thumbnail_url": "https://i1.sndcdn.com/artworks-RQH2KPnushgBas2T-epCnaA-t500x500.jpg"}
            try:
                items = [{"id": "sc:kggn/skytearer", "title": "skytearer", "artist": "kggn"}]
                out = h.with_sc_meta(items)
                self.assertEqual(out[0]["artist"], "kuru")
                self.assertEqual(out[0]["cover"], "https://i1.sndcdn.com/artworks-RQH2KPnushgBas2T-epCnaA-t300x300.jpg")
                self.assertIn("url=https%3A%2F%2Fsoundcloud.com%2Fkggn%2Fskytearer", calls[0])
                h.with_sc_meta(items)
                self.assertEqual(len(calls), 1)
            finally:
                h.SC_META_PATH, h.http_json = saved


class CoversEverywhere(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = (h.COVERS_DIR, h.HISTORY_PATH, h.DATA_DIR, h.DZ_TRACKS_PATH)
        h.COVERS_DIR = os.path.join(self.tmp.name, "covers")
        os.makedirs(h.COVERS_DIR)
        h.DATA_DIR = self.tmp.name
        h.HISTORY_PATH = os.path.join(self.tmp.name, "history.jsonl")
        h.DZ_TRACKS_PATH = os.path.join(self.tmp.name, "dz.json")

    def tearDown(self):
        h.COVERS_DIR, h.HISTORY_PATH, h.DATA_DIR, h.DZ_TRACKS_PATH = self.saved
        self.tmp.cleanup()

    def test_valid_cover(self):
        local = os.path.join(h.COVERS_DIR, "au-V66vyPP.jpg")
        pathlib.Path(local).write_bytes(b"x")
        self.assertEqual(h.valid_cover(local), os.path.realpath(local))
        self.assertEqual(h.valid_cover("https://cdn-images.dzcdn.net/images/cover/" + "a" * 32 + "/250x250-000000-80-0-0.jpg")[:8], "https://")
        self.assertEqual(h.valid_cover("https://thumbnailer.mixcloud.com/unsafe/300x300/extaudio/a/b"), "https://thumbnailer.mixcloud.com/unsafe/300x300/extaudio/a/b")
        outside = os.path.join(self.tmp.name, "x.jpg")
        pathlib.Path(outside).write_bytes(b"x")
        for bad in (outside, "https://evil.example/a.jpg", os.path.join(h.COVERS_DIR, "missing.jpg"), None, 3):
            self.assertEqual(h.valid_cover(bad), "", bad)

    def test_mixes_keep_any_services_cover(self):
        local = os.path.join(h.COVERS_DIR, "rd-x.png")
        pathlib.Path(local).write_bytes(b"x")
        dz = "https://cdn-images.dzcdn.net/images/cover/" + "b" * 32 + "/250x250-000000-80-0-0.jpg"
        self.assertEqual(h.clean_track({"id": "dz:1", "title": "a", "cover": dz})["cover"], dz)
        self.assertEqual(h.clean_track({"id": "au:abc", "title": "a", "cover": local})["cover"], os.path.realpath(local))
        self.assertNotIn("cover", h.clean_track({"id": "au:abc", "title": "a", "cover": "/etc/passwd"}))

    def test_recently_played_has_covers(self):
        dz = "https://cdn-images.dzcdn.net/images/cover/" + "c" * 32 + "/250x250-000000-80-0-0.jpg"
        h.write_json_atomic(h.DZ_TRACKS_PATH, {"dz:2": {"title": "old", "cover": dz}})
        with open(h.HISTORY_PATH, "w") as fh:
            fh.write(json.dumps({"t": 1, "id": "dz:2", "title": "old", "played": 200, "duration": 200}) + "\n")
            fh.write(json.dumps({"t": 2, "id": "dz:3", "title": "new", "played": 200, "duration": 200, "cover": dz}) + "\n")
        recent = {t["id"]: t for t in h.recent_tracks()}
        self.assertEqual(recent["dz:2"]["cover"], dz)
        self.assertEqual(recent["dz:3"]["cover"], dz)

    def test_embedded_cover_of_a_local_folder(self):
        import shutil
        import subprocess
        if not shutil.which("ffmpeg"):
            self.skipTest("ffmpeg")
        music = os.path.join(self.tmp.name, "music", "Band", "Album")
        os.makedirs(music)
        art = os.path.join(self.tmp.name, "art.png")
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=c=red:s=64x64", "-frames:v", "1", art], check=True)
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=duration=1", "-i", art, "-map", "0:a", "-map", "1:v",
                        "-c:v", "mjpeg", "-disposition:v:0", "attached_pic", os.path.join(music, "01 - Song.mp3")], check=True)
        src = {"id": "0a1b2c3d", "kind": "local", "remote": "", "path": os.path.join(self.tmp.name, "music")}
        idx = h.index_entries(src, h.local_entries(src["path"]))
        self.assertTrue(os.path.isfile(idx["covers"]["Band/Album"]))


class AppleMusic(unittest.TestCase):
    def test_art_ids_and_links(self):
        self.assertEqual(h.am_art("https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/1d/1b/f9/x/26UMGIM39303.rgb.jpg/{w}x{h}bb.{f}"),
                         "https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/1d/1b/f9/x/26UMGIM39303.rgb.jpg/300x300bb.jpg")
        self.assertTrue(h.am_art("https://is1-ssl.mzstatic.com/image/thumb/Music/x/cover.jpg/100x100bb.jpg").endswith("/cover.jpg/300x300bb.jpg"))
        self.assertIsNone(h.am_art("https://evil.example/x/100x100bb.jpg"))
        t = h.am_song("1460471576", "Ghost Love Score", "Nightwish", 602000)
        self.assertEqual((t["id"], t["duration"]), ("am:1460471576", 602))
        self.assertTrue(h.TRACK_KEY_RE.match(t["id"]))
        self.assertEqual(h.track_url(t), "ytmusic-apple://1460471576")
        self.assertEqual(h.mix_entry("ytmusic-apple://1460471576")[0], "am:1460471576")
        for lid in ("am:top", "am:search", "am:al:1460471435", "am:pl:pl.f4d106fed2bd41149aaacabb233eb5eb"):
            self.assertTrue(h.is_list_id(lid), lid)
        self.assertTrue(h.AM_LINK_RE.match("https://music.apple.com/us/playlist/todays-hits/pl.f4d106fed2bd41149aaacabb233eb5eb"))
        self.assertTrue(h.AM_LINK_RE.match("https://music.apple.com/ru/album/once/1460471435?i=1460471576"))
        for bad in ("https://evil.example/us/playlist/x/pl.f4d106fed2bd4114", "https://music.apple.com/us/artist/x/123"):
            self.assertIsNone(h.AM_LINK_RE.match(bad), bad)

    def test_playlist_page(self):
        page = json.dumps({"data": [{"data": {"sections": [{"items": [
            {"title": "stupid song", "artistName": "Olivia Rodrigo", "duration": 209680,
             "contentDescriptor": {"kind": "song", "identifiers": {"storeAdamID": "1889992115"}},
             "artwork": {"dictionary": {"url": "https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/a/b.jpg/{w}x{h}bb.{f}"}}},
            {"title": "Album", "contentDescriptor": {"kind": "album", "identifiers": {"storeAdamID": "1"}}}]}]}}]})
        body = ('<html><title>&lrm;Today&#8217;s Hits - Playlist - Apple Music</title>'
                '<script type="application/json" id="serialized-server-data">' + page + '</script></html>').encode()
        saved = h.http_get
        h.http_get = lambda url, max_bytes, timeout=15, accept="": (body, None)
        try:
            title, songs = h.am_playlist_page("https://music.apple.com/us/playlist/x/pl.f4d106fed2bd4114")
        finally:
            h.http_get = saved
        self.assertEqual(title, "Today\u2019s Hits")
        self.assertEqual([s["id"] for s in songs], ["am:1889992115"])
        self.assertEqual(songs[0]["duration"], 209)
        self.assertTrue(songs[0]["cover"].endswith("/300x300bb.jpg"))


class AiLanguages(unittest.TestCase):
    def test_setting_and_prompt_rule(self):
        self.assertEqual(h.ai_languages("RU, en ,xx,ru,instrumental"), ["ru", "en", "instrumental"])
        self.assertEqual(h.languages_line([]), "")
        self.assertTrue(h.languages_line(["ru"]).startswith("Only songs sung in Russian."))
        self.assertTrue(h.languages_line(["ru", "en", "de"]).startswith("Only songs sung in Russian, English or German."))
        self.assertTrue(h.languages_line(["instrumental"]).startswith("Only instrumental music"))
        self.assertIn("or instrumental music", h.languages_line(["ja", "instrumental"]))

    def test_the_rule_reaches_the_ai(self):
        asked = []
        saved = (h.taste_profile, h.ask_agent)
        h.taste_profile = lambda browser="none": {"plays": 20, "likes": 3, "mostPlayed": [], "liked": [], "topArtists": ["Wardruna"]}

        def ask(prompt):
            asked.append(prompt)
            raise RuntimeError("stop here")
        h.ask_agent = ask
        try:
            out = []
            try:
                out = capture(h.cmd_ai_mix, ["--languages", "ru,instrumental"])
            except SystemExit:
                pass
        finally:
            h.taste_profile, h.ask_agent = saved
        self.assertIn("Only songs sung in Russian, or instrumental music without singing.", asked[0])


class ServicePages(unittest.TestCase):
    def test_fixed_https_pages(self):
        for name, url in h.SERVICE_PAGES.items():
            self.assertTrue(url.startswith("https://"), name)
        for name in ("sc", "sc-profile", "dz", "dz-profile"):
            self.assertIn(name, h.SERVICE_PAGES)


class Deezer(unittest.TestCase):
    def test_profile_links(self):
        self.assertEqual(h.deezer_user("123456"), "123456")
        self.assertEqual(h.deezer_user("https://www.deezer.com/en/profile/987654321"), "987654321")
        self.assertEqual(h.deezer_user("https://www.deezer.com/profile/5?x=1"), "5")
        for bad in ("", "evil", "https://evil.example/profile/1x", "javascript:1"):
            self.assertEqual(h.deezer_user(bad), "", bad)

    def test_track_and_covers(self):
        t = h.dz_track({"id": 668826392, "title": "Ghost Love Score\n", "duration": 600, "artist": {"name": "Nightwish"},
                        "album": {"title": "Once", "md5_image": "a" * 32}})
        self.assertEqual(t["id"], "dz:668826392")
        self.assertEqual(t["title"], "Ghost Love Score")
        self.assertEqual(t["cover"], "https://cdn-images.dzcdn.net/images/cover/" + "a" * 32 + "/250x250-000000-80-0-0.jpg")
        self.assertTrue(h.TRACK_KEY_RE.match(t["id"]))
        self.assertIsNone(h.dz_track({"id": "x"}))
        self.assertTrue(h.dz_image("playlist", "-".join(["b" * 32] * 4)))
        self.assertIsNone(h.dz_image("cover", "../x"))

    def test_lists_queue_and_matches(self):
        for lid in ("dz:fav", "dz:chart", "dz:search", "dz:pl:276102231"):
            self.assertTrue(h.is_list_id(lid), lid)
        self.assertFalse(h.is_list_id("dz:pl:x"))
        self.assertEqual(h.track_url({"id": "dz:668826392"}), "ytmusic-deezer://668826392")
        self.assertEqual(h.mix_entry("ytmusic-deezer://668826392")[0], "dz:668826392")
        self.assertEqual(h.source_of("dz:668826392"), "dz")
        with tempfile.TemporaryDirectory() as d:
            saved = h.DZ_MATCH_PATH
            h.DZ_MATCH_PATH = os.path.join(d, "m.json")
            try:
                h.write_json_atomic(h.DZ_MATCH_PATH, {"668826392": "XZcI70MPE5A"})
                self.assertEqual(h.resolve_spotify("dz:668826392"), "XZcI70MPE5A")
            finally:
                h.DZ_MATCH_PATH = saved


class MixcloudAudius(unittest.TestCase):
    def test_mixcloud(self):
        t = h.mc_track({"key": "/DJJazzyJeff/dj-jazzy-jeff-boiler-room/", "name": "Boiler Room", "audio_length": 3600,
                        "user": {"name": "DJ Jazzy Jeff"},
                        "pictures": {"large": "https://thumbnailer.mixcloud.com/unsafe/300x300/extaudio/a/b/c"}})
        self.assertEqual(t["id"], "mc:DJJazzyJeff/dj-jazzy-jeff-boiler-room")
        self.assertTrue(h.TRACK_KEY_RE.match(t["id"]))
        self.assertEqual(h.track_url(t), "https://www.mixcloud.com/DJJazzyJeff/dj-jazzy-jeff-boiler-room/")
        self.assertEqual(h.mix_entry(h.track_url(t))[0], t["id"])
        self.assertIsNone(h.mc_track({"key": "/../x/"}))
        self.assertTrue(h.is_list_id("mc:hot:deep-house") and h.is_list_id("mc:search"))

    def test_audius(self):
        t = h.au_track({"id": "V66vyPP", "title": "Fragments", "duration": 212, "user": {"name": "Xsetra"},
                        "artwork": {"150x150": "https://v.example.org/content/baeaaaiqse1234567890/150x150.jpg"}})
        self.assertEqual(t["id"], "au:V66vyPP")
        self.assertEqual(t["art"], "https://v.example.org/content/baeaaaiqse1234567890/150x150.jpg")
        self.assertIsNone(h.au_track({"id": "bad id"}))
        self.assertIsNone(h.au_track({"id": "abc", "is_streamable": False}))
        self.assertEqual(h.track_url({"id": "au:V66vyPP"}), "ytmusic-audius://V66vyPP")
        self.assertEqual(h.mix_entry("ytmusic-audius://V66vyPP")[0], "au:V66vyPP")
        self.assertEqual(h.audius_stream_url("au:V66vyPP"),
                         "https://api.audius.co/v1/tracks/V66vyPP/stream?app_name=omarchy-music-player")
        self.assertTrue(h.is_list_id("au:trending") and h.is_list_id("au:trending:hip-hop-rap"))
        self.assertEqual(h.au_slug("Hip-Hop/Rap"), "hip-hop-rap")
        self.assertTrue(h.cache_name("au:V66vyPP").startswith("au") and "-" not in h.cache_name("au:V66vyPP"))


class Scrobbling(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = (h.DATA_DIR, h.SCROBBLE_PATH, h.listenbrainz_call, h.lastfm_call)
        h.DATA_DIR = self.tmp.name
        h.SCROBBLE_PATH = os.path.join(self.tmp.name, "scrobble.json")
        self.sent = []
        h.listenbrainz_call = lambda path, token, payload=None: self.sent.append(("lb", path, token, payload)) or {}
        h.lastfm_call = lambda method, params, key, secret, post=False: self.sent.append(("lf", method, params)) or {}

    def tearDown(self):
        h.DATA_DIR, h.SCROBBLE_PATH, h.listenbrainz_call, h.lastfm_call = self.saved
        self.tmp.cleanup()

    def test_only_long_enough_plays_where_connected(self):
        song = {"title": "Ghost Love Score (Official Live Video)", "artist": "NightwishVEVO", "album": "Once"}
        h.scrobble(song, 600, 600, 1000)
        self.assertEqual(self.sent, [])
        h.write_scrobble_config({"listenbrainz": {"token": "tok-12345678", "user": "me"},
                                 "lastfm": {"key": "k", "secret": "s", "session": "sk", "user": "me"}})
        self.assertEqual(oct(os.stat(h.SCROBBLE_PATH).st_mode & 0o777), "0o600")
        h.scrobble(song, 100, 600, 1000)
        h.scrobble(dict(song, title="Jingle"), 25, 25, 1000)
        self.assertEqual(self.sent, [])
        h.scrobble(song, 300, 600, 1000)
        lb = self.sent[0]
        self.assertEqual(lb[1], "submit-listens")
        meta = lb[3]["payload"][0]["track_metadata"]
        self.assertEqual((meta["artist_name"], meta["track_name"], meta["release_name"]), ("Nightwish", "Ghost Love Score", "Once"))
        self.assertEqual(lb[3]["payload"][0]["listened_at"], 1000)
        lf = self.sent[1]
        self.assertEqual((lf[1], lf[2]["artist"], lf[2]["track"], lf[2]["timestamp"], lf[2]["sk"]),
                         ("track.scrobble", "Nightwish", "Ghost Love Score", 1000, "sk"))
        self.sent.clear()
        h.scrobble(dict(song, title="An epic"), 250, 3600, 1000)
        self.assertEqual(len(self.sent), 2)

    def test_signature_and_status(self):
        import hashlib
        sig = h.lastfm_sig({"method": "auth.getSession", "api_key": "k", "token": "t", "format": "json"}, "s")
        self.assertEqual(sig, hashlib.md5(b"api_keykmethodauth.getSessiontokents").hexdigest())
        h.write_scrobble_config({"lastfm": {"key": "k", "secret": "s", "session": "sk", "user": "me"}})
        out = capture(h.cmd_scrobble, [])
        self.assertEqual(out[-1], {"type": "scrobble", "listenbrainz": "", "lastfm": "me"})
        out = capture(h.cmd_scrobble, ["--remove", "lastfm"])
        self.assertEqual(out[-1]["lastfm"], "")

    def test_names(self):
        self.assertEqual(h.scrobble_names("Song - Remastered 2011", "Queen"), ("Queen", "Song - Remastered 2011"))
        self.assertEqual(h.scrobble_names("Wardruna - Helvegen", "Some Channel"), ("Wardruna", "Helvegen"))
        self.assertEqual(h.scrobble_names("Helvegen", "Wardruna - Topic"), ("Wardruna", "Helvegen"))


class Podcasts(unittest.TestCase):
    FEED = b"""<?xml version="1.0"?>
<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
<title>Show Title</title><itunes:author>Host</itunes:author><itunes:image href="https://x.example/art.jpg"/>
<item><title>Old</title><guid>g1</guid><pubDate>Mon, 03 Mar 2025 10:00:00 +0000</pubDate>
  <enclosure url="https://cdn.example/1.mp3" type="audio/mpeg"/><itunes:duration>1:02:03</itunes:duration></item>
<item><title>New</title><guid>g2</guid><pubDate>Tue, 04 Mar 2025 10:00:00 +0000</pubDate>
  <enclosure url="https://cdn.example/2.mp3" type="audio/mpeg"/><itunes:duration>600</itunes:duration></item>
<item><title>A PDF</title><enclosure url="https://cdn.example/x.pdf" type="application/pdf"/></item>
<item><title>Bad link</title><enclosure url="javascript:alert(1)" type="audio/mpeg"/></item>
</channel></rss>"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = (h.DATA_DIR, h.PODCASTS_PATH, h.PODCAST_DIR, h.PODCAST_SHOWS_PATH, h.COVERS_DIR)
        h.DATA_DIR = self.tmp.name
        h.PODCASTS_PATH = os.path.join(self.tmp.name, "podcasts.json")
        h.PODCAST_DIR = os.path.join(self.tmp.name, "pc")
        h.PODCAST_SHOWS_PATH = os.path.join(self.tmp.name, "shows.json")
        h.COVERS_DIR = os.path.join(self.tmp.name, "covers")

    def tearDown(self):
        h.DATA_DIR, h.PODCASTS_PATH, h.PODCAST_DIR, h.PODCAST_SHOWS_PATH, h.COVERS_DIR = self.saved
        self.tmp.cleanup()

    def test_feed_episodes_newest_first_audio_only(self):
        show = h.podcast_show("https://feed.example/rss", "x")
        show, eps = h.parse_feed(self.FEED, show)
        self.assertEqual(show["title"], "Show Title")
        self.assertEqual(show["author"], "Host")
        self.assertEqual([e["title"] for e in eps], ["New", "Old"])
        self.assertEqual(eps[1]["duration"], 3723)
        self.assertEqual(eps[0]["e"], h.podcast_hash("g2"))
        with self.assertRaises(RuntimeError):
            h.parse_feed(b'<!DOCTYPE x [<!ENTITY a "aaaa">]><rss><channel/></rss>', show)
        with self.assertRaises(RuntimeError):
            h.parse_feed(b"<html>not a feed", show)

    def test_ids_progress_and_resume(self):
        show = h.podcast_show("https://feed.example/rss", "Show", "Host")
        h.remember_shows([show])
        _, eps = h.parse_feed(self.FEED, show)
        os.makedirs(h.PODCAST_DIR)
        h.write_json_atomic(os.path.join(h.PODCAST_DIR, show["h"] + ".json"),
                            {"fetchedAt": int(time.time()), "show": show, "episodes": eps})
        key = f"pc:{show['h']}/{eps[1]['e']}"
        self.assertTrue(h.TRACK_KEY_RE.match(key))
        self.assertTrue(h.is_list_id("pc:" + show["h"]) and h.is_list_id("pc:new"))
        self.assertFalse(h.is_list_id("pc:../x"))
        self.assertEqual(h.track_url({"id": key}), "ytmusic-podcast://" + key[3:])
        self.assertEqual(h.mix_entry("ytmusic-podcast://" + key[3:])[0], key)
        self.assertEqual(h.podcast_stream(key), ("https://cdn.example/1.mp3", 0))
        h.note_podcast_progress(key, 1200, 3723, "quit")
        self.assertEqual(h.podcast_stream(key), ("https://cdn.example/1.mp3", 1195))
        items = h.podcast_tracks("pc:" + show["h"])["items"]
        self.assertIn("42 min left", items[1]["note"])
        h.note_podcast_progress(key, 3720, 3723, "eof")
        self.assertEqual(h.podcast_stream(key)[1], 0)
        self.assertIn("Played", h.podcast_tracks("pc:" + show["h"])["items"][1]["note"])
        self.assertEqual(oct(os.stat(h.PODCASTS_PATH).st_mode & 0o777), "0o600")

    def test_subscribe(self):
        show = h.podcast_show("https://feed.example/rss", "Show")
        h.remember_shows([show])
        out = capture(h.cmd_podcast_sub, ["pc:" + show["h"]])
        self.assertEqual(out[-1], {"type": "podcastSubs", "ids": ["pc:" + show["h"]]})
        out = capture(h.cmd_podcast_sub, ["pc:" + show["h"], "--remove", "1"])
        self.assertEqual(out[-1]["ids"], [])


class LocalFolder(unittest.TestCase):
    def test_lists_songs_and_never_leaves_the_folder(self):
        with tempfile.TemporaryDirectory() as d:
            album = os.path.join(d, "Band", "Album")
            os.makedirs(album)
            for name in ("01 - Song.mp3", "cover.jpg", "notes.txt", ".hidden.mp3"):
                pathlib.Path(album, name).write_bytes(b"x")
            os.makedirs(os.path.join(d, ".git"))
            pathlib.Path(d, ".git", "x.mp3").write_bytes(b"x")
            entries = h.local_entries(d)
            self.assertEqual(sorted(e["Path"] for e in entries),
                             ["Band/Album/.hidden.mp3", "Band/Album/01 - Song.mp3", "Band/Album/cover.jpg"])
            src = {"id": "0a1b2c3d", "kind": "local", "remote": "", "path": d}
            self.assertTrue(h.local_file(src, "Band/Album/01 - Song.mp3").endswith("01 - Song.mp3"))
            for bad in ("../etc/passwd", "Band/../../x", "/etc/passwd"):
                with self.assertRaises(RuntimeError):
                    h.local_file(src, bad)



class FakeServer:
    """A tiny HTTP server answering like Subsonic, Jellyfin or Plex."""

    def __init__(self, routes):
        import http.server, threading
        routes_ = routes
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass
            def answer(self):
                path, _, query = self.path.partition("?")
                params = dict(urllib.parse.parse_qsl(query))
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length) or b"{}") if length else {}
                for prefix, fn in routes_:
                    if path.startswith(prefix):
                        status, ctype, data = fn(path, params, body, self.headers)
                        self.send_response(status)
                        self.send_header("Content-Type", ctype)
                        self.end_headers()
                        self.wfile.write(data if isinstance(data, bytes) else json.dumps(data).encode())
                        return
                self.send_response(404)
                self.end_headers()
            do_GET = do_POST = answer
        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.httpd.server_port}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()


JPEG = b"\xff\xd8\xff\xe0" + b"0" * 64
AUDIO = b"ID3" + b"\x00" * 2048


class MediaServers(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        d = self.dir.name
        self.env = dict(os.environ, XDG_DATA_HOME=os.path.join(d, "data"), XDG_CACHE_HOME=os.path.join(d, "cache"),
                        XDG_RUNTIME_DIR=os.path.join(d, "run"))
        self.servers = []

    def tearDown(self):
        for srv in self.servers:
            srv.close()
        self.dir.cleanup()

    def run_helper(self, *args, stdin=""):
        import subprocess
        proc = subprocess.run([sys.executable, "-I", str(HELPER), *args], input=stdin, capture_output=True, text=True,
                              env=self.env, timeout=60)
        return [json.loads(l) for l in proc.stdout.splitlines() if l.startswith("{")]

    def check_server(self, kind, routes, fields):
        srv = FakeServer(routes)
        self.servers.append(srv)
        out = self.run_helper("cloud-add", stdin=json.dumps({"kind": kind, "path": "", "fields": dict(fields, url=srv.url)}) + "\n")
        self.assertEqual(out[-1].get("state"), "added", out)
        sid = out[-1]["id"]
        secrets = pathlib.Path(self.env["XDG_DATA_HOME"], h.PLUGIN_ID, "servers.json")
        self.assertEqual(oct(secrets.stat().st_mode & 0o777), "0o600")
        self.assertNotIn("hunter2", secrets.read_text())             # never the password
        lists = [m for m in self.run_helper("playlists", "--service", "cl", "--max-age", "0") if m["type"] == "playlists"][-1]["items"]
        ids = [l["id"] for l in lists]
        self.assertIn(f"ms:{sid}:al:al1", ids)
        album = next(l for l in lists if l["id"] == f"ms:{sid}:al:al1")
        self.assertTrue(album["cover"].endswith(".jpg") and os.path.isfile(album["cover"]))
        tracks = [m for m in self.run_helper("tracks", f"ms:{sid}:al:al1") if m["type"] == "tracks"][-1]["items"]
        self.assertEqual([t["title"] for t in tracks], ["First", "Second"])
        self.assertEqual(tracks[0]["duration"], 200)
        self.assertEqual(tracks[0]["artist"], "Band")
        key = tracks[0]["id"]
        self.assertTrue(h.TRACK_KEY_RE.match(key))
        url = self.run_helper("resolve", key)[-1]["url"]
        self.assertTrue(url.startswith(srv.url))
        self.assertNotIn("hunter2", url)
        self.assertNotIn(url.split("?", 1)[-1], h.redact(url))        # the sign-in is masked in reports
        return sid, key

    def test_subsonic(self):
        def rest(path, params, body, headers):
            ok = params.get("u") == "me" and params.get("t") == __import__("hashlib").md5(("hunter2" + params.get("s", "")).encode()).hexdigest()
            if not ok:
                return 200, "application/json", {"subsonic-response": {"status": "failed", "error": {"code": 40, "message": "Wrong"}}}
            song = lambda i, t: {"id": f"tr{i}", "title": t, "artist": "Band", "album": "Album", "duration": 200, "coverArt": "al1"}
            data = {"ping": {}, "getPlaylists": {"playlists": {"playlist": [{"id": "pl1", "name": "Mine", "songCount": 2}]}},
                    "getAlbumList2": {"albumList2": {"album": [{"id": "al1", "name": "Album", "artist": "Band", "songCount": 2, "coverArt": "al1"}]}},
                    "getAlbum": {"album": {"song": [song(1, "First"), song(2, "Second")]}}}
            method = path.rsplit("/", 1)[-1]
            if method == "getCoverArt":
                return 200, "image/jpeg", JPEG
            if method == "stream":
                return 200, "audio/mpeg", AUDIO
            return 200, "application/json", {"subsonic-response": {"status": "ok", **data.get(method, {})}}
        sid, key = self.check_server("subsonic", [("/rest/", rest)], {"user": "me", "pass": "hunter2"})
        bad = self.run_helper("cloud-add", stdin=json.dumps({"kind": "subsonic", "fields": {"url": self.servers[0].url, "user": "me", "pass": "wrong"}}) + "\n")
        self.assertIn("check the user name and password", bad[-1]["message"])

    def test_jellyfin(self):
        def route(path, params, body, headers):
            if path == "/Users/AuthenticateByName":
                if body.get("Pw") != "hunter2":
                    return 401, "application/json", {}
                return 200, "application/json", {"AccessToken": "tok123", "User": {"Id": "u1"}}
            if "tok123" not in headers.get("Authorization", "") and params.get("api_key") != "tok123":
                return 401, "application/json", {}
            if path.startswith("/Items/") and path.endswith("/Images/Primary"):
                return 200, "image/jpeg", JPEG
            if path == "/Users/u1/Items" and params.get("IncludeItemTypes") == "MusicAlbum":
                return 200, "application/json", {"Items": [{"Id": "al1", "Name": "Album", "AlbumArtist": "Band", "ChildCount": 2}]}
            if path == "/Users/u1/Items" and params.get("ParentId") == "al1":
                mk = lambda i, t: {"Id": f"tr{i}", "Name": t, "Artists": ["Band"], "Album": "Album", "AlbumId": "al1",
                                   "RunTimeTicks": 200 * 10_000_000}
                return 200, "application/json", {"Items": [mk(1, "First"), mk(2, "Second")]}
            return 200, "application/json", {"Items": []}
        self.check_server("jellyfin", [("/", route)], {"user": "me", "pass": "hunter2"})

    def test_plex_lists_and_stream(self):
        def route(path, params, body, headers):
            if headers.get("X-Plex-Token") != "ptok" and params.get("X-Plex-Token") != "ptok":
                return 401, "application/json", {}
            mc = lambda **k: {"MediaContainer": k}
            if path == "/library/sections":
                return 200, "application/json", mc(Directory=[{"key": "3", "type": "artist"}])
            if path == "/library/sections/3/all":
                return 200, "application/json", mc(Metadata=[{"ratingKey": "al1", "title": "Album", "parentTitle": "Band", "leafCount": 2, "thumb": "/t/1"}])
            if path == "/playlists":
                return 200, "application/json", mc(Metadata=[])
            if path == "/library/metadata/al1/children":
                mk = lambda i, t: {"ratingKey": f"tr{i}", "title": t, "grandparentTitle": "Band", "parentTitle": "Album",
                                   "duration": 200000, "parentThumb": "/t/1"}
                return 200, "application/json", mc(Metadata=[mk(1, "First"), mk(2, "Second")])
            if path == "/library/metadata/tr1":
                return 200, "application/json", mc(Metadata=[{"Media": [{"Part": [{"key": "/library/parts/9/file.flac"}]}]}])
            if path.startswith("/photo/"):
                return 200, "image/jpeg", JPEG
            return 200, "application/json", mc()
        srv = FakeServer([("/", route)])
        self.servers.append(srv)
        sid = "0a1b2c3d"
        data = pathlib.Path(self.env["XDG_DATA_HOME"], h.PLUGIN_ID)
        data.mkdir(parents=True)
        (data / "cloud.json").write_text(json.dumps({"sources": [{"id": sid, "remote": "", "path": srv.url, "kind": "plex",
                                                                    "title": "Plex", "created": False}]}))
        (data / "servers.json").write_text(json.dumps({sid: {"token": "ptok", "client": "c"}}))
        lists = [m for m in self.run_helper("playlists", "--service", "cl", "--max-age", "0") if m["type"] == "playlists"][-1]["items"]
        self.assertIn(f"ms:{sid}:al:al1", [l["id"] for l in lists])
        tracks = [m for m in self.run_helper("tracks", f"ms:{sid}:al:al1") if m["type"] == "tracks"][-1]["items"]
        self.assertEqual([t["title"] for t in tracks], ["First", "Second"])
        url = self.run_helper("resolve", tracks[0]["id"])[-1]["url"]
        self.assertEqual(url, f"{srv.url}/library/parts/9/file.flac?X-Plex-Token=ptok")
        self.assertEqual(self.run_helper("cloud-remove", sid)[-1]["state"], "removed")
        self.assertNotIn(sid, json.loads((data / "servers.json").read_text()))



class History(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.saved = (h.HISTORY_PATH, h.SESSION_PATH, h.DATA_DIR, h.AI_MIX_PATH, h.ask_agent, h.find_on_youtube, h.tracks_cache_path)
        d = self.dir.name
        h.DATA_DIR = d
        h.HISTORY_PATH = os.path.join(d, "history.jsonl")
        h.SESSION_PATH = os.path.join(d, "session.json")
        h.AI_MIX_PATH = os.path.join(d, "ai-mix.json")
        h.tracks_cache_path = lambda list_id, browser: os.path.join(d, "none.json")
        h.write_json_atomic(h.SESSION_PATH, {"tracks": [
            {"id": "dQw4w9WgXcQ", "title": "Never Gonna", "artist": "Rick"},
            {"id": "kJQP7kiw5Fk", "title": "Despacito", "artist": "Luis Fonsi"}]})

    def tearDown(self):
        (h.HISTORY_PATH, h.SESSION_PATH, h.DATA_DIR, h.AI_MIX_PATH, h.ask_agent, h.find_on_youtube, h.tracks_cache_path) = self.saved
        self.dir.cleanup()

    def add(self, vid, played, duration, reason):
        h.cmd_history_add([f"https://music.youtube.com/watch?v={vid}", "--played", str(played),
                           "--duration", str(duration), "--reason", reason])

    def test_finished_and_skipped(self):
        self.add("dQw4w9WgXcQ", 210, 212, "eof")
        self.add("kJQP7kiw5Fk", 8, 229, "stop")        # too short to note at all? 8 s is noted by the helper
        self.add("kJQP7kiw5Fk", 15, 229, "stop")
        e = h.read_history()
        self.assertTrue(e[0]["finished"] and not e[0]["skipped"])
        self.assertTrue(e[-1]["skipped"])
        self.assertEqual(e[0]["artist"], "Rick")
        recent = h.recent_tracks()
        self.assertEqual([t["id"] for t in recent], ["dQw4w9WgXcQ"])      # skipped songs aren't "recent"
        self.add("dQw4w9WgXcQ", 1, 0, "eof")
        h.cmd_history_add(["ytmusic-radio://1c6dcd6f-88c6-4fd4-8191-078435168e85", "--played", "300", "--reason", "stop"])
        self.assertEqual(len(h.read_history()), 4)                        # stations aren't songs

    def test_taste_and_a_mix_from_the_agent(self):
        for _ in range(3):
            self.add("dQw4w9WgXcQ", 210, 212, "eof")
        for _ in range(3):
            self.add("kJQP7kiw5Fk", 12, 229, "stop")
        taste = h.taste_profile()
        self.assertEqual(taste["topArtists"], ["Rick"])
        self.assertIn("Luis Fonsi", taste["oftenSkipped"])
        asked = {}
        def agent(prompt):
            asked["prompt"] = prompt
            return {"title": "For You", "about": "x", "songs": [{"artist": "A", "title": f"Song {i}", "why": "because"} for i in range(8)]
                    + [{"artist": "Ghost", "title": "Invented", "why": "?"}]}, "Claude"
        h.ask_agent = agent
        h.find_on_youtube = lambda s: None if s["artist"] == "Ghost" else {"id": f"vid{s['title'][-1]}aaaaaaa"[:11], "title": s["title"], "artist": s["artist"], "duration": 100}
        import io, contextlib
        with contextlib.redirect_stdout(io.StringIO()) as out:
            h.cmd_ai_mix(["--prompt", "something calm"])
        self.assertIn("something calm", asked["prompt"])
        self.assertIn("Rick", asked["prompt"])
        mix = h.read_json(h.AI_MIX_PATH)
        self.assertEqual(len(mix["items"]), 8)                            # the invented song is dropped
        self.assertEqual(mix["items"][0]["note"], "because")
        self.assertIn('"state":"done"', out.getvalue())
        with contextlib.redirect_stdout(io.StringIO()) as out:
            h.cmd_ai_mix(["--if-older", "86400"])
        self.assertIn('"state":"fresh"', out.getvalue())


class Reports(unittest.TestCase):
    def test_redact_removes_everything_personal(self):
        home = os.path.expanduser("~")
        text = (f"ERROR: [youtube] dQw4w9WgXcQ: bot check; cookies from firefox:{home}/.config/zen/29yzqria.Default (release) "
                "mail me@example.com token=abcdefghijklmnopqrstuvwxyz watch?v=kJQP7kiw5Fk "
                "https://soundcloud.com/joey/warm ytmusic-spotify://4uLU6hMCjMI75M1A2tKUQC sp:4uLU6hMCjMI75M1A2tKUQC "
                f"{home}/Music/My Song.mp3")
        out = h.redact(text)
        for leak in (home, "29yzqria", "dQw4w9WgXcQ", "kJQP7kiw5Fk", "example.com", "abcdefghijklmnop", "joey",
                     "4uLU6hMCjMI75M1A2tKUQC"):
            self.assertNotIn(leak, out, leak)
        self.assertIn("bot check", out)                        # the reason stays
        self.assertIn("~/Music", out)

    def test_report_url_fits_and_keeps_the_newest_errors(self):
        import urllib.parse
        errors = [f"[e] error number {i} " + "x" * 200 for i in range(80)]
        title, url = h.build_report("Liked Music", "Couldn't load", "yt", ["Plugin: 0.6.0"], ["default: ok"], errors)
        self.assertLessEqual(len(url), h.REPORT_MAX_URL)
        self.assertTrue(url.startswith(h.REPO_URL + "/issues/new?"))
        body = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)["body"][0]
        self.assertIn("error number 79", body)                 # newest kept
        self.assertNotIn("error number 0 ", body)              # oldest dropped
        self.assertIn("Couldn't load", body)
        self.assertEqual(title, "[Report] Liked Music: Couldn't load")


if __name__ == "__main__":
    unittest.main()
