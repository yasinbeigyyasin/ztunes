# Third-party notices

## Limusic

Spotless is a fork of **Limusic** by SimoHypers and contributors
(<https://github.com/SimoHypers/limusic>), licensed under the GNU General Public License v3.0 or
later. Spotless is distributed under the same licence ([LICENSE](LICENSE)). The original copyright
notices in the source files are retained. Changes made for Spotless are recorded in this
repository's git history.


## libmpv, FFmpeg and their libraries (macOS release bundle)

The macOS `Spotless.app` built by `scripts/release-mac.sh` bundles, in `Contents/Frameworks`, the
libmpv (mpv, GPL-2.0-or-later build), FFmpeg (built with `--enable-gpl`), Rubber Band (GPL-2.0+),
libass, libplacebo, LuaJIT and other libraries exactly as shipped in the `Contents/Frameworks` of
**IINA** 1.5.1 (<https://github.com/iina/iina>, GPL-3.0), signed by IINA's Developer ID and
re-signed for Spotless. Each library is under its own licence; the build and the provenance (DMG
hash, per-file SHA-256) are recorded in `Spotless.app/Contents/Resources/libmpv-SOURCE.txt`.
Corresponding sources: mpv <https://github.com/mpv-player/mpv>, FFmpeg <https://ffmpeg.org>,
IINA's library build scripts <https://github.com/iina/iina/tree/develop/other>, and the upstream
project of each library named there.


## pypinyin phrase data (Mandarin lyric romanization)

`src-tauri/src/romanize_zh.tsv` is derived from the phrase and character data of **pypinyin**
0.55 (<https://github.com/mozillazg/python-pinyin>, which bundles mozillazg/phrase-pinyin-data and
pinyin-data), under the MIT License:

```
The MIT License (MIT)

Copyright (c) 2016 mozillazg, 闲耘 <hotoo.cn@gmail.com>

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```
