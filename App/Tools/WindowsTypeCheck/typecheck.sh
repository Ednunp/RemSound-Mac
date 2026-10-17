#!/bin/sh
# Type-check the whole Mac app - RemSoundJam, RemSoundCore, RemSoundApp, RemSoundUpdater and the app's own tests - on
# WINDOWS, against the stand-in Apple modules in stubs/. Nothing is linked or run: it finds the compile errors a Mac
# would find (a missing member, a wrong argument, a public type used from another module without a public init ...)
# without a Mac. See README.md in this folder. Run it from Git Bash:  sh App/Tools/WindowsTypeCheck/typecheck.sh
#
# Needs the Swift toolchain for Windows (swift.org) and Visual Studio's C++ tools. It finds both itself; set
# SWIFT_HOME (default %LOCALAPPDATA%\Programs\Swift), SWIFT_VERSION (default the newest installed) or VCVARS (the full
# path of vcvars64.bat) if it guesses wrong. It prints one line per module; 0 errors everywhere is a pass.
#
# Its work goes OUTSIDE the source (AGENTS.md): into TYPECHECK_OUT if set, else the Windows scratch folder
# D:\projects\Codex\temp\remsound-mac\typecheck-out when that folder exists, else %TEMP%\remsound-mac-typecheck.
# Each module's full compiler output is <that folder>\<module>.log.
cd "$(dirname "$0")" || exit 1
HERE=$(pwd -W 2>/dev/null || pwd)
APP=$(cd ../.. && (pwd -W 2>/dev/null || pwd))
if [ -z "$TYPECHECK_OUT" ]; then
  if [ -d "/d/projects/Codex/temp/remsound-mac" ]; then TYPECHECK_OUT="D:/projects/Codex/temp/remsound-mac/typecheck-out"
  else TYPECHECK_OUT="$(cygpath -m "$TEMP" 2>/dev/null || echo "$TEMP")/remsound-mac-typecheck"; fi
fi
OUT=$TYPECHECK_OUT

SWIFT_HOME=${SWIFT_HOME:-"$LOCALAPPDATA\\Programs\\Swift"}
SWIFT_HOME_UNIX=$(cygpath -u "$SWIFT_HOME" 2>/dev/null || echo "$SWIFT_HOME")
if [ -z "$SWIFT_VERSION" ]; then
  SWIFT_VERSION=$(ls "$SWIFT_HOME_UNIX/Platforms" 2>/dev/null | sort -V | tail -1)
fi
TOOLCHAIN=$(ls -d "$SWIFT_HOME_UNIX/Toolchains/$SWIFT_VERSION"* 2>/dev/null | head -1)
if [ -z "$SWIFT_VERSION" ] || [ -z "$TOOLCHAIN" ]; then
  echo "No Swift toolchain found under $SWIFT_HOME - install Swift for Windows or set SWIFT_HOME / SWIFT_VERSION."; exit 1
fi
TOOLCHAIN=$(cygpath -w "$TOOLCHAIN")
if [ -z "$VCVARS" ]; then
  VSWHERE="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
  VS=$("$VSWHERE" -latest -products '*' -property installationPath 2>/dev/null | tr -d '\r')
  VCVARS="$VS\\VC\\Auxiliary\\Build\\vcvars64.bat"
fi
PLATFORM="$SWIFT_HOME\\Platforms\\$SWIFT_VERSION\\Windows.platform"
XCTEST=$(ls -d "$SWIFT_HOME_UNIX/Platforms/$SWIFT_VERSION/Windows.platform/Developer/Library/XCTest-"* 2>/dev/null | head -1)
XCTEST=$(cygpath -w "$XCTEST/usr/lib/swift/windows" 2>/dev/null)

rm -rf "$OUT"; mkdir -p "$OUT/AudioSupport" "$OUT/UpdateSupport" "$OUT/app-src"
# The compiler, inside Visual Studio's x64 environment, run on a response file.
cat > "$OUT/swc.cmd" <<EOF
@echo off
call "$VCVARS" >nul
set "PATH=$TOOLCHAIN\\usr\\bin;$SWIFT_HOME\\Runtimes\\$SWIFT_VERSION\\usr\\bin;%PATH%"
set "SDKROOT=$PLATFORM\\Developer\\SDKs\\Windows.sdk\\"
cd /d "%~1"
swiftc @%2
EOF
SWC=$(cygpath -w "$OUT/swc.cmd" 2>/dev/null || echo "$OUT/swc.cmd")
# The app's C helper, as a Clang module (SwiftPM makes this on a Mac).
cat > "$OUT/AudioSupport/module.modulemap" <<EOF
module AudioSupport {
    header "$APP/Sources/AudioSupport/include/AudioSupport.h"
    export *
}
EOF
# Native updater declarations only; the Windows harness never links or runs extraction.
cat > "$OUT/UpdateSupport/module.modulemap" <<EOF
module UpdateSupport {
    header "$APP/Sources/UpdateSupport/include/UpdateSupport.h"
    export *
}
EOF
# The app's sources are checked from copies, each line where it was, with a few Windows-only adjustments:
# - No Objective-C runtime on Windows (RemSoundApp only): drop @objc and turn #selector(m) into _objcSelector(m) - which
#   still checks that the method m exists (see stubs/AppKit.swift).
# - Windows' Swift overlay for its C runtime declares S_IFMT, S_IFDIR, S_IFREG and S_IFLNK itself, as Int32; they are
#   qualified as Darwin's (mode_t, as on a Mac) so they aren't ambiguous.
# - Windows' Foundation marks FileHandle.fileDescriptor unavailable; it becomes _macFileDescriptor (MacFoundationExtras).
prep() { # source folder, copy folder, extra sed arguments...
  src=$1; dst=$2; shift 2; mkdir -p "$dst"
  for f in "$src"/*.swift; do
    sed -e 's/Darwin\.S_IF/S_IF/g' -e 's/\bS_IF\(MT\|DIR\|REG\|LNK\)\b/Darwin.S_IF\1/g' -e 's/\.fileDescriptor\b/._macFileDescriptor/g' "$@" \
      "$f" > "$dst/$(basename "$f")"
  done
}
prep "$APP/Packages/RemSoundRuntime/Sources/RemSoundRuntime" "$OUT/runtime-src"
prep "$APP/Sources/RemSoundCore" "$OUT/core-src"
prep "$APP/Sources/RemSoundApp" "$OUT/app-src" -e 's/@objc //g' -e 's/#selector(/_objcSelector(/g'
prep "$APP/Sources/RemSoundUpdater" "$OUT/updater-src"
prep "$APP/Tests/RemSoundCoreTests" "$OUT/coretests-src"
prep "$APP/Tests/RemSoundAppTests" "$OUT/apptests-src" -e 's/@objc //g' -e 's/#selector(/_objcSelector(/g'

FAILED=0
IMPLICIT=""  # 1 once the Mac-Foundation extras are built: every app module then imports them
EXTRA=""      # more compiler arguments, one per line
TOPLEVEL=""   # 1 for a target with a main.swift
module() { # name, sources...
  name=$1; shift
  {
    echo "-emit-module"; echo "-wmo"; echo "-continue-building-after-errors"; echo "-module-name"; echo "$name"
    [ -z "$TOPLEVEL" ] && echo "-parse-as-library"
    # Keep the Windows C runtime from declaring its POSIX-named aliases (stat, close, read, S_IFDIR, EWOULDBLOCK ...): the
    # Darwin stand-in declares those the way a Mac does, and both at once made every use ambiguous.
    # On a Mac, Foundation brings Darwin and Core Foundation with it; here the app's modules import their stand-ins, and the
    # Mac-only Foundation extras, implicitly.
    # A debug build, as `swift build` and `swift test` make one (code under #if DEBUG is checked too).
    [ -n "$IMPLICIT" ] && { echo "-D"; echo "DEBUG"; }
    [ -n "$IMPLICIT" ] && for m in Darwin CoreFoundation MacFoundationExtras; do echo "-Xfrontend"; echo "-import-module"; echo "-Xfrontend"; echo "$m"; done
    echo "-Xcc"; echo "-D_CRT_DECLARE_NONSTDC_NAMES=0"; echo "-Xcc"; echo "-D_CRT_NO_POSIX_ERROR_CODES"; echo "-Xcc"; echo "-Doff_t=_off_t"   # Dispatch's C headers still need off_t
    # On a Mac URLSession and XMLParser are in Foundation; on Windows they live in FoundationNetworking and FoundationXML.
    echo "-Xfrontend"; echo "-import-module"; echo "-Xfrontend"; echo "FoundationNetworking"
    echo "-Xfrontend"; echo "-import-module"; echo "-Xfrontend"; echo "FoundationXML"
    echo "-I"; echo "$OUT"; echo "-I"; echo "$OUT/AudioSupport"; echo "-I"; echo "$OUT/UpdateSupport"; echo "-I"; echo "stubs/CoreAudioC"
    [ -n "$EXTRA" ] && printf '%s\n' "$EXTRA"
    echo "-o"; echo "$OUT/$name.swiftmodule"
    for f in "$@"; do echo "$f"; done
  } > "$OUT/$name.rsp"
  cmd //c "$SWC" "$HERE" "$OUT/$name.rsp" > "$OUT/$name.log" 2>&1
  errors=$(grep -cE "^[^ |].*:[0-9]+:[0-9]+: error:" "$OUT/$name.log")
  [ "$errors" = "0" ] && grep -q "error:" "$OUT/$name.log" && errors="compiler failed -"
  echo "$name: $errors errors"
  [ "$errors" = "0" ] || FAILED=1
}

# The stand-ins for Apple's modules.
module CoreAudio stubs/CoreAudio.swift
module CoreFoundation stubs/CoreFoundation.swift
module AudioToolbox stubs/AudioToolbox.swift
module AVFoundation stubs/AVFoundation.swift
module CryptoKit stubs/CryptoKit.swift
module Security stubs/Security.swift
module Darwin stubs/Darwin.swift
module UniformTypeIdentifiers stubs/UniformTypeIdentifiers.swift
module AppKit stubs/AppKit.swift
module Carbon stubs/Carbon.swift
module SwiftUI stubs/SwiftUI.swift
module ServiceManagement stubs/ServiceManagement.swift
module SystemConfiguration stubs/SystemConfiguration.swift
module Network stubs/Network.swift
module dnssd stubs/dnssd.swift
module CommonCrypto stubs/CommonCrypto.swift
module ApplicationServices stubs/ApplicationServices.swift
module MacFoundationExtras stubs/MacFoundationExtras.swift
IMPLICIT=1
# The Mac app, in build order. The libraries allow @testable, as `swift test` builds them.
EXTRA="-enable-testing"
module RemSoundJam "$APP"/Packages/RemSoundJam/Sources/RemSoundJam/*.swift
module RemSoundSim "$APP"/Packages/RemSoundJam/Sources/RemSoundSim/*.swift
# RemSoundRuntime's file-identity code reads Darwin's stat layout (st_mtimespec, 64-bit st_size), which Windows' C
# runtime lays out differently; its module is emitted even with those errors so everything after it is still checked.
# Its own errors are listed in RemSoundRuntime.log - only NEW ones there matter (RUNTIME_KNOWN_ERRORS is the baseline).
EXTRA="-enable-testing
-Xfrontend
-experimental-allow-module-with-compiler-errors"
module RemSoundRuntime "$OUT"/runtime-src/*.swift
EXTRA="-enable-testing"
module RemSoundCore "$OUT"/core-src/*.swift
EXTRA="-enable-testing"
module RemSoundApp "$OUT"/app-src/*.swift
EXTRA=""
TOPLEVEL=1
module RemSoundUpdater "$OUT"/updater-src/*.swift
TOPLEVEL=""
EXTRA="-I
$XCTEST"
module RemSoundCoreTests "$OUT"/coretests-src/*.swift TestBundle.swift
module RemSoundAppTests "$OUT"/apptests-src/*.swift TestBundle.swift

if [ $FAILED = 0 ]; then echo "PASS: the whole Mac app type-checks."
else echo "FAIL: each module's compiler output is in $OUT"; fi
exit $FAILED
