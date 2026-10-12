"""Portable session lifecycle checks. Fixtures never use a real user session."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'src'
spec = importlib.util.spec_from_file_location('portable_music', SOURCE / 'yandex_music.py')
music = importlib.util.module_from_spec(spec)
spec.loader.exec_module(music)


class Response(io.BytesIO):
    def __init__(self, data):
        super().__init__(data)
        self.headers = {'Content-Length': str(len(data))}


class PortableRuntimeTests(unittest.TestCase):
    def test_session_and_app_paths_follow_install_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / 'state'
            archive = Path(directory) / 'Music' / 'resources' / 'app.asar'
            env = {**os.environ, 'YM_WORK_DIR': str(state), 'YM_APP_ASAR': str(archive)}
            script = ('import runpy,json; m=runpy.run_path(' + repr(str(SOURCE / 'yandex_music.py')) + '); '
                      'print(json.dumps([str(m["SESSION_PATH"]),str(m["APP_ASAR"])]))')
            result = subprocess.run([sys.executable, '-I', '-c', script], env=env,
                                    capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout), [str(state / '.yandex-music-session.dpapi'), str(archive)])
            self.assertFalse(state.exists())

    def test_button_can_import_sibling_module_with_isolated_python(self):
        result = subprocess.run([sys.executable, '-I', str(SOURCE / 'yandex_music_button.py'), '--help'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--format', result.stdout)

    def test_current_app_session_replaces_previous_account_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            session = Path(directory) / 'state' / '.yandex-music-session.dpapi'
            session.parent.mkdir()
            session.write_bytes(b'previous-account-encrypted-fixture')
            with patch.object(music, 'read_app_session', return_value='current-account-fixture') as read, \
                 patch.object(music, 'installed_config', return_value={'secret': 'fixture', 'version': 'fixture'}) as config, \
                 patch.object(music, 'dpapi', side_effect=lambda data, decrypt=False: b'protected:' + data), \
                 contextlib.redirect_stdout(io.StringIO()) as output:
                state = music.import_current_session(Path(directory) / 'app.asar', session, 9929)
            read.assert_called_once_with(9929)
            config.assert_called_once_with(Path(directory) / 'app.asar')
            self.assertEqual(state['token'], 'current-account-fixture')
            self.assertTrue(session.read_bytes().startswith(b'protected:'))
            self.assertNotIn(b'previous-account', session.read_bytes())
            self.assertFalse(session.with_name(session.name + '.tmp').exists())
            self.assertEqual(output.getvalue(), '')

    def test_logout_never_falls_back_to_old_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            session = Path(directory) / '.yandex-music-session.dpapi'
            previous = b'old-session-fixture'
            session.write_bytes(previous)
            with patch.object(music, 'read_app_session', side_effect=RuntimeError('No current app session')), \
                 patch.object(music, 'load_state') as old_cache, patch.object(music, 'installed_config') as config:
                with self.assertRaisesRegex(RuntimeError, 'No current app session'):
                    music.import_current_session(Path(directory) / 'app.asar', session)
            old_cache.assert_not_called()
            config.assert_not_called()
            self.assertEqual(session.read_bytes(), previous)

    def test_portable_node_path_and_private_child_output(self):
        result = subprocess.CompletedProcess([], 0, json.dumps({'token': 'synthetic-private-fixture'}), '')
        with patch.dict(os.environ, {'YM_NODE': 'portable-node.exe'}), \
             patch.object(music.subprocess, 'run', return_value=result) as run, \
             contextlib.redirect_stdout(io.StringIO()) as output:
            token = music.read_app_session(9229)
        self.assertEqual(token, 'synthetic-private-fixture')
        self.assertEqual(run.call_args.args[0], ['portable-node.exe', str(SOURCE / 'ym-session-export.mjs'), '9229'])
        self.assertTrue(run.call_args.kwargs['capture_output'])
        self.assertEqual(output.getvalue(), '')

    def test_failed_child_diagnostics_are_not_exposed(self):
        result = subprocess.CompletedProcess([], 1, 'private-stdout-fixture', 'private-stderr-fixture')
        with patch.dict(os.environ, {'YM_NODE': 'portable-node.exe'}), \
             patch.object(music.subprocess, 'run', return_value=result):
            with self.assertRaises(RuntimeError) as error:
                music.read_app_session()
        self.assertNotIn('private-', str(error.exception))

    def test_configured_ffmpeg_path_is_used_without_system_path(self):
        payload = b'\x00\x00\x00\x1cftypisom' + b'synthetic container' * 10
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'synthetic.flac'
            def remux(argv, **kwargs):
                Path(argv[-1]).write_bytes(b'synthetic native FLAC fixture')
                return subprocess.CompletedProcess(argv, 0, '', '')
            with patch.dict(os.environ, {'YM_FFMPEG': 'portable-ffmpeg.exe'}), \
                 patch.object(music, 'urlopen', return_value=Response(payload)), \
                 patch.object(music.shutil, 'which', side_effect=AssertionError('System ffmpeg must not be needed')), \
                 patch.object(music.subprocess, 'run', side_effect=remux) as run, \
                 patch.object(music, 'flac_streaminfo', return_value={'sample_rate': 44100}):
                result = music.download_audio({'transport': 'raw', 'codec': 'flac-mp4', 'quality': 'lossless'},
                                              'https://example.invalid/synthetic', output)
            self.assertEqual(run.call_args.args[0][0], 'portable-ffmpeg.exe')
            self.assertIn('copy', run.call_args.args[0])
            self.assertFalse(result['reencoded'])
            self.assertTrue(output.exists())

    @unittest.skipUnless(os.name == 'nt', 'Windows user encryption')
    def test_windows_cache_is_actually_protected(self):
        state = {'token': 'synthetic-private-session', 'secret': 'fixture', 'version': 'fixture'}
        with tempfile.TemporaryDirectory() as directory:
            session = Path(directory) / 'state' / '.yandex-music-session.dpapi'
            music.save_session(state, session)
            encrypted = session.read_bytes()
            self.assertNotIn(state['token'].encode(), encrypted)
            self.assertEqual(json.loads(music.dpapi(encrypted, decrypt=True)), state)


@unittest.skipUnless(os.name == 'nt', 'Windows shortcut restoration')
class UninstallBackupTests(unittest.TestCase):
    def make_fixture(self, directory, recorded_hash='valid', unicode_paths=False):
        root = Path(directory)
        state = root / 'state'
        state.mkdir()
        shortcut = root / ('аддон.lnk' if unicode_paths else 'managed.lnk')
        backup = root / ('оригинал.lnk' if unicode_paths else 'original.lnk')
        app = root / ('Яндекс Музыка.exe' if unicode_paths else 'app.exe')
        if unicode_paths:
            shutil.copyfile(sys.executable, app)
        powershell = Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
        def literal(value):
            return "'" + str(value).replace("'", "''") + "'"
        setup = (' . ' + literal(SOURCE / 'ym-shortcuts.ps1') + '; $s=New-YandexShortcutShell;'
                 ' $original=$s.CreateShortcut(' + literal(backup) + ');'
                 ' $original.TargetPath=' + literal(app) + '; $original.Save();'
                 ' $current=$s.CreateShortcut(' + literal(shortcut) + ');'
                 ' $current.TargetPath=Join-Path $env:SystemRoot "System32\\wscript.exe";'
                 ' $current.Arguments="--addon-fixture"; $current.Save();')
        subprocess.run([str(powershell), '-NoProfile', '-NonInteractive', '-Command', setup],
                       capture_output=True, check=True)
        record = {'path': str(shortcut), 'backup': str(backup), 'installedArguments': '--addon-fixture'}
        if recorded_hash == 'valid':
            record['backupSha256'] = hashlib.sha256(backup.read_bytes()).hexdigest().upper()
        elif recorded_hash != 'legacy':
            record['backupSha256'] = recorded_hash
        config = root / 'config.json'
        config.write_text(json.dumps({'enabled': True, 'bundleDir': str(SOURCE), 'shortcuts': [record]}),
                          encoding='utf-8-sig')
        return root, shortcut, backup, config, powershell

    def uninstall(self, root, powershell):
        return subprocess.run([str(powershell), '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                               '-File', str(SOURCE / 'uninstall_music_autoload.ps1'), '-InstallRoot', str(root)],
                              capture_output=True)

    def assert_no_mutation(self, root, shortcut, config, powershell, error_code):
        lock = root / 'state/button-helper.json'
        lock.write_text('{"pid":"invalid-fixture","instance":"fixture","script":"fixture"}', encoding='utf-8')
        before = [path.read_bytes() for path in (shortcut, config, lock)]
        result = self.uninstall(root, powershell)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(error_code, result.stderr)
        self.assertEqual(before, [path.read_bytes() for path in (shortcut, config, lock)])
        self.assertFalse((root / 'state/button-helper-stop.json').exists())

    def test_tampered_backup_rejected_before_helper_or_shortcut_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root, shortcut, backup, config, powershell = self.make_fixture(directory)
            backup.write_bytes(backup.read_bytes() + b'synthetic tamper fixture')
            self.assert_no_mutation(root, shortcut, config, powershell, b'BACKUP_HASH_MISMATCH')

    def test_malformed_recorded_hash_rejected_before_changes(self):
        for malformed in ('', 'ABC', 'z' * 64, None):
            with self.subTest(hash=malformed), tempfile.TemporaryDirectory() as directory:
                root, shortcut, _, config, powershell = self.make_fixture(directory, malformed)
                self.assert_no_mutation(root, shortcut, config, powershell, b'BACKUP_HASH_INVALID')

    def test_valid_and_legacy_backup_restore_exact_bytes(self):
        for recorded_hash in ('valid', 'legacy'):
            with self.subTest(recorded_hash=recorded_hash), tempfile.TemporaryDirectory() as directory:
                root, shortcut, backup, config, powershell = self.make_fixture(directory, recorded_hash)
                expected = backup.read_bytes()
                result = self.uninstall(root, powershell)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(shortcut.read_bytes(), expected)
                self.assertEqual(backup.read_bytes(), expected)
                self.assertFalse(json.loads(config.read_text(encoding='utf-8-sig'))['enabled'])

    def test_unicode_shortcuts_restore_without_changing_native_target(self):
        with tempfile.TemporaryDirectory() as directory:
            unicode_root = Path(directory) / 'Музыка проверка'
            unicode_root.mkdir()
            root, shortcut, backup, config, powershell = self.make_fixture(unicode_root, unicode_paths=True)
            expected = backup.read_bytes()
            result = self.uninstall(root, powershell)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(shortcut.read_bytes(), expected)
            # Windows TEMP can use an 8.3 account-directory alias. Shell Link
            # returns the existing file's long name; resolve that identity while
            # retaining exact Unicode directory and executable-name checks.
            expected_target = (root / 'Яндекс Музыка.exe').resolve(strict=True)
            self.assertEqual(expected_target.name, 'Яндекс Музыка.exe')
            self.assertIn('Музыка проверка', expected_target.parts)
            def literal(value):
                return "'" + str(value).replace("'", "''") + "'"
            inspect = ('. ' + literal(SOURCE / 'ym-shortcuts.ps1') + '; '
                       '$s=New-YandexShortcutShell; $lnk=$s.CreateShortcut(' + literal(shortcut) + '); '
                       '$actual=$lnk.TargetPath; $expected=' + literal(expected_target) + '; '
                       'if($actual -cne $expected){'
                       '[Console]::Error.WriteLine(([ordered]@{actual=$actual;expected=$expected} | ConvertTo-Json -Compress)); '
                       'throw "Unicode target changed"}; '
                       'Write-Output "unicode fixture passed"')
            read = subprocess.run([str(powershell), '-NoProfile', '-NonInteractive', '-Command', inspect],
                                  capture_output=True)
            self.assertEqual(read.returncode, 0, read.stderr)
            self.assertIn(b'unicode fixture passed', read.stdout)


@unittest.skipUnless(os.name == 'nt', 'Windows PowerShell helper lock lifecycle')
class HelperLockRaceTests(unittest.TestCase):
    def run_functions(self, source_name, directory, body):
        powershell = Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
        def literal(value):
            return "'" + str(value).replace("'", "''") + "'"
        # Load only function definitions. No app launch, config writes or uninstall.
        setup = ('$ErrorActionPreference="Stop"; $t=$null; $e=$null;'
                 ' $a=[System.Management.Automation.Language.Parser]::ParseFile(' + literal(SOURCE / source_name) + ',[ref]$t,[ref]$e);'
                 ' if($e.Count){throw "Invalid fixture source"};'
                 ' $a.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and'
                 ' $n.Name -in @("Read-HelperLockText","Read-HelperOwner")},$true) |'
                 ' ForEach-Object {Invoke-Expression $_.Extent.Text};'
                 ' $directory=' + literal(directory) + '; $lock=Join-Path $directory "button-helper.json";')
        result = subprocess.run([str(powershell), '-NoProfile', '-NonInteractive', '-Command', setup + body],
                                capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b'fixture passed', result.stdout)

    def test_lock_disappearing_between_exists_and_read_is_absent(self):
        for source in ('launch_music_installed.ps1', 'uninstall_music_autoload.ps1'):
            with self.subTest(source=source), tempfile.TemporaryDirectory() as directory:
                (Path(directory) / 'button-helper.json').write_text('{"fixture":true}', encoding='utf-8')
                body = (' function Test-Path {param([string]$LiteralPath) [IO.File]::Delete($LiteralPath); return $true};'
                        ' function Get-CimInstance {throw "Process inspection must not be reached"};')
                if source.startswith('launch'):
                    body += ' if($null -ne (Read-HelperOwner $directory "fixture.mjs")){throw "Owner survived disappeared lock"};'
                else:
                    body += ' if(Test-Path -LiteralPath $lock){if($null -ne (Read-HelperLockText $lock)){throw "Lock survived deletion"}};'
                self.run_functions(source, directory, body + ' Write-Output "fixture passed"')

    def test_sharing_errors_are_not_swallowed_as_missing_lock(self):
        for source in ('launch_music_installed.ps1', 'uninstall_music_autoload.ps1'):
            with self.subTest(source=source), tempfile.TemporaryDirectory() as directory:
                (Path(directory) / 'button-helper.json').write_text('{"fixture":true}', encoding='utf-8')
                body = (' $held=[IO.File]::Open($lock,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);'
                        ' $failed=$false; try{$null=Read-HelperLockText $lock}catch{$failed=$true}finally{$held.Dispose()};'
                        ' if(-not $failed){throw "File access error was swallowed"}; Write-Output "fixture passed"')
                self.run_functions(source, directory, body)

    def test_launcher_malformed_owner_is_still_rejected(self):
        for malformed in ('{', 'null', '{"pid":"invalid"}'):
            with self.subTest(lock=malformed), tempfile.TemporaryDirectory() as directory:
                (Path(directory) / 'button-helper.json').write_text(malformed, encoding='utf-8')
                body = (' function Get-CimInstance {throw "Invalid owner reached process inspection"};'
                        ' $failed=$false; try{$null=Read-HelperOwner $directory "fixture.mjs"}catch{$failed=$true};'
                        ' if(-not $failed){throw "Malformed owner was accepted"}; Write-Output "fixture passed"')
                self.run_functions('launch_music_installed.ps1', directory, body)


    def test_dead_process_lock_disappearing_before_cleanup_is_absent(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'button-helper.json').write_text(
                '{"pid":123,"instance":"fixture","script":"fixture.mjs"}', encoding='utf-8')
            body = (' function Get-CimInstance {[IO.File]::Delete($lock); return $null};'
                    ' if($null -ne (Read-HelperOwner $directory "fixture.mjs")){throw "Dead owner survived cleanup"};'
                    ' Write-Output "fixture passed"')
            self.run_functions('launch_music_installed.ps1', directory, body)


@unittest.skipUnless(os.name == 'nt', 'Windows addon lifecycle serialization')
class LifecycleSerializationTests(unittest.TestCase):
    def test_launcher_waits_for_update_and_reads_committed_config(self):
        powershell = Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'

        def literal(value):
            return "'" + str(value).replace("'", "''") + "'"

        def wait_file(path, process):
            deadline = time.monotonic() + 15
            while not path.exists():
                self.assertIsNone(process.poll(), 'Fixture process exited before synchronization')
                self.assertLess(time.monotonic(), deadline, 'Fixture synchronization timed out')
                time.sleep(0.05)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready, release, launched = (root / name for name in ('ready', 'release', 'launched'))
            # This fake update holds the exact same mutex as the real installer.
            # Config is deliberately absent until commit; an early launcher read
            # fails, and an early fake app start is observable without an app.
            holder = ('. ' + literal(SOURCE / 'ym-shortcuts.ps1') + '; '
                      '$m=New-YandexLifecycleMutex ' + literal(root) + '; '
                      'if(-not (Enter-YandexLifecycleMutex $m)){throw "Fixture mutex unavailable"}; '
                      'try{[IO.File]::WriteAllText(' + literal(ready) + ',"ready"); '
                      'while(-not [IO.File]::Exists(' + literal(release) + ')){Start-Sleep -Milliseconds 50}; '
                      '@{enabled=$false;appExe="fixture-new.exe";shortcuts=@()} | ConvertTo-Json | '
                      'Set-Content -LiteralPath ' + literal(root / 'config.json') + ' -Encoding UTF8'
                      '}finally{$m.ReleaseMutex();$m.Dispose()}')
            update = subprocess.Popen([str(powershell), '-NoProfile', '-NonInteractive', '-Command', holder],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            launcher = None
            try:
                wait_file(ready, update)
                launch = ('function Start-Process {param($FilePath,$ArgumentList) '
                          '[IO.File]::WriteAllText(' + literal(launched) + ',$FilePath)}; '
                          '& ' + literal(SOURCE / 'launch_music_installed.ps1') + ' -InstallRoot ' + literal(root))
                launcher = subprocess.Popen([str(powershell), '-NoProfile', '-NonInteractive',
                                             '-ExecutionPolicy', 'Bypass', '-Command', launch],
                                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                time.sleep(0.6)
                self.assertIsNone(launcher.poll(), 'Launcher did not wait for config transition')
                self.assertFalse(launched.exists(), 'Launcher started app before update commit')
                release.write_text('release')
                _, errors = update.communicate(timeout=15)
                self.assertEqual(update.returncode, 0, errors)
                _, errors = launcher.communicate(timeout=15)
                self.assertEqual(launcher.returncode, 0, errors)
                self.assertEqual(launched.read_text(), 'fixture-new.exe')
            finally:
                release.write_text('release')
                for process in (launcher, update):
                    if process is not None and process.poll() is None:
                        process.kill()
                        process.communicate()

    def test_removal_respects_setup_download_lock(self):
        powershell = Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'

        def literal(value):
            return "'" + str(value).replace("'", "''") + "'"

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'config.json'
            config.write_text(json.dumps({'enabled': True, 'shortcuts': []}), encoding='utf-8-sig')
            # A distinct process is necessary: the setup-to-uninstall call in the
            # installer intentionally takes this mutex reentrantly on one thread.
            test = ('. ' + literal(SOURCE / 'ym-shortcuts.ps1') + '; '
                    '$m=New-YandexLifecycleMutex ' + literal(root) + ' "Setup"; '
                    'if(-not (Enter-YandexLifecycleMutex $m)){throw "Fixture mutex unavailable"}; '
                    'try{& ' + literal(powershell) + ' -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '
                    + literal(SOURCE / 'uninstall_music_autoload.ps1') + ' -InstallRoot ' + literal(root) + '; '
                    'if($LASTEXITCODE -eq 0){throw "Removal ignored setup mutex"}; '
                    'Write-Output "fixture passed"}finally{$m.ReleaseMutex();$m.Dispose()}')
            before = config.read_bytes()
            result = subprocess.run([str(powershell), '-NoProfile', '-NonInteractive', '-Command', test],
                                    capture_output=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(b'fixture passed', result.stdout)
            self.assertEqual(config.read_bytes(), before)

if __name__ == '__main__':
    unittest.main(verbosity=2)
