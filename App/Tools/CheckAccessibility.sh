#!/bin/bash
set -euo pipefail
if [[ "${REMSOUND_ALLOW_VISIBLE_UI_TESTS:-}" != 1 ]]; then
    echo "SKIP: native app and plugin UI checks are unverified. Agree a visible test window before setting REMSOUND_ALLOW_VISIBLE_UI_TESTS=1."
    exit 0
fi
source_root=${1:?Usage: CheckAccessibility.sh /source/root /built/bin /external/work}
bin=${2:?Missing built binary directory}
work=${3:?Missing external work directory}
for path in "$source_root" "$bin" "$work"; do
    [[ "$path" == /* && -d "$path" ]] || { echo "Expected an existing absolute directory: $path" >&2; exit 2; }
done
source_root=$(cd "$source_root" && pwd -P)
bin=$(cd "$bin" && pwd -P)
work=$(cd "$work" && pwd -P)
case "$work/" in "$source_root/"*) echo "Accessibility work must be outside the source repository." >&2; exit 2;; esac
fixture_root=$(mktemp -d "$work/accessibility.XXXXXX")
cleanup() {
    case "$fixture_root" in
        "$work"/accessibility.*)
            [[ ! -L "$fixture_root" ]] || return 2
            rm -rf "$fixture_root"
            ;;
        *) return 2;;
    esac
}
trap cleanup EXIT
app="$fixture_root/RemSound-Accessibility.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
cp "$bin/RemSound" "$app/Contents/MacOS/RemSound"
cp "$bin/../Frameworks/libmp3lame.0.dylib" "$app/Contents/Frameworks/"
cp "$source_root/App/Info.plist" "$app/Contents/Info.plist"
fixture_id="org.remsound.mac.accessibility-test.$(uuidgen | tr '[:upper:]' '[:lower:]')"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $fixture_id" "$app/Contents/Info.plist"
cp "$source_root/README.md" "$app/Contents/Resources/"
cp "$source_root/Manual.html" "$app/Contents/Resources/"
ditto "$source_root/App/Resources/default sounds" "$app/Contents/Resources/default sounds"
ditto "$source_root/docs" "$app/Contents/Resources/docs"
codesign --force --sign - "$app/Contents/Frameworks/libmp3lame.0.dylib"
codesign --force --sign - --entitlements "$source_root/App/RemSound.entitlements" "$app"
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/RemSound" --check-accessibility --silent --config-dir "$fixture_root/config"
