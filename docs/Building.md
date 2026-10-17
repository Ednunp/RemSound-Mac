# Building RemSound for Mac

Use macOS 14 or later, Xcode with its command-line tools, and CMake 3.22 or later. The first build needs an internet connection to fetch the pinned dependencies. Apple Silicon and Intel binaries are built together.

From the source folder, run:

```sh
REMSOUND_WORK_ROOT="$PWD/.build-work" ./Build.sh "$PWD/.build-output"
```

The work folder holds dependency sources, compiler output and tests. The output folder contains the app, the three plugin formats, manuals and licences. A local build does not carry the public release's Developer ID signature or notarization ticket. Keep it separate from an installed copy you use for audio work.

`Build.sh` builds the native codecs, Swift app and updater, and JUCE-based AU, VST3 and CLAP plugins. It verifies the generated manual exports before building. Hardware-free tests run against the build's own temporary folders; checks needing visible windows or host interaction are reported separately.

The plugin project is `Plugin/CMakeLists.txt`. Dependency revisions and archive hashes are pinned there and in `Build.sh`. The corresponding-source download supplied with each release includes those dependency sources and their licences. To use them without fetching another copy, pass `FETCHCONTENT_SOURCE_DIR_JUCE` and `FETCHCONTENT_SOURCE_DIR_CLAP_JUCE` to CMake, pointing at the included dependency folders. The archive's build notes identify their exact revisions.

The app source retains the MIT licence. JUCE-linked plugin binaries in the public release are distributed under AGPLv3; see `Plugin/LICENSE-AGPL-3.0.txt` and `THIRD_PARTY_NOTICES.md`.

## Replacing the MP3 library

LAME is a separate dynamic library at `RemSound.app/Contents/Frameworks/libmp3lame.0.dylib`. Its unmodified source archive and full library licence are included in the app's `Contents/Resources/Licenses` folder. `Build.sh` contains the universal compiler and configuration flags.

You can rebuild the app from source with a modified, compatible LAME library. For a direct Swift build, set `REMSOUND_LAME_LIBRARY` to your library's absolute path. Keep the library's install name as `@rpath/libmp3lame.0.dylib` and include the architectures used by your app. Replacing a library invalidates the distributed app's signature, so sign your own local build afterward; it will not retain the publisher's notarization. The MIT app source and these instructions are supplied to permit modification and relinking.
