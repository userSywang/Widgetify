#!/usr/bin/env python3
"""Build an isolated Widgetify process that calls the public Notion REST API.
Secrets are read from a user-supplied folder, never printed or embedded in the app.
"""
import argparse,json,plistlib,re,subprocess,sys,hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
from patch_binary import validate_custom_base
from inspiration_build_support import integration_seed

def run(*args):subprocess.run([str(x) for x in args],check=True)
def main():
 p=argparse.ArgumentParser();p.add_argument('--properties',action='store_true');p.add_argument('--retain-test-page',action='store_true');p.add_argument('--output',type=Path,required=True);p.add_argument('--credential-directory',type=Path,required=True);a=p.parse_args()
 if a.retain_test_page and not a.properties:p.error('Retaining a page requires --properties')
 trial_name=('NotionPropertyReview' if a.retain_test_page else 'NotionPropertyTrial') if a.properties else 'NotionTrial'
 trial_source=ROOT/'experiments/notion-api-trial'/('PropertyTrial.m' if a.properties else 'NotionTrial.m')
 base=Path('/Applications/Widgetify 0.2.13.app');app=a.output/'Widgetify Notion API 测试.app'
 if app.exists():p.error('Choose a fresh output directory')
 if (Path.home()/'Library/Containers/local.widgetify.stylepreview.integration.v0211/Data/Library/Application Support'/trial_name/'report.json').exists():p.error('A previous trial report exists; review its result before starting another run')
 credentials=set()
 for file in a.credential_directory.iterdir():
  if file.is_file():
   try:credentials.update(re.findall(r'(?:ntn_|secret_)[A-Za-z0-9_]+',file.read_text()))
   except (UnicodeError,OSError):pass
 if len(credentials)!=1:p.error('Expected one credential; no values have been printed')
 validate_custom_base(base/'Contents/MacOS/Widgetify')
 a.output.mkdir(parents=True,exist_ok=True);run('ditto',base,app)
 module=app/'Contents/Frameworks/WidgetifyEnhancements.dylib'
 # Keep the host executable's existing load commands. Link the experiment into
 # its already-supported enhancement module, without modifying production files.
 run('xcrun','clang','-arch','arm64','-mmacosx-version-min=12.0','-fobjc-arc','-fblocks','-dynamiclib','-framework','AppKit','-framework','UserNotifications','-framework','CoreGraphics','-framework','QuartzCore',*[ROOT/'src'/f for f in ['Enhancements.m','OriginalFolderBridge.m','ComponentIntegration.m','ComponentSettings.m','ReminderSchedule.m','DirectoryReferences.m']],trial_source,app/'Contents/Frameworks/WidgetifyContext.dylib','-o',module,'-install_name','@rpath/WidgetifyEnhancements.dylib')
 info=plistlib.loads((app/'Contents/Info.plist').read_bytes());info.update(CFBundleIdentifier='local.widgetify.stylepreview.integration.v0211',CFBundleName='Widgetify Notion API 测试',CFBundleDisplayName='Widgetify Notion API 测试',WidgetifyIntegrationTest=True,WidgetifyNotionAPITrial=not a.properties,WidgetifyNotionPropertyTrial=a.properties,WidgetifyNotionKeepTestPage=a.retain_test_page,WidgetifyStylePreview=False,WidgetifyPreviewUseMainScreen=True)
 (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info));(app/'Contents/Resources/StylePreview.plist').write_bytes(plistlib.dumps(integration_seed('0.2.13')))
 entitlement=a.output/'entitlements.plist';entitlement.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True}))
 child=a.output/'git-entitlements.plist';child.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.inherit':True}))
 run('codesign','--force','--deep','--sign','-','--entitlements',entitlement,app);run('codesign','--force','--sign','-','--entitlements',child,app/'Contents/MacOS/InspirationGit');run('codesign','--force','--sign','-','--entitlements',entitlement,app);run('codesign','--verify','--deep','--strict',app)
 library=Path.home()/'Library/Containers/local.widgetify.stylepreview.integration.v0211/Data/Library';trial=library/'Application Support'/trial_name
 if (trial/'report.json').exists():p.error('A trial report exists; review it before building another run')
 trial.mkdir(parents=True,exist_ok=True);trial.chmod(0o700)
 token=trial/'token.txt';token.write_text(credentials.pop());token.chmod(0o600)
 config=trial/'config.json';config.write_text(json.dumps({'dataSourceID':'1d9bc4ff-b77a-82d8-9add-87ced13f644a'}));config.chmod(0o600)
 original=Path.home()/'Library/Containers/local.widgetify.custom/Data/Library/Application Support/Inspiration/ideas-v1.json';blob=original.read_bytes()
 snapshot=trial/'ideas-v1.json';snapshot.write_bytes(blob);snapshot.chmod(0o600)
 (a.output/'trial-manifest.json').write_text(json.dumps({'app':str(app.resolve()),'sourceNotesSHA256':hashlib.sha256(blob).hexdigest(),'trialSourceSHA256':hashlib.sha256((trial_source).read_bytes()).hexdigest(),'sourceApp':str(base),'report':str(trial/'report.json'),'installedAppModified':False},indent=2))
 print(json.dumps({'app':str(app.resolve()),'prepared':True,'credentialEmbeddedInApp':False,'installedAppModified':False}))
if __name__=='__main__':main()
