"""Ensure public assets are immutable and failed draft uploads cannot go public."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="agentdeck-publish-")
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        for name in ["VERSION", ".bumpversion.cfg", "Resources/Info.plist", "scripts/check-release.py", "scripts/publish-release.sh"]:
            target = self.folder / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        (self.folder / "bin").mkdir()
        fake = self.folder / "bin/gh"
        fake.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ['CALL_LOG']).open('a') as log:
    log.write(json.dumps(args) + '\\n')
if args[:2] == ['release', 'view']:
    status = os.environ['RELEASE_STATE']
    if status == 'missing': sys.exit(1)
    print('true' if status == 'draft' else 'false')
if args[:2] == ['release', 'upload'] and os.environ.get('FAIL_UPLOAD') == '1':
    sys.exit(1)
''')
        fake.chmod(0o755)

    def publish(self, state, fail=False):
        env = dict(os.environ, PATH=str(self.folder / "bin") + os.pathsep + os.environ["PATH"],
                   RELEASE_TAG="v" + (self.folder / "VERSION").read_text().strip(), GH_REPO="fixture/app",
                   CALL_LOG=str(self.folder / "calls.jsonl"), RELEASE_STATE=state, FAIL_UPLOAD="1" if fail else "0")
        result = subprocess.run(["/bin/bash", "scripts/publish-release.sh"], cwd=self.folder, env=env, capture_output=True, text=True)
        calls = [json.loads(line) for line in (self.folder / "calls.jsonl").read_text().splitlines()]
        return result, calls

    def test_existing_public_release_is_never_modified(self):
        result, calls = self.publish("public")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:2], ["release", "view"])

    def test_failed_upload_leaves_a_draft(self):
        result, calls = self.publish("missing", fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(any(call[:2] == ["release", "create"] and "--draft" in call for call in calls))
        self.assertFalse(any("--draft=false" in call for call in calls))

    def test_resume_draft_uploads_exact_assets_before_publishing(self):
        result, calls = self.publish("draft")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call[:2] == ["release", "create"] for call in calls))
        upload = next(call for call in calls if call[:2] == ["release", "upload"])
        self.assertEqual(len([value for value in upload if value.endswith((".zip", ".dmg", "SHA256SUMS"))]), 5)
        self.assertIn("--draft=false", calls[-1])


if __name__ == "__main__":
    unittest.main()
