#!/usr/bin/env python3
"""Prepare or apply an approved local installation. Does not publish or launch apps."""
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import uuid
from pathlib import Path
from migrate_inspiration import validate,migrate,empty_target


def app_fingerprint(app):
    digest=hashlib.sha256()
    for path in sorted(app.rglob('*')):
        if path.is_symlink():digest.update((str(path.relative_to(app))+'->'+str(path.readlink())).encode())
        elif path.is_file():digest.update(str(path.relative_to(app)).encode());digest.update(b'\0');digest.update(path.read_bytes())
    return digest.hexdigest()


def main():
    p=argparse.ArgumentParser();p.add_argument('--app',type=Path,required=True);p.add_argument('--inspiration-source',type=Path,required=True);p.add_argument('--backup-directory',type=Path,required=True);p.add_argument('--apply',action='store_true');p.add_argument('--expected-app-sha256');a=p.parse_args()
    app=a.app.resolve();info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier')!='local.widgetify.custom' or not info.get('WidgetifyInspirationEnabled') or info.get('WidgetifyIntegrationTest') or info.get('WidgetifyStylePreview'):p.error('Use the actual production build')
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    version=info['CFBundleShortVersionString'];destination=Path('/Applications')/('Widgetify '+version+'.app')
    library=Path.home()/'Library/Containers/local.widgetify.custom/Data/Library'
    target=library/'Application Support/Inspiration'
    records=validate(a.inspiration_source);fingerprint=app_fingerprint(app)
    plan={'version':version,'appSHA256':fingerprint,'destination':str(destination),'inspirationRecords':len(records['entries']),'destinationNotesEmpty':empty_target(target),'willApply':a.apply}
    if not a.apply:print(json.dumps(plan,ensure_ascii=False,indent=2));return
    if fingerprint!=a.expected_app_sha256:p.error('The app differs from the reviewed build')
    if destination.exists():p.error('Installation destination already exists; nothing overwritten')
    if not empty_target(target):p.error('Production already has notes; nothing overwritten')
    commands=subprocess.check_output(['ps','-axo','command'],text=True)
    if any('/Applications/Widgetify ' in line and '.app/Contents/MacOS/Widgetify' in line for line in commands.splitlines()):p.error('Close the currently installed Widgetify before applying')
    backup=a.backup_directory.resolve()
    if backup.exists():p.error('Choose a fresh private backup directory')
    backup.mkdir(parents=True,mode=0o700)
    for relative in ['Preferences/local.widgetify.custom.plist','Application Support/Widgetify/autosaved.widgetlist4']:
        path=library/relative
        if path.exists():
            out=backup/path.name;shutil.copy2(path,out);out.chmod(0o600)
    for old in Path('/Applications').glob('Widgetify *.app'):
        subprocess.run(['ditto',str(old),str(backup/old.name)],check=True)
    # Keep the new app hidden until verification and the data migration both succeed.
    staging=destination.with_name('.Widgetify-install-'+uuid.uuid4().hex+'.app')
    try:
        subprocess.run(['ditto',str(app),str(staging)],check=True)
        subprocess.run(['codesign','--verify','--deep','--strict',str(staging)],check=True)
        if app_fingerprint(staging)!=fingerprint:raise RuntimeError('Installed copy does not match the reviewed build')
        result=migrate(a.inspiration_source,target)
        staging.rename(destination)
    except Exception:
        if staging.exists():shutil.move(str(staging),str(backup/'Failed-new-build.app'))
        raise
    (backup/'installation.json').write_text(json.dumps(dict(plan,migration=result),ensure_ascii=False,indent=2));(backup/'installation.json').chmod(0o600)
    print(json.dumps(dict(plan,migration=result),ensure_ascii=False,indent=2))

if __name__=='__main__':main()
