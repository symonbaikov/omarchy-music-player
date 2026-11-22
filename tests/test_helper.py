# Run: python3 -I -m unittest discover -s tests -p 'test_*.py'
# No network and no browser cookies: only the helper's pure parts.
import json
import os
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
        self.saved = (h.SOCKET_PATH, h.SESSION_PATH, h.PID_PATH, h.our_mpv_pid)
        h.SOCKET_PATH, h.SESSION_PATH, h.PID_PATH = (os.path.join(d, n) for n in ("s", "session.json", "pid"))
        pathlib.Path(h.SESSION_PATH).write_text("{}")
        self.alive = True
        h.our_mpv_pid = lambda: 4242 if self.alive else None
        self.mpv = None

    def tearDown(self):
        if self.mpv:
            self.mpv.close()
        h.SOCKET_PATH, h.SESSION_PATH, h.PID_PATH, h.our_mpv_pid = self.saved
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
