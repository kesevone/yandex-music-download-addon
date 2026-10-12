"""One-shot audio download for the runtime button; no HTTP listener."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import sys
import uuid
sys.dont_write_bytecode = True
# The Windows embeddable Python runtime uses an isolated ._pth; make our own
# sibling module available without enabling unrelated site packages.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from yandex_music import APP_ASAR, SESSION_PATH, import_current_session, get_source, track_metadata, download_audio


def downloads_directory():
    if os.name != 'nt':
        return Path.home() / 'Downloads'
    folder_id = ctypes.create_string_buffer(uuid.UUID('374de290-123f-4565-9164-39c4925e467b').bytes_le)
    path = ctypes.c_void_p()
    shell = ctypes.WinDLL('shell32')
    shell.SHGetKnownFolderPath.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
    shell.SHGetKnownFolderPath.restype = ctypes.c_long
    result = shell.SHGetKnownFolderPath(folder_id, 0, None, ctypes.byref(path))
    if result != 0:
        raise RuntimeError('Не удалось определить папку «Загрузки».')
    try:
        return Path(ctypes.wstring_at(path))
    finally:
        ctypes.windll.ole32.CoTaskMemFree(ctypes.c_void_p(path.value))


def filename(metadata, track):
    name = ', '.join(metadata.get('artists', [])) + ' - ' + metadata.get('title', 'Трек ' + track)
    if metadata.get('version'):
        name += ' (' + metadata['version'] + ')'
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', '_', name).strip(' .')[:140].rstrip(' .')
    if not name or re.match(r'(?i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)', name):
        name = 'track-' + track
    return name


def emit(value):
    print(json.dumps(value, ensure_ascii=True), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('track')
    parser.add_argument('--format', choices=['flac', 'mp3'], required=True)
    args = parser.parse_args()
    emit({'stage': 'source', 'message': 'Получаю ' + args.format.upper() + '…'})
    state = import_current_session(APP_ASAR, SESSION_PATH, int(os.environ.get('YM_APP_PORT', '9229')))
    _, info, url = get_source(args.track, state, 'lossless' if args.format == 'flac' else 'hq', args.format)
    metadata = track_metadata(args.track, state)
    emit({'stage': 'metadata', 'metadata': metadata})
    folder = downloads_directory() / 'Yandex Music'
    stem = filename(metadata, args.track)
    folder.mkdir(parents=True, exist_ok=True)
    emit({'stage': 'download', 'message': 'Скачиваю ' + args.format.upper() + '…'})
    for suffix in range(1, 1000):
        destination = folder / (stem + (f' ({suffix})' if suffix > 1 else '') + '.' + args.format)
        if destination.exists() or destination.with_name(destination.name + '.part').exists():
            continue
        try:
            result = download_audio(info, url, destination,
                                    progress=lambda status: emit({'stage': 'progress', **status}))
            emit({'stage': 'done', 'file': result['file'], 'bytes': result['bytes'], 'codec': result['codec']})
            return
        except FileExistsError:
            continue
    raise RuntimeError('Не удалось выбрать свободное имя файла.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        message = str(error)
        if 'Lossless FLAC is unavailable' in message:
            emit({'stage': 'error', 'code': 'flac_unavailable', 'message': 'Для этого трека FLAC недоступен. Можно скачать MP3.'})
        elif 'FFmpeg' in message:
            emit({'stage': 'error', 'message': 'Для сохранения FLAC нужен FFmpeg в PATH.'})
        else:
            emit({'stage': 'error', 'message': 'Скачать не удалось. Проверьте доступ к треку и авторизацию.'})
        sys.exit(1)
