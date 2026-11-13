#!/usr/bin/env python3
"""Build a local Widgetify derivative from a separately installed supported base."""
import argparse
import json
import plistlib
import subprocess
from pathlib import Path
from patch_binary import patch, arm64_slice, validate_custom_base
import struct

ROOT = Path(__file__).resolve().parents[1]

def run(*args):
    subprocess.run([str(a) for a in args], check=True)

def embed(executable):
    data = bytearray(executable.read_bytes())
    arm, _ = arm64_slice(data)
    commands, size = struct.unpack_from('<II', data, arm+16)
    name = b'@executable_path/../Frameworks/WidgetifyEnhancements.dylib\0'
    cursor = arm+32
    for _ in range(commands):
        kind, length = struct.unpack_from('<II', data, cursor)
        if kind == 0xc and name in data[cursor:cursor+length]:
            return
        cursor += length
    command_size = (24+len(name)+7) & ~7
    end = arm+32+size
    if end+command_size >= arm+0x2fe0 or any(data[end:end+command_size]):
        raise ValueError('No unused Mach-O header space for the enhancement module')
    command = struct.pack('<6I', 0xc, command_size, 24, 0, 0x10000, 0x10000) + name
    data[end:end+command_size] = command.ljust(command_size, b'\0')
    struct.pack_into('<II', data, arm+16, commands+1, size+command_size)
    executable.write_bytes(data)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--base-app', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'dist')
    args = parser.parse_args()
    version = (ROOT/'VERSION').read_text().strip()
    args.output.mkdir(parents=True, exist_ok=True)
    app = args.output/'Widgetify.app'
    if app.exists():
        parser.error('Output Widgetify.app already exists; use a fresh output directory')
    base_info = plistlib.loads((args.base_app/'Contents/Info.plist').read_bytes())
    is_original = (base_info.get('CFBundleShortVersionString'), base_info.get('CFBundleVersion')) == ('4.55', '216')
    if not is_original:
        if base_info.get('CFBundleIdentifier') != 'local.widgetify.custom':
            parser.error('Requires supported Widgetify 4.55 (216) or its verified local customization')
        validate_custom_base(args.base_app/'Contents/MacOS/Widgetify')
    run('ditto', args.base_app, app)
    changes = patch(app/'Contents/MacOS/Widgetify') if is_original else [{'base':'verified customization; original binary changes retained'}]
    info = base_info.copy()
    info.update(CFBundleIdentifier='local.widgetify.custom', CFBundleName='Widgetify', CFBundleDisplayName='Widgetify '+version, CFBundleShortVersionString=version, CFBundleVersion='216.'+'.'.join(version.split('.')[1:]))
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(args.base_app)], check=True, capture_output=True)
    entitlements = plistlib.loads(result.stdout)
    entitlements = {k:v for k,v in entitlements.items() if k not in ('com.apple.application-identifier',) and not k.startswith('com.apple.developer.')}
    entitlements_path = args.output/'entitlements.plist'
    entitlements_path.write_bytes(plistlib.dumps(entitlements))
    source = ROOT/'src/Enhancements.m'
    if version != '0.1.0':
        if not source.exists():
            raise ValueError('Enhancement source is missing')
        module = app/'Contents/Frameworks/WidgetifyEnhancements.dylib'
        run('xcrun','clang','-arch','arm64','-mmacosx-version-min=12.0','-fobjc-arc','-fblocks','-dynamiclib','-framework','AppKit','-framework','UserNotifications','-framework','CoreGraphics', source, '-o', module, '-install_name','@rpath/WidgetifyEnhancements.dylib')
        embed(app/'Contents/MacOS/Widgetify')
    run('codesign','--force','--deep','--sign','-','--entitlements',entitlements_path,app)
    run('codesign','--verify','--deep','--strict',app)
    (args.output/'patch-manifest.json').write_text(json.dumps(changes,indent=2)+'\n')
    archive = args.output/('Widgetify-'+version+'-macOS-arm64.zip')
    run('ditto','-c','-k','--sequesterRsrc','--keepParent',app,archive)
    print(archive)

if __name__ == '__main__':
    main()
