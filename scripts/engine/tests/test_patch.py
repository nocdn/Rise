"""Regression checks for incremental, overlapping Chromium patches; no Chromium checkout needed."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class PatchScriptTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix="rise-engine-patch-test-")
        self.addCleanup(self.folder.cleanup)
        root = Path(self.folder.name)
        self.source = root / "src"
        self.source.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Rise test")
        self.git("config", "user.email", "test@example.invalid")
        (self.source / "shared.txt").write_text("original\n")
        (self.source / "local.txt").write_text("keep this\n")
        self.git("add", ".")
        self.git("commit", "-qm", "Base")
        engine = root / "Engine"
        patches = engine / "fork/patches"
        patches.mkdir(parents=True)
        for number, (before, after) in enumerate([("original", "first"), ("first", "second"), ("second", "third")], 1):
            (patches / f"{number:04d}.patch").write_text(
                f"--- a/shared.txt\n+++ b/shared.txt\n@@ -1 +1 @@\n-{before}\n+{after}\n")
        scripts = root / "scripts/engine"
        scripts.mkdir(parents=True)
        shutil.copy(Path(__file__).resolve().parents[1] / "patch.sh", scripts / "patch.sh")
        (scripts / "common.sh").write_text('set -euo pipefail\nCHROMIUM_SRC="$RISE_PATCH_TEST_SOURCE"\nENGINE_DIR="$RISE_PATCH_TEST_ENGINE"\n')
        (scripts / "brand.py").write_text("# No branding needed in a patch fixture.\n")
        self.script = scripts / "patch.sh"
        self.patches = patches
        self.environment = dict(os.environ, RISE_PATCH_TEST_SOURCE=str(self.source), RISE_PATCH_TEST_ENGINE=str(engine))

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.source, check=True, capture_output=True, text=True)

    def run_script(self):
        return subprocess.run(["bash", str(self.script)], env=self.environment, capture_output=True, text=True)

    def test_fresh_checkout_applies_all_patches_and_second_run_is_idempotent(self):
        first = self.run_script()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual((self.source / "shared.txt").read_text(), "third\n")
        self.assertEqual(first.stdout.count("applied:"), 3)
        second = self.run_script()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(second.stdout.count("already applied:"), 3)
        self.assertEqual((self.source / "shared.txt").read_text(), "third\n")

    def test_new_patch_skips_overlapping_installed_prefix_and_preserves_local_work(self):
        for number in [1, 2]:
            self.git("apply", str(self.patches / f"{number:04d}.patch"))
        (self.source / "local.txt").write_text("unsaved local work\n")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("already applied:"), 2)
        self.assertIn("applied: 0003.patch", result.stdout)
        self.assertEqual((self.source / "shared.txt").read_text(), "third\n")
        self.assertEqual((self.source / "local.txt").read_text(), "unsaved local work\n")

    def test_conflicting_new_patch_fails_without_overwriting_the_checkout(self):
        for number in [1, 2]:
            self.git("apply", str(self.patches / f"{number:04d}.patch"))
        (self.source / "shared.txt").write_text("local replacement\n")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.source / "shared.txt").read_text(), "local replacement\n")


if __name__ == "__main__":
    unittest.main()
