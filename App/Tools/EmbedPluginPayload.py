#!/usr/bin/env python3
"""Embed the fixed plugin source in a staging app before its outer signature."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys

LOCATIONS = (('AU', 'RemSound.component'), ('VST3', 'RemSound.vst3'), ('CLAP', 'RemSound.clap'))
MAX_FILES = 4096
MAX_FILE_BYTES = 32 * 1024 * 1024
MAX_PAYLOAD_BYTES = 128 * 1024 * 1024
MAX_MANIFEST_BYTES = 128 * 1024
RUNTIME = 'libRemSoundPluginHost-v1.dylib'


def command(arguments):
    return subprocess.run(arguments, check=True, capture_output=True, text=True, timeout=30).stdout


def regular(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_mode & 0o022 or info.st_size > MAX_FILE_BYTES:
        raise ValueError('payload file refused')
    return info


def inventory(root):
    result = []
    folded = set()
    total = 0
    visited = 0
    for folder, directories, files in os.walk(root, followlinks=False):
        for name in directories + files:
            visited += 1
            path = Path(folder) / name
            relative = path.relative_to(root).as_posix()
            if visited > MAX_FILES * 2 or len(relative.encode()) > 1024 or len(relative.split('/')) > 16 or '\\' in relative or any(ord(char) < 32 for char in relative) or relative.lower() in folded:
                raise ValueError('payload inventory bounds exceeded')
            folded.add(relative.lower())
            info = path.lstat()
            if stat.S_ISDIR(info.st_mode):
                if info.st_mode & 0o022:
                    raise ValueError('writable payload directory')
                continue
            info = regular(path)
            raw = path.read_bytes()
            after = path.lstat()
            if (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_mode) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_mode):
                raise ValueError('payload changed while reading')
            total += len(raw)
            if total > MAX_PAYLOAD_BYTES or len(result) >= MAX_FILES:
                raise ValueError('payload inventory bounds exceeded')
            result.append(dict(path=relative, sha256=hashlib.sha256(raw).hexdigest(), size=len(raw), mode=stat.S_IMODE(info.st_mode)))
    return sorted(result, key=lambda entry: entry['path'])


def embed(app, plugins):
    app, plugins = Path(app).absolute(), Path(plugins).absolute()
    if app.resolve() != app or plugins.resolve() != plugins or app.name != 'RemSound.app':
        raise ValueError('staging roots refused')
    for directory in [app / 'Contents', app / 'Contents/Resources', plugins]:
        if not directory.is_dir() or directory.resolve() != directory:
            raise ValueError('staging directory redirected')
    def read_info(path):
        if regular(path).st_size > MAX_MANIFEST_BYTES:
            raise ValueError('metadata bounds exceeded')
        return plistlib.loads(path.read_bytes())
    info = read_info(app / 'Contents/Info.plist')
    version, build = info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')
    if info.get('CFBundleIdentifier') != 'org.remsound.mac' or info.get('CFBundleExecutable') != 'RemSound' or not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+', version) or not isinstance(build, str) or not re.fullmatch(r'\d{1,10}', build):
        raise ValueError('staging app metadata refused')
    sources = []
    for fmt, name in LOCATIONS:
        bundle = plugins / fmt / name
        if not bundle.is_dir() or bundle.resolve() != bundle:
            raise ValueError('plugin source missing or redirected')
        metadata = read_info(bundle / 'Contents/Info.plist')
        if metadata.get('CFBundleIdentifier') != 'org.remsound.plugin' or metadata.get('CFBundleExecutable') != 'RemSound' or metadata.get('CFBundleShortVersionString') != version:
            raise ValueError('plugin metadata refused')
        command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(bundle)])
        binary = bundle / 'Contents/MacOS/RemSound'
        runtime = bundle / 'Contents/Frameworks' / RUNTIME
        for path in [binary, runtime]:
            regular(path)
            for architecture in ('arm64', 'x86_64'):
                command(['/usr/bin/lipo', '-verify_arch', architecture, str(path)])
        dependencies = command(['/usr/bin/otool', '-L', str(binary)])
        if '@rpath/' + RUNTIME not in dependencies:
            raise ValueError('shared runtime dependency missing')
        for line in dependencies.splitlines()[1:]:
            if line.rstrip().endswith(':'):
                continue
            dependency = line.strip().split(' (', 1)[0]
            if dependency and dependency != '@rpath/' + RUNTIME and not dependency.startswith(('/System/Library/', '/usr/lib/')):
                raise ValueError('plugin dependency outside fixed runtime/system scope')
        commands = command(['/usr/bin/otool', '-l', str(binary)])
        if 'path @loader_path/../Frameworks ' not in commands:
            raise ValueError('plugin runtime search path missing')
        inventory(bundle)
        sources.append((name, bundle))
    destination = app / 'Contents/PlugIns'
    if destination.exists():
        if destination.resolve() != destination or set(path.name for path in destination.iterdir()) - {name for _, name in LOCATIONS}:
            raise ValueError('unknown embedded plugin bystander')
        inventory(destination)
    else:
        destination.mkdir()
    # Only fresh build/release staging is supplied here; all existing entries were checked above.
    for name, source in sources:
        target = destination / name
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(source, target)
    entries = inventory(destination)
    raw = json.dumps(dict(schema=1, appIdentifier='org.remsound.mac', version=version, build=build,
                          architectures=['arm64', 'x86_64'], files=entries), sort_keys=True, separators=(',', ':')).encode()
    if len(raw) > MAX_MANIFEST_BYTES:
        raise ValueError('payload manifest exceeds bound')
    output = app / 'Contents/Resources/plugin-payload.json'
    if output.is_symlink() or not output.parent.is_dir():
        raise ValueError('payload manifest destination refused')
    temporary = output.with_name('.plugin-payload.json')
    with temporary.open('xb') as stream:
        stream.write(raw)
    temporary.chmod(0o644)
    temporary.replace(output)
    return len(entries)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('Usage: EmbedPluginPayload.py STAGING-RemSound.app STAGING-Plugins')
    try:
        count = embed(sys.argv[1], sys.argv[2])
    except (OSError, ValueError, subprocess.SubprocessError, plistlib.InvalidFileException):
        raise SystemExit('Plugin payload staging refused; no release signature was produced.')
    print('Embedded fixed plugin payload: ' + str(count) + ' files. Sign the app after this step.')
