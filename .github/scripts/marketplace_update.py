#!/usr/bin/env python3
"""Ask the Omarchy plugin marketplace to verify a new release.

Run by .github/workflows/release.yml with GH_TOKEN (the owner's token),
VERSION and TARGET_SHA. The marketplace maintainer still reviews and
approves every commit; this only files or refreshes the request:

  - still waiting for the first listing: edit the open [Plugin] submission
    so the marketplace validates the new commit (its bot re-runs on edit);
  - listed: open a "[Verify]" request for the new commit, or update the one
    already open.
"""

import json
import os
import re
import subprocess
import sys
import urllib.request

MARKETPLACE = "omacom/omarchy-plugin-marketplace"
PLUGIN_ID = "io.github.symonbaikov.ytmusic-mpv"
SOURCE = "https://github.com/symonbaikov/omarchy-music-player"
SUBMISSION_TITLE = "[Plugin]: Omarchy Music Player"
REGISTRY = f"https://raw.githubusercontent.com/{MARKETPLACE}/main/registry.json"

VERIFY_BODY = """### Verification action

Verify and publish a newer upstream commit

### Plugin ID

{plugin}

### Repository URL

{source}

### Target commit

{sha}

### Verification acknowledgment

- [x] I understand that only the exact target commit can become a verified marketplace snapshot and that verification is not a security audit.

### Standard installation acknowledgment

- [ ] I confirm that this listed root plugin supports the standard Omarchy installation path and does not require manual setup.
"""


def gh(*args, stdin=None):
    proc = subprocess.run(["gh", *args], input=stdin, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"gh {' '.join(args[:3])} failed: {proc.stderr.strip()}")
    return proc.stdout


def listed():
    """Is the plugin in the marketplace registry?"""
    try:
        with urllib.request.urlopen(REGISTRY, timeout=60) as response:
            return f'"{PLUGIN_ID}"' in response.read(64 * 1024 * 1024).decode("utf-8", "replace")
    except OSError as exc:
        sys.exit(f"couldn't read the marketplace registry: {exc}")


def main():
    version, sha = os.environ["VERSION"], os.environ["TARGET_SHA"]
    if not re.fullmatch(r"[0-9a-f]{40}", sha) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        sys.exit("bad VERSION or TARGET_SHA")
    me = gh("api", "user", "--jq", ".login").strip()

    if listed():
        open_requests = json.loads(gh("issue", "list", "-R", MARKETPLACE, "--author", me, "--state", "open",
                                      "--search", f'in:title "[Verify]: {PLUGIN_ID}"', "--json", "number,title"))
        body = VERIFY_BODY.format(plugin=PLUGIN_ID, source=SOURCE, sha=sha)
        mine = [i for i in open_requests if i["title"].strip() == f"[Verify]: {PLUGIN_ID}"]
        if mine:
            gh("issue", "edit", str(mine[0]["number"]), "-R", MARKETPLACE, "--body-file", "-", stdin=body)
            print(f"updated verification request #{mine[0]['number']} to {sha}")
        else:
            url = gh("issue", "create", "-R", MARKETPLACE, "--title", f"[Verify]: {PLUGIN_ID}", "--body-file", "-", stdin=body)
            print(f"opened verification request {url.strip()}")
        return

    submissions = json.loads(gh("issue", "list", "-R", MARKETPLACE, "--author", me, "--state", "open",
                                "--search", f'in:title "{SUBMISSION_TITLE}"', "--json", "number,title,body"))
    submission = next((i for i in submissions if i["title"].strip() == SUBMISSION_TITLE), None)
    if not submission:
        print("not listed and no open submission: nothing to do")
        return
    body = submission["body"]
    updated, count = re.subn(r"Current version: \d+\.\d+\.\d+\.", f"Current version: {version}.", body)
    if count == 0:
        # Appending would land in the checklist section and could break the
        # form's validation: leave it to the owner.
        print(f"::warning::submission #{submission['number']} has no 'Current version: x.y.z.' to update; edit it by hand")
        return
    if updated == body:
        print(f"submission #{submission['number']} already names {version}")
        return
    gh("issue", "edit", str(submission["number"]), "-R", MARKETPLACE, "--body-file", "-", stdin=updated)
    print(f"edited submission #{submission['number']} for {version}: the marketplace re-validates it")


if __name__ == "__main__":
    main()
