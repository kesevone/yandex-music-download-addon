import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'src'))
import yandex_music as ym
import yandex_music_button as button


class Response(io.BytesIO):
    def __init__(self, payload, length=True):
        super().__init__(payload)
        self.headers = {'Content-Length': str(len(payload))} if length else {}


class ProgressTests(unittest.TestCase):
    def test_trickling_source_hits_total_deadline_and_removes_owned_partial(self):
        clock = {'now': 0}
        class TricklingResponse(Response):
            def read(self, size=-1):
                data = super().read(size)
                clock['now'] += len(data)
                return data

            def read1(self, size=-1):
                return self.read(min(size, 1))

        response = TricklingResponse(b'four')
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'deadline.mp3'
            with patch.dict(os.environ, {'YM_DOWNLOAD_TIMEOUT_SECONDS': '3'}), \
                 patch.object(ym, 'urlopen', return_value=response), \
                 patch.object(ym.time, 'monotonic', side_effect=lambda: clock['now']):
                with self.assertRaisesRegex(RuntimeError, 'download exceeded its time limit'):
                    ym.download_audio({'transport': 'raw', 'codec': 'mp3'}, 'https://example.invalid/audio', output)
            self.assertFalse(output.exists())
            self.assertFalse(output.with_name(output.name + '.part').exists())
            self.assertTrue(response.closed)
            self.assertLessEqual(clock['now'], 3)

    def test_default_total_deadline_is_finite(self):
        clock = {'now': 0}
        class LateResponse(Response):
            def read(self, size=-1):
                clock['now'] = 3601
                return super().read(size)

            def read1(self, size=-1):
                return self.read(size)

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'default-deadline.mp3'
            with patch.dict(os.environ):
                os.environ.pop('YM_DOWNLOAD_TIMEOUT_SECONDS', None)
                with patch.object(ym, 'urlopen', return_value=LateResponse(b'fixture')), \
                     patch.object(ym.time, 'monotonic', side_effect=lambda: clock['now']):
                    with self.assertRaisesRegex(RuntimeError, 'download exceeded its time limit'):
                        ym.download_audio({'transport': 'raw', 'codec': 'mp3'}, 'https://example.invalid/audio', output)
            self.assertFalse(output.exists())
            self.assertFalse(output.with_name(output.name + '.part').exists())

    def test_expired_connection_deadline_does_not_start_a_body_read(self):
        clock = {'now': 0}
        class UnreadResponse(Response):
            def read1(self, size=-1):
                raise AssertionError('An expired transfer must not start another body read')

        response = UnreadResponse(b'fixture')
        def connect(request, timeout):
            clock['now'] = 4
            return response

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'connection-deadline.mp3'
            with patch.dict(os.environ, {'YM_DOWNLOAD_TIMEOUT_SECONDS': '3'}), \
                 patch.object(ym, 'urlopen', side_effect=connect), \
                 patch.object(ym.time, 'monotonic', side_effect=lambda: clock['now']):
                with self.assertRaisesRegex(RuntimeError, 'download exceeded its time limit'):
                    ym.download_audio({'transport': 'raw', 'codec': 'mp3'}, 'https://example.invalid/audio', output)
            self.assertFalse(output.exists())
            self.assertFalse(output.with_name(output.name + '.part').exists())
            self.assertTrue(response.closed)

    def test_invalid_total_deadline_fails_before_network_or_file_creation(self):
        for value in ('', '0', '-1', '1.5', 'NaN', 'inf', '86401'):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / 'absent' / 'invalid.mp3'
                with patch.dict(os.environ, {'YM_DOWNLOAD_TIMEOUT_SECONDS': value}), \
                     patch.object(ym, 'urlopen', side_effect=AssertionError('Invalid timeout reached network')):
                    with self.assertRaisesRegex(ValueError, 'YM_DOWNLOAD_TIMEOUT_SECONDS'):
                        ym.download_audio({'transport': 'raw', 'codec': 'mp3'}, 'https://example.invalid/audio', output)
                self.assertFalse(output.parent.exists())

    def test_bytes_and_throttle(self):
        payload = b'local fixture' * 90000
        statuses = []
        ticks = iter(index * 0.1 for index in range(30))
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'fixture.mp3'
            with patch.object(ym, 'urlopen', return_value=Response(payload)), patch.object(ym.time, 'monotonic', side_effect=lambda: next(ticks)):
                result = ym.download_audio({'transport':'raw','codec':'mp3'}, 'https://example.invalid/fixture', output, statuses.append)
            self.assertEqual(output.read_bytes(), payload)
            self.assertEqual(result['bytes'], len(payload))
            self.assertEqual(statuses[0], {'phase':'download','received':0,'total':len(payload),'percent':0})
            self.assertEqual(statuses[-1], {'phase':'download','received':len(payload),'total':len(payload),'percent':100})
            self.assertGreater(len(statuses), 2)
            self.assertLess(len(statuses), 11)
            self.assertTrue(all(set(item) == {'phase','received','total','percent'} for item in statuses))
            self.assertEqual(sorted(item['received'] for item in statuses), [item['received'] for item in statuses])

    def test_unknown_length_and_truncation(self):
        with tempfile.TemporaryDirectory() as directory:
            statuses = []
            output = Path(directory) / 'unknown.mp3'
            with patch.object(ym, 'urlopen', return_value=Response(b'fixture', length=False)):
                ym.download_audio({'transport':'raw','codec':'mp3'}, 'https://example.invalid/fixture', output, statuses.append)
            self.assertEqual(statuses[-1], {'phase':'download','received':7,'total':None,'percent':None})
            response = Response(b'fixture')
            response.headers['Content-Length'] = '8'
            output = Path(directory) / 'truncated.mp3'
            with patch.object(ym, 'urlopen', return_value=response):
                with self.assertRaisesRegex(RuntimeError, 'Incomplete download'):
                    ym.download_audio({'transport':'raw','codec':'mp3'}, 'https://example.invalid/fixture', output, statuses.append)
            self.assertEqual(statuses[-1]['received'], 7)
            self.assertFalse(output.exists())
            self.assertFalse(output.with_name(output.name + '.part').exists())

    @unittest.skipUnless(shutil.which('ffmpeg'), 'FFmpeg is not installed in this test environment')
    def test_actual_flac_extract(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'synthetic.mp4'
            subprocess.run(['ffmpeg','-nostdin','-hide_banner','-loglevel','error','-f','lavfi','-i','anullsrc=r=44100:cl=stereo','-t','0.05','-c:a','flac','-strict','experimental',str(source)], check=True, capture_output=True)
            statuses = []
            output = Path(directory) / 'synthetic.flac'
            with patch.object(ym, 'urlopen', return_value=Response(source.read_bytes())):
                result = ym.download_audio({'transport':'raw','codec':'flac-mp4','quality':'lossless'}, 'https://example.invalid/fixture', output, statuses.append)
            self.assertEqual(statuses[-3]['phase'], 'download')
            self.assertEqual(statuses[-3]['received'], source.stat().st_size)
            self.assertEqual(statuses[-2], {'phase':'extract','received':0,'total':None,'percent':None})
            self.assertEqual(statuses[-1], {'phase':'extract','received':output.stat().st_size,'total':output.stat().st_size,'percent':100})
            self.assertFalse(result['reencoded'])
            self.assertEqual(ym.flac_streaminfo(output)['total_samples'], 2205)

    def test_button_json_lines(self):
        def fake_download(info, url, output, progress):
            progress({'phase':'download','received':0,'total':7,'percent':0})
            progress({'phase':'download','received':7,'total':7,'percent':100})
            return {'file':str(output),'bytes':7,'codec':'mp3'}
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()) as captured:
            with patch.object(sys, 'argv', ['button','123','--format','mp3']), patch.object(button, 'import_current_session', return_value={}), patch.object(button, 'get_source', return_value=('123',{'codec':'mp3'},'https://private.invalid/source')), patch.object(button, 'track_metadata', return_value={'id':'123','title':'Fixture','artists':['Synthetic'],'cover':None,'duration_ms':50}), patch.object(button, 'downloads_directory', return_value=Path(directory)), patch.object(button, 'download_audio', side_effect=fake_download):
                button.main()
            messages = [json.loads(line) for line in captured.getvalue().splitlines()]
        self.assertEqual([message['stage'] for message in messages], ['source','metadata','download','progress','progress','done'])
        self.assertNotIn('private.invalid', json.dumps(messages))
        self.assertEqual(messages[1]['metadata']['id'], '123')


if __name__ == '__main__':
    unittest.main(verbosity=2)
