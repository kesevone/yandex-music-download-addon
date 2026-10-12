import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ym', root / 'src/yandex_music.py')
ym = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ym)

class Response(io.BytesIO):
    def __init__(self, data):
        super().__init__(data)
        self.headers = {'Content-Length':str(len(data))}

class AudioSafetyTests(unittest.TestCase):
    def test_mp3_request_rejects_another_source_codec(self):
        for codec in ('aac', 'he-aac', 'flac', 'flac-mp4', None):
            with self.subTest(codec=codec):
                reply = {'result': {'downloadInfo': {
                    'transport': 'raw', 'codec': codec, 'quality': 'hq',
                    'urls': ['https://example.invalid/audio']}}}
                with patch.object(ym, 'urlopen', return_value=Response(json.dumps(reply).encode())):
                    with self.assertRaisesRegex(RuntimeError, 'requested MP3'):
                        ym.get_source('123', {'secret': 'fixture', 'token': 'fixture', 'version': 'fixture'}, 'hq', 'mp3')

    def test_lossless_label_on_mp3_is_rejected(self):
        reply = {'result':{'downloadInfo':{'transport':'raw','codec':'mp3','quality':'lossless',
                                           'urls':['https://example.invalid/audio']}}}
        with patch.object(ym,'urlopen',return_value=Response(json.dumps(reply).encode())):
            with self.assertRaisesRegex(RuntimeError,'No fallback was downloaded'):
                ym.get_source('19839489', {'secret':'fixture','token':'fixture','version':'fixture'},'lossless','flac')

    def test_mp3_disguised_as_flac_is_rejected_and_partial_removed(self):
        with tempfile.TemporaryDirectory(prefix='ym-flac-test-') as directory:
            output = Path(directory)/'track.flac'
            with patch.object(ym,'urlopen',return_value=Response(b'\xff\xfb'+b'not FLAC'*20)):
                with self.assertRaisesRegex(RuntimeError,'not a native FLAC'):
                    ym.download_audio({'codec':'flac','transport':'raw'},'https://example.invalid/audio',output)
            self.assertFalse(output.exists())
            self.assertFalse(output.with_name(output.name+'.part').exists())

    def test_existing_output_is_preserved_without_network(self):
        with tempfile.TemporaryDirectory(prefix='ym-flac-test-') as directory:
            output = Path(directory)/'track.flac'
            output.write_bytes(b'user file')
            with patch.object(ym,'urlopen') as network:
                with self.assertRaises(FileExistsError):
                    ym.download_audio({'codec':'flac','transport':'raw'},'https://example.invalid/audio',output)
                network.assert_not_called()
            self.assertEqual(output.read_bytes(),b'user file')

    def test_existing_remux_temporary_file_is_preserved(self):
        with tempfile.TemporaryDirectory(prefix='ym-flac-test-') as directory:
            output = Path(directory)/'track.flac'
            existing = output.with_name(output.name+'.part.flac')
            existing.write_bytes(b'user file')
            with patch.object(ym,'urlopen',return_value=Response(b'\x00\x00\x00\x1cftypisom'+b'fixture'*20)), \
                 patch.object(ym.shutil,'which',return_value='ffmpeg'):
                with self.assertRaises(FileExistsError):
                    ym.download_audio({'codec':'flac-mp4','transport':'raw','quality':'lossless'},'https://example.invalid/audio',output)
            self.assertEqual(existing.read_bytes(),b'user file')
            self.assertFalse(output.with_name(output.name+'.part').exists())

    def test_missing_ffmpeg_fails_before_download(self):
        with patch.object(ym.shutil,'which',return_value=None),patch.object(ym,'urlopen') as network:
            with self.assertRaisesRegex(RuntimeError,'FFmpeg is required'):
                ym.download_audio({'codec':'flac-mp4','transport':'raw','quality':'lossless'},
                                  'https://example.invalid/audio',Path('unused.flac'))
            network.assert_not_called()

    def test_incomplete_download_is_removed(self):
        with tempfile.TemporaryDirectory(prefix='ym-flac-test-') as directory:
            output = Path(directory)/'track.mp3'
            response = Response(b'bytes')
            response.headers['Content-Length']='8'
            with patch.object(ym,'urlopen',return_value=response):
                with self.assertRaisesRegex(RuntimeError,'Incomplete download'):
                    ym.download_audio({'codec':'mp3','transport':'raw'},'https://example.invalid/audio',output)
            self.assertFalse(output.exists())
            self.assertFalse(output.with_name(output.name+'.part').exists())

if __name__=='__main__':
    unittest.main(verbosity=2)
