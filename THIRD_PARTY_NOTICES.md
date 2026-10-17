# Third-party notices

- RemSound 6.0 reference source: copyright 2026 Ed Pourtahmasbi; MIT, see `LICENSE` and the reference copy.
- JUCE 8.0.15: commit `91ad83ae34a81e0833b1a2b0866f54846370ae53`, https://github.com/juce-framework/JUCE. This release uses JUCE under AGPLv3; no commercial JUCE licence is asserted. The JUCE-based plugin binaries are distributed under AGPLv3, with complete corresponding source supplied alongside the release downloads. The app's original MIT notices remain in force. The full AGPLv3 text is `Plugin/LICENSE-AGPL-3.0.txt` in source and `Licenses/AGPL-3.0.txt` in the app's resources.
- clap-juce-extensions: commit `55525c9858d4b25687be7759a5e0f70eccef218e`, https://github.com/free-audio/clap-juce-extensions, MIT, with its pinned CLAP and CLAP helper submodules and their notices.
- Opus 1.6.1: https://opus-codec.org, BSD-style license in `Opus-COPYING.txt` in packages. Archive SHA-256: `6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1`. Built statically for macOS 14 and both supported architectures. Architecture-specific intrinsics are disabled in the initial universal build; performance must be measured before changing this choice.

The generated test audio and synthetic password fixtures contain no user recordings or credentials.

## FLAC lossless encoder

libFLAC 1.5.0, https://xiph.org/flac/, is linked statically for macOS 14, arm64 and x86_64. It supplies compression levels 0 through 8 independently of 16- or 24-bit recording depth. Archive SHA-256: `f2c1c76592a82ffff8413ba3c4a1299b6c7ab06c734dee03fd88630485c2b920`. Only the BSD-licensed C library is built; the C++ library, command-line programs, examples, Ogg support and multithreading are disabled. Its unmodified public headers and `COPYING.Xiph` are retained under `App/Sources/AudioSupport/vendor/FLAC`; binary distributions include that full notice as `Licenses/FLAC-COPYING.txt`, also inside the app's resources. `Build.sh` implements the pinned universal build. The app's recording wrapper is separate from libFLAC and does not modify its source.

## Apple system libarchive headers

Pinned Apple public headers at commit `5649597e7975dd1f8c24ab0176f131f47a1cdae0` from https://github.com/apple-oss-distributions/libarchive. Only the declarations are vendored; the updater links the macOS system library.

Copyright (c) 2003-2010 Tim Kientzle
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR(S) ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
IN NO EVENT SHALL THE AUTHOR(S) BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Copyright (c) 2003-2008 Tim Kientzle
Copyright (c) 2016 Martin Matuska
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR(S) ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
IN NO EVENT SHALL THE AUTHOR(S) BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## LAME MP3 encoder

LAME 4.0, https://lame.sourceforge.io/, is built as a separate, unmodified dynamic encoder library for macOS 14, arm64 and x86_64. Its decoder, frontend and analyzer hooks are disabled. LAME is licensed under the GNU Library General Public License, version 2; its complete COPYING and LICENSE are included in `Licenses/LAME-COPYING.txt` and `Licenses/LAME-LICENSE.txt`. The unmodified corresponding source archive is included as `Licenses/lame-4.0.tar.gz`, SHA-256 `3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb`. These files are also inside the app's resources. Build flags are in `Build.sh`; replacement instructions are in `docs/Building.md`. The app's own recording wrapper is separate from LAME and does not modify its source.

The six bundled `push talk on` and `push talk off` WAV cues are from Windows RemSound, copyright (c) 2026 Ed Pourtahmasbi, under the MIT License. The complete notice is `App/Resources/default sounds/PTT-LICENSE.txt` and is retained with the bundled sounds.
