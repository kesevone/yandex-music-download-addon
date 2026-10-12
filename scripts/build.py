"""Build a self-contained Windows setup; only explicitly allowlisted source files enter it."""
from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE_FILES = (
    "ym-button-helper.mjs", "ym-download-button.js", "ym-download-queue.js",
    "ym-active-track.js", "yandex_music.py", "yandex_music_button.py",
    "ym-session-export.mjs", "launch_music_installed.ps1", "launch_music_hidden.vbs",
    "uninstall_music_autoload.ps1", "ym-shortcuts.ps1",
)
PACKAGE_FILES = tuple("src/" + name for name in SOURCE_FILES) + (
    "installer/install.ps1", "installer/dependencies.json", "LICENSE", "THIRD_PARTY_NOTICES.md",
)


def package(root: Path = ROOT) -> bytes:
    files = {name: (root / name).read_bytes() for name in PACKAGE_FILES}
    manifest = {
        "format": 1,
        "files": [{"path": name, "sha256": hashlib.sha256(data).hexdigest()}
                  for name, data in sorted(files.items())],
    }
    files["package.json"] = (json.dumps(manifest, ensure_ascii=True, sort_keys=True,
                                       separators=(",", ":")) + "\n").encode()
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 0
            info.external_attr = 0
            archive.writestr(info, data, compresslevel=9)
    return stream.getvalue()


def build(destination: Path, root: Path = ROOT) -> dict:
    payload = package(root)
    payload_hash = hashlib.sha256(payload).hexdigest()
    names = tuple(sorted((*PACKAGE_FILES, "package.json")))
    bootstrap = (root / "installer/bootstrap.ps1").read_text(encoding="utf-8-sig")
    bootstrap = bootstrap.replace("@@PAYLOAD_SHA256@@", payload_hash)
    bootstrap = bootstrap.replace("@@ALLOWED_NAMES@@", ", ".join("'" + name + "'" for name in names))
    command = (
        '@echo off\nsetlocal DisableDelayedExpansion\n'
        'set "YM_ADDON_SETUP_FILE=%~f0"\n'
        'set "YM_ADDON_SETUP_ACTION=%~1"\n'
        'set "YM_ADDON_SETUP_OUTPUT=%~2"\n'
        'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command '
        '"$ErrorActionPreference=\'Stop\';try {$s=[IO.File]::ReadAllText($env:YM_ADDON_SETUP_FILE);'
        '$m=[regex]::Match($s,\'(?ms)^:YM_BOOTSTRAP_BEGIN\\r?\\n(.*?)^:YM_BOOTSTRAP_END\');'
        'if(-not $m.Success){throw \'Setup bootstrap is missing.\'};'
        '& ([scriptblock]::Create($m.Groups[1].Value))}catch{Write-Host $_.Exception.Message -ForegroundColor Red;exit 1}"\n'
        'set "YM_ADDON_SETUP_EXIT=%ERRORLEVEL%"\n'
        'if "%~1"=="" pause\n'
        'exit /b %YM_ADDON_SETUP_EXIT%\n'
        ':YM_BOOTSTRAP_BEGIN\n'
    )
    encoded = base64.b64encode(payload).decode("ascii")
    content = command + bootstrap.rstrip() + '\n:YM_BOOTSTRAP_END\n:YM_PAYLOAD_BEGIN\n'
    content += '\n'.join(encoded[pos:pos + 120] for pos in range(0, len(encoded), 120))
    content += '\n:YM_PAYLOAD_END\n'
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(content.replace('\r\n', '\n').replace('\n', '\r\n').encode("utf-8"))
    result = {"file": destination.name, "bytes": destination.stat().st_size,
              "sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
              "payloadSha256": payload_hash, "packageFiles": list(names)}
    destination.with_suffix(".cmd.sha256").write_text(
        result["sha256"] + "  " + destination.name + "\n", encoding="ascii")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/YandexMusicAddon-Setup.cmd")
    options = parser.parse_args()
    print(json.dumps(build(options.output), indent=2))


if __name__ == "__main__":
    main()
