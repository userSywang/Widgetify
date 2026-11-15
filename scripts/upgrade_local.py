#!/usr/bin/env python3
"""Upgrade an approved app build without importing or overwriting existing notes."""
import argparse,json,plistlib,shutil,subprocess,uuid
from pathlib import Path
from install_local import app_fingerprint
from migrate_inspiration import fingerprint

def main():
 p=argparse.ArgumentParser();p.add_argument('--app',type=Path,required=True);p.add_argument('--current-app',type=Path,required=True);p.add_argument('--backup-directory',type=Path,required=True);p.add_argument('--apply',action='store_true');p.add_argument('--expected-app-sha256');a=p.parse_args()
 app=a.app.resolve();old=a.current_app.resolve();info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
 if info.get('CFBundleIdentifier')!='local.widgetify.custom' or info.get('WidgetifyIntegrationTest') or info.get('WidgetifyStylePreview'):p.error('Use the production build')
 old_info=plistlib.loads((old/'Contents/Info.plist').read_bytes())
 if old_info.get('CFBundleIdentifier')!='local.widgetify.custom':p.error('Current app is not the supported customization')
 subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
 target=Path('/Applications')/('Widgetify '+info['CFBundleShortVersionString']+'.app');sha=app_fingerprint(app)
 library=Path.home()/'Library/Containers/local.widgetify.custom/Data/Library';notes=library/'Application Support/Inspiration'
 before=fingerprint(notes) if notes.exists() else None
 plan={'version':info['CFBundleShortVersionString'],'appSHA256':sha,'destination':str(target),'preserveExistingNotes':True,'willApply':a.apply}
 if not a.apply:print(json.dumps(plan,ensure_ascii=False,indent=2));return
 if sha!=a.expected_app_sha256:p.error('The app differs from the reviewed build')
 if target.exists():p.error('Target already exists; nothing overwritten')
 commands=subprocess.check_output(['ps','-axo','command'],text=True).splitlines()
 if any(line.startswith(str(old/'Contents/MacOS/Widgetify')) for line in commands):p.error('Close the old app before upgrading')
 backup=a.backup_directory.resolve()
 if backup.exists():p.error('Choose a fresh private backup directory')
 backup.mkdir(parents=True,mode=0o700)
 subprocess.run(['ditto',str(old),str(backup/old.name)],check=True)
 for relative in ['Preferences/local.widgetify.custom.plist','Application Support/Widgetify/autosaved.widgetlist4']:
  source=library/relative
  if source.exists():shutil.copy2(source,backup/source.name);(backup/source.name).chmod(0o600)
 if notes.exists():shutil.copytree(notes,backup/'Inspiration')
 staging=target.with_name('.Widgetify-upgrade-'+uuid.uuid4().hex+'.app')
 try:
  subprocess.run(['ditto',str(app),str(staging)],check=True)
  subprocess.run(['codesign','--verify','--deep','--strict',str(staging)],check=True)
  if app_fingerprint(staging)!=sha:raise RuntimeError('Installed copy differs from the reviewed build')
  if (fingerprint(notes) if notes.exists() else None)!=before:raise RuntimeError('Notes changed during upgrade; retry after closing active writers')
  staging.rename(target)
 except Exception:
  if staging.exists():shutil.move(str(staging),str(backup/'Failed-new-build.app'))
  raise
 (backup/'upgrade.json').write_text(json.dumps(plan,ensure_ascii=False,indent=2));(backup/'upgrade.json').chmod(0o600)
 print(json.dumps(dict(plan,notesUnchanged=True),ensure_ascii=False,indent=2))
if __name__=='__main__':main()
