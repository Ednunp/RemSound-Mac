#!/bin/bash
set -euo pipefail
source_root=$(cd "$(dirname "$0")" && pwd)
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$source_root/App/Info.plist")
output=${1:?Usage: Build.sh /absolute/output/folder}
mkdir -p "$output"
output=$(cd "$output" && pwd)
work=${REMSOUND_WORK_ROOT:-"$HOME/Projects/Codex/Temp/remsound-mac"}
mkdir -p "$work"
work=$(cd "$work" && pwd)
case "$work/" in "$source_root/"*) echo "Build work must be outside the source repository." >&2; exit 2;; esac
cmake_bin=${CMAKE_COMMAND:-$(command -v cmake || true)}
if [[ -z "$cmake_bin" && -x /opt/homebrew/bin/cmake ]]; then cmake_bin=/opt/homebrew/bin/cmake; fi
[[ -x "$cmake_bin" ]] || { echo "CMake 3.22 or newer is required." >&2; exit 2; }
exec > >(tee "$work/Build.log") 2>&1
export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=Never
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
export TMPDIR="$work/tmp"
export REMSOUND_TEST_ROOT="$work/tmp"
mkdir -p "$TMPDIR"
xcrun swiftc "$source_root/App/Packages/RemSoundJam/Sources/RemSoundJam/ManualHTML.swift" \
    "$source_root/App/Tools/RenderManual.swift" -o "$work/RenderManual"
"$work/RenderManual" "$source_root/README.md" "$source_root/Manual.html" "$source_root/Manual.txt" --check
archive="$work/opus.tar.gz"
if [[ ! -f "$archive" ]]; then curl -L --fail --max-time 120 https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz -o "$archive"; fi
echo "6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1  $archive" | shasum -a 256 -c -
if [[ ! -d "$work/opus-1.6.1" ]]; then tar -xzf "$archive" -C "$work"; fi
"$cmake_bin" -S "$work/opus-1.6.1" -B "$work/opus-build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 '-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64' \
    -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_DISABLE_INTRINSICS=ON -DOPUS_CUSTOM_MODES=ON \
    "-DCMAKE_C_FLAGS=-ffile-prefix-map=$work/opus-1.6.1=opus-1.6.1"
"$cmake_bin" --build "$work/opus-build" -j 4
export REMSOUND_OPUS_LIBRARY="$work/opus-build/libopus.a"
# BSD libFLAC supplies the real 0...8 compression presets, independently of PCM depth.
flac_archive="$work/flac-1.5.0.tar.xz"
if [[ ! -f "$flac_archive" ]]; then
    curl -L --fail --max-time 120 https://downloads.xiph.org/releases/flac/flac-1.5.0.tar.xz -o "$flac_archive"
fi
echo "f2c1c76592a82ffff8413ba3c4a1299b6c7ab06c734dee03fd88630485c2b920  $flac_archive" | shasum -a 256 -c -
if [[ ! -d "$work/flac-1.5.0" ]]; then tar -xJf "$flac_archive" -C "$work"; fi
"$cmake_bin" -S "$work/flac-1.5.0" -B "$work/flac-build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 '-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64' \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_CXXLIBS=OFF -DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTING=OFF -DBUILD_DOCS=OFF -DWITH_OGG=OFF -DENABLE_MULTITHREADING=OFF -DWITH_ASM=OFF \
    "-DCMAKE_C_FLAGS=-ffile-prefix-map=$work/flac-1.5.0=flac-1.5.0"
"$cmake_bin" --build "$work/flac-build" --target FLAC -j 4
export REMSOUND_FLAC_LIBRARY="$work/flac-build/src/libFLAC/libFLAC.a"
# The encoder is a separate, unmodified LGPL library; the decoder/frontend are not built.
lame_archive="$work/lame-4.0.tar.gz"
if [[ ! -f "$lame_archive" ]]; then
    curl -L --fail --max-time 120 https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz -o "$lame_archive"
fi
echo "3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb  $lame_archive" | shasum -a 256 -c -
if [[ ! -d "$work/lame-4.0" ]]; then tar -xzf "$lame_archive" -C "$work"; fi
sdk=$(xcrun --sdk macosx --show-sdk-path)
pkg_config=${PKG_CONFIG:-$(command -v pkg-config || true)}
if [[ -z "$pkg_config" && -x /opt/homebrew/bin/pkg-config ]]; then pkg_config=/opt/homebrew/bin/pkg-config; fi
[[ -x "$pkg_config" ]] || { echo "pkg-config is required to configure LAME." >&2; exit 2; }
export PKG_CONFIG="$pkg_config"
for architecture in arm64 x86_64; do
    host="$architecture-apple-darwin"
    [[ "$architecture" != arm64 ]] || host=aarch64-apple-darwin
    mkdir -p "$work/lame-$architecture"
    (cd "$work/lame-$architecture"
        CC="$(xcrun -f clang)" \
        CFLAGS="-O2 -arch $architecture -isysroot $sdk -mmacosx-version-min=14.0 -ffile-prefix-map=$work=lame-build" \
        LDFLAGS="-arch $architecture -isysroot $sdk -mmacosx-version-min=14.0" \
        "$work/lame-4.0/configure" --host="$host" --disable-decoder --disable-frontend \
            --disable-analyzer-hooks --enable-shared --disable-static --disable-dependency-tracking
        make -j4)
done
mkdir -p "$work/lame-universal"
lipo -create "$work/lame-arm64/libmp3lame/.libs/libmp3lame.0.dylib" \
    "$work/lame-x86_64/libmp3lame/.libs/libmp3lame.0.dylib" -output "$work/lame-universal/libmp3lame.0.dylib"
install_name_tool -id @rpath/libmp3lame.0.dylib "$work/lame-universal/libmp3lame.0.dylib"
xcrun strip -S "$work/lame-universal/libmp3lame.0.dylib"
export REMSOUND_LAME_LIBRARY="$work/lame-universal/libmp3lame.0.dylib"

# Keep local control sockets below macOS's Unix-domain path limit, independently of the build-folder name.
test_parent="$HOME/Projects/Codex/Temp/remsound-mac"
mkdir -p "$test_parent"
export REMSOUND_TEST_ROOT=$(mktemp -d "$test_parent/tXXXX")
chmod 700 "$REMSOUND_TEST_ROOT"
echo "Isolated test fixtures: $REMSOUND_TEST_ROOT"
python3 "$source_root/App/Tools/CreatePluginPayloadFixture.py" "$REMSOUND_TEST_ROOT"
python3 - "$source_root" "$REMSOUND_TEST_ROOT" <<'PY'
from pathlib import Path
import shutil
import sys
source, root = map(Path, sys.argv[1:])
snapshot = root / 'dialog-audit-source'
snapshot.mkdir(mode=0o700)
for name in ['App/Sources', 'App/Tests', 'App/Packages', 'Plugin/Source', 'Plugin/Tests']:
    for path in (source / name).rglob('*'):
        relative = path.relative_to(source)
        if any(part in {'.build', 'build', '.git'} for part in relative.parts):
            continue
        if path.suffix not in {'.swift', '.c', '.h', '.cpp', '.mm'} or not path.is_file():
            continue
        if path.is_symlink():
            raise ValueError('source snapshot refuses symbolic links')
        target = snapshot / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
PY
export REMSOUND_TEST_FUNNEL_FIXTURES="$REMSOUND_TEST_ROOT/owned-process"
mkdir -m 700 "$REMSOUND_TEST_FUNNEL_FIXTURES"
xcrun clang -O2 "$source_root/App/Tests/Fixtures/WebFunnelProcessFixture.c" -o "$REMSOUND_TEST_FUNNEL_FIXTURES/normal"
codesign --force --sign - "$REMSOUND_TEST_FUNNEL_FIXTURES/normal"
for name in silent deadline inherited nonzero stdout stderr halfclosed approval-needed; do
    cp "$REMSOUND_TEST_FUNNEL_FIXTURES/normal" "$REMSOUND_TEST_FUNNEL_FIXTURES/$name"
done

# Playing together through a server: the shared package's own tests (the real-relay test runs when REMSOUND_RELAY_PY names
# Ed's server/remsound-relay.py; see docs/Playing-through-a-server.md).
(cd "$source_root/App/Packages/RemSoundJam" && swift test --scratch-path "$work/jam-test")
(cd "$source_root/App/Packages/RemSoundRuntime" && swift test --scratch-path "$work/runtime-test")
cd "$source_root/App"
# SwiftPM's test loader searches beside its built products, independently of the app bundle.
test_bin=$(swift build --scratch-path "$work/swift-test" --show-bin-path)
mkdir -p "$test_bin"
cp "$REMSOUND_LAME_LIBRARY" "$test_bin/libmp3lame.0.dylib"
swift test --scratch-path "$work/swift-test"
swift package --scratch-path "$work/swift-release" clean
swift build -c release --arch arm64 --arch x86_64 --scratch-path "$work/swift-release"
bin=$(swift build -c release --arch arm64 --arch x86_64 --scratch-path "$work/swift-release" --show-bin-path)
mkdir -p "$bin/../Frameworks"
cp "$REMSOUND_LAME_LIBRARY" "$bin/../Frameworks/libmp3lame.0.dylib"
/usr/bin/python3 "$source_root/App/Tools/Tests/AccessibilityCheckTests.py" "$source_root/App/Tools/CheckAccessibility.sh"
bash "$source_root/App/Tools/CheckAccessibility.sh" "$source_root" "$bin" "$work"
"$cmake_bin" -S "$source_root/Plugin" -B "$work/plugin" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 '-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64'
"$cmake_bin" --build "$work/plugin" -j 4
"$(dirname "$cmake_bin")/ctest" --test-dir "$work/plugin" --output-on-failure
stage_root=$(mktemp -d "$work/package.XXXXXX")
stage="$stage_root/RemSound-Mac-$version-parity-preview"
mkdir -p "$stage/RemSound.app/Contents/Frameworks" "$stage/RemSound.app/Contents/MacOS" "$stage/RemSound.app/Contents/Resources/docs" "$stage/Plugins" "$stage/Licenses" "$stage/docs"
cp "$REMSOUND_LAME_LIBRARY" "$stage/RemSound.app/Contents/Frameworks/libmp3lame.0.dylib"
cp "$bin/RemSound" "$stage/RemSound.app/Contents/MacOS/RemSound"
xcrun strip -S "$stage/RemSound.app/Contents/MacOS/RemSound"
cp "$bin/RemSoundUpdater" "$stage/RemSound.app/Contents/MacOS/RemSoundUpdater"
xcrun strip -S "$stage/RemSound.app/Contents/MacOS/RemSoundUpdater"
cp "$source_root/App/Info.plist" "$stage/RemSound.app/Contents/Info.plist"
ditto "$source_root/App/Resources/default sounds" "$stage/RemSound.app/Contents/Resources/default sounds"
# The packaged Core loader requires its own exact browser page, with no build-tree fallback.
cp "$source_root/App/Sources/RemSoundCore/Resources/web-listener.html" "$stage/RemSound.app/Contents/Resources/web-listener.html"
cp "$source_root/README.md" "$stage/RemSound.app/Contents/Resources/README.md"
cp "$source_root/Manual.html" "$stage/RemSound.app/Contents/Resources/Manual.html"
cp "$source_root/LICENSE" "$source_root/THIRD_PARTY_NOTICES.md" "$stage/RemSound.app/Contents/Resources/"
cp "$source_root/README.md" "$source_root/LICENSE" "$source_root/THIRD_PARTY_NOTICES.md" "$stage/"
cp "$source_root/Manual.html" "$source_root/Manual.txt" "$stage/"
cp "$source_root/docs/Architecture.md" "$source_root/docs/Building.md" "$stage/docs/"
cp "$source_root/docs/Architecture.md" "$source_root/docs/Building.md" "$stage/RemSound.app/Contents/Resources/docs/"
cp "$work/opus-1.6.1/COPYING" "$stage/Licenses/Opus-COPYING.txt"
cp "$work/flac-1.5.0/COPYING.Xiph" "$stage/Licenses/FLAC-COPYING.txt"
cp "$work/lame-4.0/COPYING" "$stage/Licenses/LAME-COPYING.txt"
cp "$work/lame-4.0/LICENSE" "$stage/Licenses/LAME-LICENSE.txt"
cp "$lame_archive" "$stage/Licenses/lame-4.0.tar.gz"
cp "$work/plugin/_deps/juce-src/LICENSE.md" "$stage/Licenses/JUCE-LICENSE.md"
cp "$source_root/Plugin/LICENSE-AGPL-3.0.txt" "$stage/Licenses/AGPL-3.0.txt"
cp "$work/plugin/_deps/clap_juce-src/LICENSE.md" "$stage/Licenses/CLAP-JUCE-LICENSE.md"
find "$work/plugin/_deps/clap_juce-src/clap-libs" -maxdepth 3 -name LICENSE -exec sh -c 'cp "$1" "$2/$(basename "$(dirname "$1")")-LICENSE.txt"' sh {} "$stage/Licenses" \;
# Release packaging retains the app bundle, so its resources must contain all dependency notices.
ditto "$stage/Licenses" "$stage/RemSound.app/Contents/Resources/Licenses"
for format in AU VST3 CLAP; do
    mkdir -p "$stage/Plugins/$format"
    ditto "$work/plugin/RemSoundPlugin_artefacts/Release/$format" "$stage/Plugins/$format"
done
host_runtime="$work/plugin/host-runtime/Release/libRemSoundPluginHost-v1.dylib"
[[ -f "$host_runtime" ]] || { echo "Shared plugin host runtime missing." >&2; exit 2; }
for bundle in "$stage/Plugins/AU/RemSound.component" "$stage/Plugins/VST3/RemSound.vst3" "$stage/Plugins/CLAP/RemSound.clap"; do
    mkdir -p "$bundle/Contents/Frameworks"
    cp "$host_runtime" "$bundle/Contents/Frameworks/libRemSoundPluginHost-v1.dylib"
    install_name_tool -delete_rpath "$work/plugin/host-runtime/Release" \
        -add_rpath '@loader_path/../Frameworks' "$bundle/Contents/MacOS/RemSound"
    codesign --force --sign - "$bundle/Contents/Frameworks/libRemSoundPluginHost-v1.dylib"
    lipo -verify_arch arm64 "$bundle/Contents/Frameworks/libRemSoundPluginHost-v1.dylib"
    lipo -verify_arch x86_64 "$bundle/Contents/Frameworks/libRemSoundPluginHost-v1.dylib"
done
for bundle in "$stage/Plugins/AU/RemSound.component" "$stage/Plugins/VST3/RemSound.vst3" "$stage/Plugins/CLAP/RemSound.clap" "$stage/RemSound.app"; do
    if [[ "$bundle" == *.app ]]; then
        codesign --force --sign - "$bundle/Contents/Frameworks/libmp3lame.0.dylib"
        codesign --force --sign - "$bundle/Contents/MacOS/RemSoundUpdater"
    fi
    if [[ "$bundle" == *.app ]]; then
        python3 "$source_root/App/Tools/EmbedPluginPayload.py" "$bundle" "$stage/Plugins"
        codesign --force --sign - --entitlements "$source_root/App/RemSound.entitlements" "$bundle"
    else
        codesign --force --sign - "$bundle"
    fi
    codesign --verify --deep --strict "$bundle"
    architectures=" $(lipo "$bundle/Contents/MacOS/RemSound" -archs) "
    [[ "$architectures" == *" arm64 "* && "$architectures" == *" x86_64 "* ]] || { echo "Missing universal architecture: $bundle" >&2; exit 2; }
done
destination="$output/RemSound-Mac-$version-parity-preview.zip"
[[ ! -e "$destination" ]] || { echo "Output already exists: $destination. Choose a fresh output folder." >&2; exit 2; }
ditto -c -k --keepParent "$stage" "$destination"
shasum -a 256 "$destination"
echo "Built $destination. Development signature only; not notarized."
echo "Logs and build work: $work"
