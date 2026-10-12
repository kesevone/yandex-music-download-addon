"""Execute the real UI handlers with isolated geometry and playback fixtures."""
import os
from pathlib import Path
import shutil
import subprocess
import unittest


class RuntimeUiTests(unittest.TestCase):
    def test_ui_regressions(self):
        node = os.environ.get('YM_NODE') or shutil.which('node')
        if not node:
            self.skipTest('Node is required for renderer handler fixtures')
        result = subprocess.run([node, '--test', str(Path(__file__).with_name('ui_fixture.mjs'))],
                                capture_output=True, text=True, encoding='utf-8', timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
