#!/usr/bin/env python3
"""Create synthetic sealed bundles for BundledPluginSourceTests; never load a plugin."""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import shutil
import stat
import subprocess
import sys


def command(arguments):
    subprocess.run(arguments, check=True, capture_output=True, timeout=30)


def sign(path):
    command(['/usr/bin/codesign', '--force', '--sign', '-', str(path)])


def create(root):
    root = Path(root).absolute()
    info = root.lstat()
    if root.resolve() != root or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise ValueError('use an existing owned private test root')
    names = ['sealed-source-fixture', 'sealed-tampered', 'sealed-stale-inventory',
             'sealed-wrong-version', 'sealed-foreign-plugin', 'sealed-thin-runtime', 'sealed-missing-manifest']
    if any((root / name).exists() for name in names):
        raise ValueError('fixture targets must be absent')
    work = root / names[0]
    work.mkdir(mode=0o700)
    stage = work / 'stage'
    app = stage / 'RemSound.app'
    host = work / 'plugin/host-runtime/Release'
    host.mkdir(parents=True)
    (work / 'runtime.c').write_text('int rs_fixture(int x) {return x+1;}\n')
    (work / 'plugin.c').write_text('extern int rs_fixture(int); int rs_entry(int x) {return rs_fixture(x);}\n')
    (work / 'app.c').write_text('int main(void) {return 0;}\n')
    for architecture in ['arm64', 'x86_64']:
        command(['xcrun', 'clang', '-arch', architecture, '-dynamiclib', str(work / 'runtime.c'),
                 '-install_name', '@rpath/libRemSoundPluginHost-v1.dylib', '-o', str(work / ('runtime-' + architecture))])
        command(['xcrun', 'clang', '-arch', architecture, '-bundle', str(work / 'plugin.c'),
                 str(work / ('runtime-' + architecture)), '-Wl,-rpath,' + str(host), '-o', str(work / ('plugin-' + architecture))])
        command(['xcrun', 'clang', '-arch', architecture, str(work / 'app.c'), '-o', str(work / ('app-' + architecture))])
    def universal(prefix, output):
        command(['lipo', '-create', str(work / (prefix + '-arm64')), str(work / (prefix + '-x86_64')), '-output', str(output)])
    universal('runtime', host / 'libRemSoundPluginHost-v1.dylib')
    for directory in ['MacOS', 'Frameworks', 'Resources']:
        (app / 'Contents' / directory).mkdir(parents=True, exist_ok=True)
    universal('app', app / 'Contents/MacOS/RemSound')
    shutil.copy2(app / 'Contents/MacOS/RemSound', app / 'Contents/MacOS/RemSoundUpdater')
    shutil.copy2(host / 'libRemSoundPluginHost-v1.dylib', app / 'Contents/Frameworks/libmp3lame.0.dylib')
    source = Path(__file__).resolve().parents[2]
    metadata = plistlib.loads((source / 'App/Info.plist').read_bytes())
    def info_file(path, identifier, kind):
        path.write_bytes(plistlib.dumps(dict(CFBundleIdentifier=identifier, CFBundleExecutable='RemSound',
            CFBundleShortVersionString=metadata['CFBundleShortVersionString'], CFBundleVersion=metadata['CFBundleVersion'], CFBundlePackageType=kind)))
    info_file(app / 'Contents/Info.plist', 'org.remsound.mac', 'APPL')
    for format_name, name in [('AU', 'RemSound.component'), ('VST3', 'RemSound.vst3'), ('CLAP', 'RemSound.clap')]:
        bundle = stage / 'Plugins' / format_name / name
        for directory in ['MacOS', 'Resources']:
            (bundle / 'Contents' / directory).mkdir(parents=True, exist_ok=True)
        universal('plugin', bundle / 'Contents/MacOS/RemSound')
        (bundle / 'Contents/Resources/help.txt').write_text('synthetic package fixture, not a real DAW wrapper\n')
        info_file(bundle / 'Contents/Info.plist', 'org.remsound.plugin', 'BNDL')
    text = (source / 'Build.sh').read_text()
    start = text.index('host_runtime=')
    end = text.index('\ndestination=', start)
    script = work / 'packaging-block.sh'
    script.write_text('set -euo pipefail\nwork="$1"\nstage="$2"\nsource_root="$3"\n' + text[start:end] + '\n')
    command(['/bin/bash', str(script), str(work), str(stage), str(source)])
    target = work / 'RemSound.app'
    shutil.copytree(app, target)
    command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(target)])
    for name in names[1:]:
        variant = root / name / 'RemSound.app'
        variant.parent.mkdir(mode=0o700)
        shutil.copytree(target, variant)
        plugin = variant / 'Contents/PlugIns/RemSound.vst3'
        manifest = variant / 'Contents/Resources/plugin-payload.json'
        if name == 'sealed-tampered':
            with (variant / 'Contents/MacOS/RemSound').open('ab') as stream:
                stream.write(b'tampered app executable')
            continue
        if name == 'sealed-stale-inventory':
            (plugin / 'Contents/Resources/help.txt').write_text('changed\n')
        if name == 'sealed-wrong-version':
            path = variant / 'Contents/Info.plist'
            data = plistlib.loads(path.read_bytes())
            data['CFBundleShortVersionString'] = '9.9.9'
            path.write_bytes(plistlib.dumps(data))
        if name == 'sealed-foreign-plugin':
            path = plugin / 'Contents/Info.plist'
            data = plistlib.loads(path.read_bytes())
            data['CFBundleIdentifier'] = 'org.other.plugin'
            path.write_bytes(plistlib.dumps(data))
        if name == 'sealed-thin-runtime':
            path = plugin / 'Contents/Frameworks/libRemSoundPluginHost-v1.dylib'
            temporary = path.with_suffix('.thin')
            command(['/usr/bin/lipo', str(path), '-thin', 'arm64', '-output', str(temporary)])
            temporary.replace(path)
            sign(path)
        if name == 'sealed-missing-manifest':
            manifest.unlink()
        sign(plugin)
        if name == 'sealed-thin-runtime':
            rows = json.loads(manifest.read_text())
            for row in rows['files']:
                path = variant / 'Contents/PlugIns' / row['path']
                row['size'] = path.stat().st_size
                row['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
            manifest.write_text(json.dumps(rows))
        sign(variant)
        command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(variant)])


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: CreatePluginPayloadFixture.py EXISTING-PRIVATE-TEST-ROOT')
    create(sys.argv[1])
    print('Created seven synthetic sealed-source fixtures; no plugin was loaded or installed.')
