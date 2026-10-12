"""Request RAW audio with the user's Yandex Music session. FLAC container extraction uses FFmpeg."""
import argparse
import base64
import ctypes
from ctypes import wintypes
import getpass
import hashlib
import hmac
import html
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
sys.dont_write_bytecode = True
import time
from urllib.error import HTTPError
from urllib.parse import urlencode, urlparse, parse_qs
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent
STATE_ROOT = Path(os.environ.get('YM_WORK_DIR') or
                  str(Path(os.environ.get('LOCALAPPDATA', str(Path.home()))) /
                      'YandexMusicDownloadAddon' / 'state'))
SESSION_PATH = STATE_ROOT / '.yandex-music-session.dpapi'
APP_ASAR = Path(os.environ.get('YM_APP_ASAR') or
                str(Path(os.environ.get('LOCALAPPDATA', '.')) /
                    'Programs/YandexMusic/resources/app.asar'))
API = 'https://api.music.yandex.ru/'

def dpapi(data, decrypt=False):
    if os.name != 'nt':
        raise RuntimeError('The protected session cache requires Windows; use YANDEX_MUSIC_TOKEN on other systems.')
    class Blob(ctypes.Structure):
        _fields_ = [('length', wintypes.DWORD), ('data', ctypes.POINTER(ctypes.c_ubyte))]
    crypt = ctypes.WinDLL('crypt32', use_last_error=True)
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.LocalFree.restype = ctypes.c_void_p
    buffer = ctypes.create_string_buffer(data)
    source = Blob(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte)))
    target = Blob()
    function = crypt.CryptUnprotectData if decrypt else crypt.CryptProtectData
    function.argtypes = [ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob)]
    function.restype = wintypes.BOOL
    if not function(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(target)):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        return ctypes.string_at(target.data, target.length)
    finally:
        kernel.LocalFree(ctypes.cast(target.data, ctypes.c_void_p))

def installed_config(archive):
    with archive.open('rb') as f:
        prefix = f.read(16)
        header_size = struct.unpack_from('<I', prefix, 4)[0]
        json_size = struct.unpack_from('<I', prefix, 12)[0]
        header = json.loads(f.read(json_size))
        base = 8 + header_size
        entries = {}
        def walk(node, parent=''):
            for name, item in node.get('files', {}).items():
                key = f'{parent}/{name}'.lstrip('/')
                if 'files' in item:
                    walk(item, key)
                else:
                    entries[key] = item
        walk(header)
        def read(name):
            entry = entries[name]
            if entry.get('unpacked'):
                return Path(str(archive) + '.unpacked', name).read_bytes()
            f.seek(base + int(entry['offset']))
            data = f.read(entry['size'])
            if len(data) != entry['size']:
                raise RuntimeError('Incomplete ASAR read')
            return data
        version = json.loads(read('package.json'))['version']
        for name in sorted(entries):
            if re.fullmatch(r'app/_next/static/chunks/[^/]+\.js', name):
                source = read(name).decode('utf-8')
                config = re.search(r'player:\{secretKey:\{([^}]+)\}', source)
                match = re.search(r'win32:"([^"]+)"', config[1]) if config else None
                if match:
                    return {'secret': match[1], 'version': version}
    raise RuntimeError('Signing configuration not found in this installed version')

def load_state(args):
    token = os.environ.get('YANDEX_MUSIC_TOKEN')
    if token:
        return {**installed_config(args.app), 'token': token}
    if not args.session.exists():
        raise RuntimeError('Run login first, or set YANDEX_MUSIC_TOKEN.')
    return json.loads(dpapi(args.session.read_bytes(), decrypt=True))

def save_session(state, session):
    """Keep the Windows-user encrypted cache in writable state, never the bundle."""
    session = Path(session)
    session.parent.mkdir(parents=True, exist_ok=True)
    protected = dpapi(json.dumps(state).encode())
    temporary = session.with_name(session.name + '.tmp')
    try:
        temporary.write_bytes(protected)
        temporary.replace(session)
    finally:
        temporary.unlink(missing_ok=True)

def read_app_session(port=9229):
    """Consume child stdout privately; never expose tokens or child diagnostics."""
    if not isinstance(port, int) or not 1 <= port <= 65535:
        raise ValueError('Invalid local app port.')
    node = os.environ.get('YM_NODE') or shutil.which('node')
    if not node:
        raise RuntimeError('Cannot start the installed session helper.')
    process = subprocess.run([node, str(ROOT / 'ym-session-export.mjs'), str(port)],
                             capture_output=True, text=True, timeout=20,
                             creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
    if process.returncode:
        raise RuntimeError('Cannot read the current Music session. Open the signed-in app using the addon shortcut.')
    try:
        token = json.loads(process.stdout)['token']
    except (ValueError, KeyError, TypeError):
        raise RuntimeError('The signed-in app did not provide a session.') from None
    if not isinstance(token, str) or not token:
        raise RuntimeError('The signed-in app did not provide a session.')
    return token

def import_current_session(archive=APP_ASAR, session=SESSION_PATH, port=9229):
    """Refresh for each job; a previous account's cache is never a fallback."""
    token = read_app_session(port)
    state = {**installed_config(Path(archive)), 'token': token}
    save_session(state, session)
    return state

def track_id(value):
    value = str(value)
    if re.fullmatch(r'\d+', value):
        return value
    parsed = urlparse(value)
    match = re.search(r'/track/(\d+)(?:/|$)', parsed.path)
    if match:
        return match[1]
    candidates = parse_qs(parsed.query).get('trackId', [])
    if candidates and re.fullmatch(r'\d+', candidates[0]):
        return candidates[0]
    raise ValueError('Use a numeric track ID or a Yandex Music track URL.')

def api_headers(state):
    return {'Authorization': 'OAuth ' + state['token'],
            'X-Yandex-Music-Client': 'YandexMusicDesktopAppWindows/' + state['version'],
            'Accept-Language': 'ru'}

def track_metadata(track, state):
    """Return display metadata for one track, without credentials or stream URLs."""
    tid = track_id(track)
    with urlopen(Request(API + 'tracks/' + tid, headers=api_headers(state)), timeout=30) as response:
        result = json.load(response).get('result', [])
    if not isinstance(result, list) or not result:
        raise RuntimeError('Music API did not provide track metadata.')
    entry = result[0]
    cover = entry.get('coverUri')
    return {'id': tid, 'title': entry.get('title', 'Трек ' + tid),
            'version': entry.get('version'),
            'artists': [artist.get('name', '') for artist in entry.get('artists', [])],
            'albums': [{'id': str(album.get('id', '')), 'title': album.get('title', '')}
                       for album in entry.get('albums', [])],
            'duration_ms': entry.get('durationMs'),
            'cover': 'https://' + cover.replace('%%', '400x400') if cover else None,
            'available': entry.get('available')}

def get_source(track, state, quality='hq', codec='mp3'):
    """Return (track_id, download_info, HTTPS URL) for RAW audio.

    FLAC/lossless requests never silently accept the server's MP3 fallback.
    MP3 requests likewise reject a different source codec before saving a file.
    """
    tid = track_id(track)
    if quality not in ('hq', 'lossless', 'nq', 'lq') or codec not in ('mp3', 'flac', 'aac', 'he-aac'):
        raise ValueError('Unsupported audio quality or codec.')
    if (quality == 'lossless') != (codec == 'flac'):
        raise ValueError('Lossless downloads require quality=lossless and codec=flac; use --flac.')
    # The current catalog serves lossless FLAC inside MP4. Requesting plain
    # "flac" alone can return MP3 while still labeling its quality "lossless".
    codecs = ['flac-mp4', 'flac'] if codec == 'flac' else [codec]
    stamp = str(int(time.time()))
    data = stamp + tid + quality + ''.join(codecs) + 'raw'
    signature = base64.b64encode(hmac.new(state['secret'].encode(), data.encode(), hashlib.sha256).digest()).decode()[:-1]
    params = {'ts':stamp,'trackId':tid,'quality':quality,'codecs':','.join(codecs),'transports':'raw','sign':signature}
    headers = api_headers(state)
    with urlopen(Request(API + 'get-file-info?' + urlencode(params), headers=headers), timeout=30) as response:
        result = json.load(response)
    result = result.get('result', result)
    info = result.get('downloadInfo', result)
    if 'error' in info:
        raise RuntimeError('Music API did not provide an audio source: ' + str(info['error']))
    if info.get('transport') != 'raw' or not info.get('urls'):
        raise RuntimeError('The server did not return RAW audio for this track/quality.')
    if codec == 'flac' and (info.get('codec') not in ('flac', 'flac-mp4') or info.get('quality') != 'lossless'):
        raise RuntimeError('Lossless FLAC is unavailable for this track/session: the server returned ' +
                           str(info.get('codec', 'unknown')) + '. No fallback was downloaded.')
    if codec == 'mp3' and info.get('codec') != 'mp3':
        raise RuntimeError('The server did not return the requested MP3 audio. No fallback was downloaded.')
    url = info['urls'][0]
    if urlparse(url).scheme != 'https':
        raise RuntimeError('The server returned a non-HTTPS audio URL.')
    return tid, info, url

def raw_source(args, state):
    """Compatibility wrapper for the original command-line interface."""
    return get_source(args.track, state, args.quality, args.codec)

def flac_streaminfo(path):
    """Validate the native FLAC header and read its STREAMINFO without conversion."""
    with Path(path).open('rb') as source:
        header = source.read(42)
    if len(header) != 42 or header[:4] != b'fLaC' or header[4] & 0x7f != 0 or int.from_bytes(header[5:8], 'big') != 34:
        raise RuntimeError('The downloaded source is not a native FLAC file; it was not saved.')
    packed = int.from_bytes(header[18:26], 'big')
    sample_rate = packed >> 44
    channels = ((packed >> 41) & 7) + 1
    bits_per_sample = ((packed >> 36) & 31) + 1
    total_samples = packed & ((1 << 36) - 1)
    if not sample_rate or bits_per_sample < 4 or Path(path).stat().st_size <= 42:
        raise RuntimeError('Invalid FLAC STREAMINFO; the file was not saved.')
    return {'sample_rate': sample_rate, 'channels': channels,
            'bits_per_sample': bits_per_sample, 'total_samples': total_samples,
            'pcm_md5': header[26:42].hex()}

def download_audio(info, url, output, progress=None):
    """Download RAW audio, extract FLAC packets losslessly, preserve existing files.

    Return a safe dictionary containing the filename, size and format properties.
    Optional progress callbacks receive phase, received, total and percent only.
    """
    output = Path(output)
    if info.get('transport') != 'raw' or urlparse(url).scheme != 'https':
        raise ValueError('Downloads require a RAW HTTPS audio source.')
    if info.get('codec') == 'flac-mp4' and info.get('quality') != 'lossless':
        raise ValueError('The server did not identify the FLAC source as lossless.')
    ffmpeg = (os.environ.get('YM_FFMPEG') or shutil.which('ffmpeg')) if info.get('codec') == 'flac-mp4' else None
    if info.get('codec') == 'flac-mp4' and not ffmpeg:
        raise RuntimeError('FFmpeg is required to extract the original FLAC from its MP4 container. Install FFmpeg and add it to PATH.')
    if output.exists():
        raise FileExistsError(f'Output already exists: {output}')
    try:
        transfer_limit = int(os.environ.get('YM_DOWNLOAD_TIMEOUT_SECONDS', '3600'))
    except ValueError:
        raise ValueError('YM_DOWNLOAD_TIMEOUT_SECONDS must be an integer from 1 to 86400.') from None
    if not 1 <= transfer_limit <= 86400:
        raise ValueError('YM_DOWNLOAD_TIMEOUT_SECONDS must be an integer from 1 to 86400.')
    output.parent.mkdir(parents=True, exist_ok=True)
    partial = output.with_name(output.name + '.part')
    total = 0
    created = False
    extracted = None
    extracted_created = False
    properties = {}
    deadline = time.monotonic() + transfer_limit
    def report(phase, received, expected, finished=False):
        if progress is not None:
            percent = min(100, round(received * 100 / expected, 1)) if expected else None
            if finished and phase == 'extract':
                percent = 100
            progress({'phase': phase, 'received': received, 'total': expected, 'percent': percent})
    try:
        with urlopen(Request(url), timeout=min(60, transfer_limit)) as response, partial.open('xb') as destination:
            created = True
            length = response.headers.get('Content-Length')
            expected = int(length) if length is not None else None
            report('download', 0, expected)
            last_report = time.monotonic()
            if last_report >= deadline:
                raise RuntimeError('Audio download exceeded its time limit.')
            # read1 returns after one buffered/socket read, so a trickling source
            # cannot hide inside a fill-read beyond the total transfer deadline.
            while True:
                chunk = response.read1(128 * 1024)
                now = time.monotonic()
                if now >= deadline:
                    raise RuntimeError('Audio download exceeded its time limit.')
                if not chunk:
                    break
                destination.write(chunk)
                total += len(chunk)
                if now - last_report >= 0.15:
                    report('download', total, expected)
                    last_report = now
            report('download', total, expected, finished=True)
        if expected is not None and total != expected:
            raise RuntimeError(f'Incomplete download: received {total} of {expected} bytes')
        if not total:
            raise RuntimeError('The server returned an empty audio file.')
        source_bytes = total
        if info.get('codec') == 'flac-mp4':
            with partial.open('rb') as source:
                if source.read(8)[4:8] != b'ftyp':
                    raise RuntimeError('The downloaded FLAC source is not the expected MP4 container.')
            extracted = partial.with_name(partial.name + '.flac')
            # Claim the temporary path before FFmpeg may write it; -y overwrites
            # only this file owned by this download, never the final output.
            with extracted.open('xb'):
                pass
            extracted_created = True
            report('extract', 0, None)
            process = subprocess.run([ffmpeg, '-nostdin', '-hide_banner', '-loglevel', 'error',
                '-y', '-protocol_whitelist', 'file,pipe', '-i', str(partial),
                '-map', '0:a:0', '-c:a', 'copy', '-f', 'flac', str(extracted)],
                capture_output=True, text=True, timeout=120,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
            if process.returncode:
                raise RuntimeError('FFmpeg could not extract the FLAC audio without re-encoding.')
            properties = flac_streaminfo(extracted)
            properties['source_codec'] = 'flac-mp4'
            properties['source_bytes'] = source_bytes
            properties['remuxed'] = True
            properties['reencoded'] = False
            partial.unlink()
            extracted.rename(partial)
            extracted = None
            extracted_created = False
            total = partial.stat().st_size
            report('extract', total, total, finished=True)
        elif info.get('codec') == 'flac':
            properties = flac_streaminfo(partial)
        if output.exists():
            raise FileExistsError(f'Output already exists: {output}')
        if os.name == 'nt':
            partial.rename(output)  # Windows rename fails if the destination exists.
        else:
            os.link(partial, output)  # Atomically publish without overwriting on POSIX.
            partial.unlink()
    except Exception:
        if created:
            partial.unlink(missing_ok=True)
        if extracted_created:
            extracted.unlink(missing_ok=True)
        raise
    return {'file': str(output.resolve()), 'bytes': total,
            'codec': 'flac' if info['codec'] == 'flac-mp4' else info['codec'],
            'bitrate': info.get('bitrate'), 'transport': info['transport'], **properties}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--session', type=Path, default=SESSION_PATH)
    parser.add_argument('--app', type=Path, default=APP_ASAR)
    commands = parser.add_subparsers(dest='command', required=True)
    login = commands.add_parser('login', help='Save an OAuth session encrypted for the current Windows user')
    login.add_argument('--from-app', action='store_true')
    login.add_argument('--port', type=int, default=9229)
    for name in ['url', 'download', 'player']:
        command = commands.add_parser(name)
        command.add_argument('track')
        command.add_argument('--quality', choices=['hq','lossless','nq','lq'], default='hq')
        command.add_argument('--codec', choices=['mp3','flac','aac','he-aac'], default='mp3')
        command.add_argument('--flac', action='store_true', help='Request original lossless FLAC; reject any MP3 fallback')
        if name != 'url':
            command.add_argument('--out', type=Path)
    args = parser.parse_args()
    if args.command == 'login':
        if args.from_app:
            import_current_session(args.app, args.session, args.port)
            print('Current app session saved with Windows user encryption.')
            return
        else:
            token = os.environ.get('YANDEX_MUSIC_TOKEN') or getpass.getpass('Yandex Music OAuth token: ').strip()
        if not token:
            raise RuntimeError('Empty OAuth token')
        state = {**installed_config(args.app), 'token':token}
        save_session(state, args.session)
        print('Session saved with Windows user encryption.')
        return
    if args.flac:
        args.quality, args.codec = 'lossless', 'flac'
    state = import_current_session(args.app, args.session, int(os.environ.get('YM_APP_PORT', '9229')))
    tid, info, url = raw_source(args, state)
    if args.command == 'url':
        print(url)
        return
    if args.command == 'player':
        output = args.out or ROOT / f'track-{tid}-player.html'
        source = html.escape(url, quote=True)
        format_label = 'FLAC · без потерь' if info['codec'] in ('flac', 'flac-mp4') else html.escape(str(info['codec']))
        if info.get('bitrate'):
            format_label += f' · {info["bitrate"]} кбит/с'
        output.write_text(f'<!doctype html><html lang="ru"><meta charset="utf-8"><title>Трек {tid}</title><body style="font:18px system-ui;max-width:700px;margin:60px auto;padding:24px"><h1>Трек {tid}</h1><p>{format_label}</p><audio controls preload="metadata" src="{source}" style="width:100%"></audio><p>Источник получен из API Яндекс Музыки. Для новой ссылки повторно выполните команду player.</p></body></html>', encoding='utf-8')
        print(output.resolve())
        return
    extension = {'mp3':'mp3','flac':'flac','flac-mp4':'flac','aac':'aac','he-aac':'aac'}.get(info['codec'], 'audio')
    output = args.out or ROOT / f'track-{tid}.{extension}'
    print(json.dumps(download_audio(info, url, output), ensure_ascii=True))

if __name__ == '__main__':
    try:
        main()
    except HTTPError as error:
        print(f'Music/CDN request failed: HTTP {error.code}. Check the session and track access.', file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        print(f'{type(error).__name__}: {error}', file=sys.stderr)
        sys.exit(1)
