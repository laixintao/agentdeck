"""Exercise the actual make release/bumpversion path against disposable local remotes."""
import configparser
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


@unittest.skipUnless(shutil.which("bumpversion"), "Install requirements-release.txt")
class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="agentdeck-release-")
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.repo = self.folder / "app"
        self.repo.mkdir()
        self.remote = self.folder / "remote.git"
        for filename in ["Makefile", "VERSION", ".bumpversion.cfg", "Resources/Info.plist", "scripts/release.py", "scripts/check-release.py"]:
            target = self.repo / filename
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / filename, target)
        self.initial = (self.repo / "VERSION").read_text().strip()
        major, minor, patch = map(int, self.initial.split("."))
        self.next = f"{major}.{minor}.{patch + 1}"
        self.run_command("git", "init", "-q", "-b", "main")
        self.run_command("git", "config", "user.name", "Release test")
        self.run_command("git", "config", "user.email", "release@example.test")
        self.run_command("git", "config", "commit.gpgsign", "false")
        self.run_command("git", "config", "tag.gpgsign", "false")
        self.run_command("git", "add", ".")
        self.run_command("git", "commit", "-qm", "Initial app")
        self.run_command("git", "init", "--bare", "-q", str(self.remote))
        self.run_command("git", "remote", "add", "origin", str(self.remote))
        self.run_command("git", "push", "-q", "-u", "origin", "main")

    def run_command(self, *args, check=True):
        return subprocess.run(args, cwd=self.repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check)

    def version(self):
        return (self.repo / "VERSION").read_text().strip()

    def test_make_release_bumps_all_versions_and_pushes_annotated_tag(self):
        self.run_command("make", "release")
        self.assertEqual(self.version(), self.next)
        info = plistlib.loads((self.repo / "Resources/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleVersion"], self.next)
        self.assertEqual(info["CFBundleShortVersionString"], self.next)
        config = configparser.ConfigParser()
        config.read(self.repo / ".bumpversion.cfg")
        self.assertEqual(config["bumpversion"]["current_version"], self.next)
        self.assertEqual(self.run_command("git", "cat-file", "-t", "v" + self.next).stdout.strip(), "tag")
        self.assertEqual(self.run_command("git", "status", "--porcelain").stdout, "")
        local = self.run_command("git", "rev-parse", "HEAD").stdout.strip()
        remote = self.run_command("git", "ls-remote", "origin", "refs/heads/main").stdout.split()[0]
        self.assertEqual(local, remote)
        self.assertIn("refs/tags/v" + self.next, self.run_command("git", "ls-remote", "--tags", "origin").stdout)

    def test_direct_bumpversion_produces_valid_release_metadata(self):
        self.run_command("bumpversion", "minor")
        self.run_command("python3", "scripts/check-release.py", "--tag", "v" + self.version())

    def test_dirty_invalid_and_existing_tag_fail_before_changing_version(self):
        (self.repo / "uncommitted.txt").write_text("unfinished")
        self.assertNotEqual(self.run_command("make", "release", check=False).returncode, 0)
        (self.repo / "uncommitted.txt").unlink()
        for version in [self.initial, "0.0.0", "bad-version", "01.2.3"]:
            self.assertNotEqual(self.run_command("make", "release", "VERSION=" + version, check=False).returncode, 0)
            self.assertEqual(self.version(), self.initial)
        self.run_command("git", "tag", "v" + self.next)
        self.assertNotEqual(self.run_command("make", "release", check=False).returncode, 0)
        self.assertEqual(self.version(), self.initial)

    def test_rejected_atomic_push_keeps_retryable_release(self):
        old_head = self.run_command("git", "rev-parse", "HEAD").stdout.strip()
        hook = self.remote / "hooks/pre-receive"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        result = self.run_command("make", "release", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("git push --atomic origin HEAD:refs/heads/main refs/tags/v" + self.next, result.stderr)
        self.assertEqual(self.version(), self.next)
        self.assertEqual(self.run_command("git", "status", "--porcelain").stdout, "")
        self.assertEqual(self.run_command("git", "ls-remote", "origin", "refs/heads/main").stdout.split()[0], old_head)
        self.assertEqual(self.run_command("git", "ls-remote", "--tags", "origin").stdout, "")
        hook.unlink()
        self.run_command("git", "push", "--atomic", "origin", "HEAD:refs/heads/main", "refs/tags/v" + self.next)

    def test_remote_ahead_is_rejected_before_bump(self):
        self.run_command("git", "commit", "--allow-empty", "-qm", "Remote change")
        self.run_command("git", "push", "-q", "origin", "main")
        self.run_command("git", "reset", "--hard", "HEAD~1")
        result = self.run_command("make", "release", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Remote main has newer changes", result.stderr)
        self.assertEqual(self.version(), self.initial)


if __name__ == "__main__":
    unittest.main()
