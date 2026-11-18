#!/usr/bin/env python3
"""Build an isolated inspiration-only preview. Optional live verification uses a private credential file."""
import argparse,hashlib,json,plistlib,re,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def run(*args):subprocess.run([str(a) for a in args],check=True)
def main():
 p=argparse.ArgumentParser();p.add_argument('--base-app',type=Path,default=Path('/Applications/Widgetify 0.2.14.app'));p.add_argument('--output',type=Path,required=True);p.add_argument('--credential-directory',type=Path);p.add_argument('--ui-credential-directory',type=Path);p.add_argument('--bidirectional-live',action='store_true');p.add_argument('--resume-page-id');a=p.parse_args()
 if a.credential_directory and a.ui_credential_directory:p.error('Select either live harness or UI credential setup')
 if a.bidirectional_live and not a.resume_page_id:p.error('Provide the reviewed existing test page ID')
 app=a.output/'Widgetify Notion 灵感预览.app'
 if app.exists():p.error('Choose a fresh output directory')
 library=Path.home()/'Library/Containers/local.widgetify.stylepreview.integration.v0211/Data/Library'
 trial=library/('Application Support/NotionBidirectionalLiveV3' if a.bidirectional_live else 'Application Support/NotionEngineLive')
 if a.credential_directory and (trial/'report.json').exists():p.error('Review the previous live report before another test')
 a.output.mkdir(parents=True,exist_ok=True);run('ditto',a.base_app,app)
 info=plistlib.loads((app/'Contents/Info.plist').read_bytes());info.update(CFBundleIdentifier='local.widgetify.stylepreview.integration.v0211',CFBundleName='Widgetify Notion 灵感预览',CFBundleDisplayName='Widgetify Notion 灵感预览',WidgetifyIntegrationTest=True,WidgetifyStylePreview=False,WidgetifyPreviewUseMainScreen=True,WidgetifyNotionEnginePreview=bool(a.credential_directory))
 if a.ui_credential_directory:info['WidgetifyNotionCredentialScope']=a.output.name
 (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
 widget={'id':'d1'*16,'name':'widget_name_shortcuts','brief':'widget_brief_shortcuts','type':{'shortcuts':{}},'needPro':False,'size':[{'large':{}}],'currentSize':{'large':{}},'screenID':'preview','screenFrame':[[0,0],[1920,1080]],'winFrame':[[1080,180],[344,359]],'isFixed':False,'isPined':False}
 prefs={'userDidAddWidgets':True,'WWant_isGuideShowed':True,'initShortcutHasSet':True,'custom.inspiration.bootstrap.v1':True,'appVersion':'0.2.13'}
 source=library.parent.parent.parent/'local.widgetify.custom/Data/Library/Preferences/local.widgetify.custom.plist'
 # Only copy the existing global appearance choices, never user notes or app lists.
 source=Path.home()/'Library/Containers/local.widgetify.custom/Data/Library/Preferences/local.widgetify.custom.plist'
 actual=plistlib.loads(source.read_bytes())
 for k,v in actual.items():
  if k.startswith('WWant_') and any(x in k.lower() for x in ['theme','background','color']):prefs[k]=v
 seed={'revision':'notion-sync-ui-v1','preferences':prefs,'layoutData':json.dumps([widget]).encode()}
 (app/'Contents/Resources/StylePreview.plist').write_bytes(plistlib.dumps(seed))
 sources=[ROOT/'src'/s for s in ['WidgetContext.swift','WaterPresentation.swift','ShortcutCategories.swift','InspirationPresentation.swift','InspirationHistory.swift','InspirationNotion.swift','InspirationIntegration.swift']]
 if a.credential_directory:sources.append(ROOT/('experiments/notion-api-trial/BidirectionalLive.swift' if a.bidirectional_live else 'experiments/notion-api-trial/SyncEngineLive.swift'))
 context=app/'Contents/Frameworks/WidgetifyContext.dylib'
 run('xcrun','swiftc','-target','arm64-apple-macos12.0','-emit-library','-parse-as-library',*sources,'-o',context,'-Xlinker','-install_name','-Xlinker','@loader_path/WidgetifyContext.dylib')
 if a.credential_directory:
  run('xcrun','clang','-arch','arm64','-mmacosx-version-min=12.0','-fobjc-arc','-fblocks','-dynamiclib','-framework','AppKit','-framework','UserNotifications','-framework','CoreGraphics','-framework','QuartzCore',*[ROOT/'src'/s for s in ['Enhancements.m','OriginalFolderBridge.m','ComponentIntegration.m','ComponentSettings.m','ReminderSchedule.m','DirectoryReferences.m']],ROOT/'experiments/notion-api-trial/SyncEngineLive.m',context,'-o',app/'Contents/Frameworks/WidgetifyEnhancements.dylib','-install_name','@rpath/WidgetifyEnhancements.dylib')
 ent=a.output/'entitlements.plist';ent.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True}))
 run('codesign','--force','--sign','-','--entitlements',ent,app);run('codesign','--verify','--deep','--strict',app)
 if a.credential_directory or a.ui_credential_directory:
  tokens=set()
  for f in (a.credential_directory or a.ui_credential_directory).iterdir():
   if f.is_file():
    try:tokens.update(re.findall(r'(?:ntn_|secret_)[A-Za-z0-9_]+',f.read_text()))
    except (UnicodeError,OSError):pass
  if len(tokens)!=1:p.error('Expected one credential; no values printed')
  if a.ui_credential_directory:trial=library/'Application Support/Inspiration'
  trial.mkdir(parents=True,exist_ok=True,mode=0o700)
  if a.bidirectional_live:(trial/'config.json').write_text(json.dumps({'resumePageID':a.resume_page_id}))
  token=trial/('notion-connection-import-once' if a.ui_credential_directory else 'token.txt');token.write_text(tokens.pop());token.chmod(0o600)
 (a.output/'preview-manifest.json').write_text(json.dumps({'app':str(app.resolve()),'isolated':True,'inspirationOnly':True,'liveTest':bool(a.credential_directory),'sources':{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in sources}},indent=2))
 print(app)
if __name__=='__main__':main()
