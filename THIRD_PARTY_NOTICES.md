# Third-party components

The addon's own code is covered by [MIT](LICENSE). External runtimes retain
their upstream licenses and are downloaded separately when needed. Their
pinned versions, download URLs and SHA256 checksums are listed in
[installer/dependencies.json](https://github.com/kesevone/yandex-music-download-addon/blob/main/installer/dependencies.json).

| Component | License and source |
|---|---|
| Node.js | MIT and bundled component notices; [upstream LICENSE](https://github.com/nodejs/node/blob/v22.23.3/LICENSE). The portable install retains `LICENSE` and `README.md`. |
| CPython | Python Software Foundation License and bundled component notices; [upstream licenses](https://docs.python.org/3.13/license.html). The embeddable archive is extracted with its license files. |
| FFmpeg essentials, Gyan build | GPLv3 and bundled library notices; [build information](https://www.gyan.dev/ffmpeg/builds/), [FFmpeg source](https://github.com/FFmpeg/FFmpeg/tree/n8.1.2). The portable install retains the build's `LICENSE` and `README.txt`, including its build configuration and library information. |

The installer contains addon source and notices, rather than runtime binaries.
An existing system runtime is used when compatible. Yandex Music binaries,
application assets and audio are not distributed with this project.
