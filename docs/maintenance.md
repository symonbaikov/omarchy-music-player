# Maintenance

The repository looks after itself, with a human approving every change.

- **Watchdog** (`.github/workflows/watchdog.yml`, every 3 hours):
  `tools/watchdog.py` plays public songs through the plugin's own helper with
  the latest yt-dlp: a radio list, real playback in mpv, each YouTube client,
  the backup download, a peak mix and the mirrors. When playback is broken it
  opens a `watchdog` issue, and closes it once playback works again. When
  YouTube only refuses the CI runner itself (a bot check on a data-center
  IP), the run is *inconclusive* and raises no alarm.
- **Fix**: for a new breakage, Claude (claude-code-action) reproduces it,
  finds the cause and opens a pull request with the fix, its tests and a
  version bump, labelled `auto-fix`. If only a newer yt-dlp helps, it says so
  on the issue. It never pushes to `main`: the branch ruleset requires a pull
  request, which the owner reviews and merges.
- **CI** (`.github/workflows/ci.yml`): the node and Python tests, the Lua
  script and the manifest, on every push and pull request.
- **Release** (`.github/workflows/release.yml`): a new version in
  `manifest.json` on `main` is tagged and released, and the Omarchy
  marketplace is asked to verify that exact commit (its maintainer approves
  it). Users get the update from the panel.

Secrets: `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) for fixes,
`MARKETPLACE_TOKEN` (a classic GitHub token with `public_repo`) for the
marketplace requests. Without them the watchdog still opens issues and
releases still happen.

Run the watchdog locally: `python3 tools/watchdog.py`. It uses throwaway
directories and a silent mpv, so it doesn't touch a running player.
