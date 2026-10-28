#!/usr/bin/env python3
"""Run bumpversion and atomically push main plus its release tag."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def run(*args, check=True):
    return subprocess.run(args, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check)


def git(*args):
    return run("git", *args).stdout.strip()


def version_tuple(value):
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", value):
        raise ValueError("Use a stable version like 0.1.1, without a v prefix")
    return tuple(map(int, value.split(".")))


def main(requested=None):
    if git("status", "--porcelain"):
        raise ValueError("Commit your changes first; releases require a clean worktree")
    if git("branch", "--show-current") != "main":
        raise ValueError("Release from main")
    bumpversion = shutil.which("bumpversion")
    if not bumpversion:
        raise ValueError("Install bumpversion first: pipx install bump2version==1.0.1")
    run(sys.executable, "scripts/check-release.py")
    current = (ROOT / "VERSION").read_text().strip()
    major, minor, patch = version_tuple(current)
    version = requested or f"{major}.{minor}.{patch + 1}"
    if version_tuple(version) <= (major, minor, patch):
        raise ValueError(f"Version must be newer than {current}")
    tag = "v" + version
    if run("git", "show-ref", "--verify", "--quiet", "refs/tags/" + tag, check=False).returncode == 0:
        raise ValueError(f"{tag} already exists; retry its push instead of bumping again")
    git("fetch", "--quiet", "origin", "refs/heads/main", "--tags")
    if run("git", "merge-base", "--is-ancestor", "FETCH_HEAD", "HEAD", check=False).returncode:
        raise ValueError("Remote main has newer changes; pull/rebase before releasing")
    if git("ls-remote", "origin", "refs/tags/" + tag):
        raise ValueError(f"{tag} already exists on origin")
    run(bumpversion, "--new-version", version, "patch")
    run(sys.executable, "scripts/check-release.py", "--tag", tag)
    push = ["git", "push", "--atomic", "origin", "HEAD:refs/heads/main", "refs/tags/" + tag]
    result = run(*push, check=False)
    if result.returncode:
        print(result.stderr, file=sys.stderr)
        print("Release commit and tag kept locally. Retry this exact push after fixing the error:\n  " + " ".join(push), file=sys.stderr)
        print("Do not bump the version again to retry this release.", file=sys.stderr)
        return 1
    remote = git("remote", "get-url", "origin")
    match = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$", remote)
    print(f"Pushed {tag}. GitHub Actions will test, package, attest, and publish it.")
    if match:
        print(f"https://github.com/{match[1]}/actions/workflows/release.yml")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default=os.environ.get("VERSION") or None)
    try:
        sys.exit(main(parser.parse_args().version))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Release stopped: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
