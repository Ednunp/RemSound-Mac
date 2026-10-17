# Type-checking the Mac app on Windows

Ed's machine has no Mac. This folder lets it compile-check the whole Mac app anyway. That covers RemSoundJam, RemSoundCore, RemSoundApp, RemSoundUpdater and the app's own tests (App/Tests). It checks them against stand-ins for the Apple frameworks the app uses. Nothing is linked and nothing runs. The check finds the errors a Mac compiler would find, such as a misspelt member, a wrong argument label, a type mismatch, or a public type used from another module without a public init. It cannot find anything that happens at run time.

Run it from Git Bash, from the repository root:

    sh App/Tools/WindowsTypeCheck/typecheck.sh

It prints one line per module, then PASS or FAIL. Its work folder is recreated on every run, and each module's full compiler output is `<module>.log` there. The folder is outside the source: `TYPECHECK_OUT` if you set it, else `D:\projects\Codex\temp\remsound-mac\typecheck-out` when that scratch folder exists, else `%TEMP%\remsound-mac-typecheck`. You need the Swift toolchain for Windows (swift.org) and Visual Studio's C++ tools. The script finds both. Set `SWIFT_HOME`, `SWIFT_VERSION` or `VCVARS` if it picks the wrong ones.

## Known errors (16 October 2026)

A clean run today ends with fourteen errors, all Windows-side, none an app fault. Treat any others as real:

- **RemSoundRuntime, one error.** In PluginInstallationStatus.swift, one expression is too complex for the compiler to type-check in reasonable time on Windows. The module is emitted anyway (`-experimental-allow-module-with-compiler-errors`), so everything after it is still checked.
- **RemSoundCoreTests, five errors.** All five come from Windows' XCTest and Foundation:
  - WebFunnelImageNativeTests makes an `XCTestCase()` without a name, which Windows' XCTest can't do;
  - WebBrowserEndToEndTests uses `POSIXError(rawValue:)` (three errors from that one line);
  - RouterHTTPTransportTests' `URLAuthenticationChallengeSender` stand-in leaves out methods that are optional on a Mac but required on Windows.
- **RemSoundAppTests, eight errors** (checked since 16 October). Both need the Objective-C runtime:
  - NativeContextHelpTests makes a selector from a property, `#selector(NSObject.description)` (six errors from three lines);
  - NativeDialogAuditTests calls an optional delegate method, `controlTextDidChange?(...)` (two errors).

How the check copes with Windows (16 October 2026):

- **The C runtime's POSIX names are switched off.** The Windows C runtime's POSIX-named aliases are hidden with `-D_CRT_DECLARE_NONSTDC_NAMES=0` and `-D_CRT_NO_POSIX_ERROR_CODES`. That leaves the Darwin stand-in's stat, close, open, O_ and EWOULDBLOCK, laid out as a Mac lays them out, as the only ones.
- **Mac-only Foundation, Darwin and Core Foundation are imported implicitly.** The app's modules implicitly import the Darwin and Core Foundation stand-ins and MacFoundationExtras, because a Mac's Foundation brings all three. They also implicitly import FoundationNetworking and FoundationXML, where Windows keeps URLSession and XMLParser.
- **Sources are checked from copies in the work folder.** Each line stays where it was, with three changes:
  - S_IFMT, S_IFDIR, S_IFREG and S_IFLNK are qualified as Darwin's;
  - `.fileDescriptor` becomes `._macFileDescriptor`;
  - in RemSoundApp and its tests, `@objc` is dropped and `#selector` is rewritten.
- **The modules are built as a debug build.** They are built with `-D DEBUG`, as `swift test` builds them, so code under `#if DEBUG` is checked too.

## What is in here

- `stubs/`: one Swift file per Apple module the app imports. They are CoreAudio (with the C structs in `stubs/CoreAudioC`, which is a real C header, so the IOProc and AudioBufferList behave as they do on a Mac), AudioToolbox, AVFoundation, CryptoKit, Security, Darwin (the BSD sockets and `kill`), AppKit, Carbon (the hot-key calls and key codes, with Apple's values), SwiftUI (with the Combine pieces the menus use) and ServiceManagement. They hold declarations only. Each signature follows Apple's SDK as Swift imports it, including main-actor isolation, marked `@preconcurrency` as the SDK's is.
- `typecheck.sh`: builds the stand-ins, then the app's modules in dependency order. It also makes two adjustments a Mac doesn't need. Windows' Swift has no Objective-C runtime, so the script copies RemSoundApp's sources to its work folder, drops `@objc`, and turns `#selector(m)` into `_objcSelector(m)`. That still checks that `m` exists. The copies go in the work folder; the app's own files are never changed. The script also makes the Clang module maps for AudioSupport and UpdateSupport, which SwiftPM makes on a Mac.
- `TestBundle.swift`: stands in for the `Bundle.module` that SwiftPM generates for the tests' Fixtures.

## When it reports an error

First decide which side is wrong. If the stand-in is missing a member, or has a signature that is only approximate, fix the stub by copying the declaration from Apple's documentation. Keep the stub as small as the app needs. Otherwise the app has a real error, and it would fail on a Mac too, so fix the app. Three planted faults were checked when this was set up. They were a misspelt method in AppDelegate.swift, a missing menu action inside a SwiftUI menu body, and a misspelt call in one of the app's tests. All three were reported.

The SystemConfiguration stand-in covers the read-only interface list, BSD name and interface type used by route diagnostics. Darwin additionally declares `connect` for a route probe that sends no packets. Native Mac tests remain responsible for actual route selection and CF bridging.

What it cannot check: anything the stubs leave out (a stub that accepts too much hides an error), Objective-C selectors' runtime spelling, Info.plist and entitlements, the C code's own compile (AudioSupport.c), the JUCE plugin, and all behaviour. A PASS here means "should compile on a Mac". It does not mean "works".

The UpdateSupport module exposes only its narrow C header. Darwin file-identity declarations are stand-ins; this harness cannot verify libarchive linkage, extraction, root ownership, deadline enforcement or cleanup. Run the native Mac updater suites for those checks.
