"""Release regressions use synthetic sessions, clocks and CDP responses only."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('release_music', ROOT / 'src/yandex_music.py')
music = importlib.util.module_from_spec(spec)
spec.loader.exec_module(music)


class CliAccountTests(unittest.TestCase):
    def fixture_response(self, request, timeout):
        self.accounts.append(request.get_header('Authorization'))
        reply = {'result': {'downloadInfo': {'transport': 'raw', 'codec': 'mp3', 'quality': 'hq',
                                             'urls': ['https://example.invalid/synthetic-audio']}}}
        return io.BytesIO(json.dumps(reply).encode())

    def test_each_cli_source_operation_uses_current_app_account(self):
        for command in ('url', 'download', 'player'):
            with self.subTest(command=command), tempfile.TemporaryDirectory() as directory:
                session = Path(directory) / 'session.dpapi'
                session.write_bytes(json.dumps({'token': 'previous-account', 'secret': 'fixture', 'version': 'fixture'}).encode())
                arguments = ['music', '--session', str(session), command, '123']
                if command != 'url':
                    arguments += ['--out', str(Path(directory) / ('synthetic.html' if command == 'player' else 'synthetic.mp3'))]
                self.accounts = []
                with patch.object(sys, 'argv', arguments), \
                     patch.dict(os.environ, {'YM_APP_PORT': '9929', 'YANDEX_MUSIC_TOKEN': 'previous-account'}), \
                     patch.object(music, 'read_app_session', return_value='current-account'), \
                     patch.object(music, 'installed_config', return_value={'secret': 'fixture', 'version': 'fixture'}), \
                     patch.object(music, 'dpapi', side_effect=lambda data, decrypt=False: data), \
                     patch.object(music, 'urlopen', side_effect=self.fixture_response), \
                     patch.object(music, 'download_audio', return_value={'file': 'synthetic.mp3'}), \
                     contextlib.redirect_stdout(io.StringIO()):
                    music.main()
                self.assertEqual(self.accounts, ['OAuth current-account'])
                self.assertEqual(json.loads(session.read_bytes())['token'], 'current-account')

    def test_cli_logout_cannot_use_a_previous_account_cache(self):
        for command in ('url', 'download', 'player'):
            with self.subTest(command=command), tempfile.TemporaryDirectory() as directory:
                session = Path(directory) / 'session.dpapi'
                previous = json.dumps({'token': 'previous-account', 'secret': 'fixture', 'version': 'fixture'}).encode()
                session.write_bytes(previous)
                arguments = ['music', '--session', str(session), command, '123']
                if command != 'url':
                    arguments += ['--out', str(Path(directory) / 'synthetic-output')]
                self.accounts = []
                with patch.object(sys, 'argv', arguments), \
                     patch.dict(os.environ, {'YANDEX_MUSIC_TOKEN': 'previous-account'}), \
                     patch.object(music, 'read_app_session', side_effect=RuntimeError('No current app session')), \
                     patch.object(music, 'installed_config', return_value={'secret': 'fixture', 'version': 'fixture'}), \
                     patch.object(music, 'dpapi', side_effect=lambda data, decrypt=False: data), \
                     patch.object(music, 'urlopen', side_effect=self.fixture_response), \
                     patch.object(music, 'download_audio', return_value={'file': 'synthetic.mp3'}), \
                     contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(RuntimeError, 'No current app session'):
                        music.main()
                self.assertEqual(self.accounts, [])
                self.assertEqual(session.read_bytes(), previous)


@unittest.skipUnless(shutil.which('node'), 'Node.js is unavailable in this test environment')
class CdpSetupTests(unittest.TestCase):
    def test_failed_setup_closes_socket_and_removes_only_created_registrations(self):
        result = subprocess.run([shutil.which('node'), str(ROOT / 'tests/release_runtime_fixture.mjs')],
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'scenarios': 5, 'liveNetworkRequests': 0})


if __name__ == '__main__':
    unittest.main(verbosity=2)
