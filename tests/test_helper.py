# Run: python3 -I -m unittest discover -s tests -p 'test_*.py'
# No network and no browser cookies: only the helper's pure parts.
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


if __name__ == "__main__":
    unittest.main()
