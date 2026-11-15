#!/usr/bin/env python3
"""Build an isolated local style preview; never installs or publishes it."""
import argparse,hashlib,json,plistlib,subprocess,uuid
from pathlib import Path
from patch_binary import validate_custom_base
ROOT=Path(__file__).resolve().parents[1]
BUNDLE='local.widgetify.stylepreview.nov15'

def run(*args):subprocess.run([str(a) for a in args],check=True)
def main():
 p=argparse.ArgumentParser();p.add_argument('--base-app',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
 validate_custom_base(a.base_app/'Contents/MacOS/Widgetify')
 a.output.mkdir(parents=True,exist_ok=True);app=a.output/'Widgetify 分类预览.app'
 if app.exists():p.error('Use a fresh output folder; existing previews are never overwritten')
 run('ditto',a.base_app,app)
 info=plistlib.loads((app/'Contents/Info.plist').read_bytes());info.update(CFBundleIdentifier=BUNDLE,CFBundleDisplayName='Widgetify 分类预览',CFBundleName='Widgetify 分类预览',WidgetifyStylePreview=True)
 reference='b1'*16;modified='b2'*16;translator='b3'*16
 info['WidgetifyPreviewReferenceIDs']=[reference]
 (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
 library=Path.home()/'Library/Containers/local.widgetify.custom/Data/Library'
 layout=json.loads((library/'Application Support/Widgetify/autosaved.widgetlist4').read_bytes())
 prefs=plistlib.loads((library/'Preferences/local.widgetify.custom.plist').read_bytes())
 original=next(x for x in layout if x.get('name')=='widget_name_shortcuts')
 translation=next(x for x in layout if x.get('name')=='widget_name_translator')
 preview=[]
 for template,identifier,x,y in [(original,reference,430,869.5),(original,modified,800,869.5),(translation,translator,430,490)]:
  widget=json.loads(json.dumps(template));widget['id']=identifier;widget['isFixed']=False;widget['isPined']=False;widget['winFrame'][0]=[x,y];preview.append(widget)
 apps=prefs.get(original['id'],[])
 seedprefs={'userDidAddWidgets':True,'WWant_isGuideShowed':True,'initShortcutHasSet':True,'hoverFocus':False,'lastAcknowledgedReleaseNotesVersion':info['CFBundleShortVersionString'],'appVersion':info['CFBundleShortVersionString']}
 for k in ['appLanguage','translator_fontSizeKey','translator_fontWeightKey','WWant_widgetBackgroundStyle','WWant_theme','WWant_isPannelColor','WWant_isPannelColorForBase','WWant_isPannelColorForBg']:
  if k in prefs:seedprefs[k]=prefs[k]
 for identifier in [reference,modified]:
  seedprefs[identifier]=apps;seedprefs[identifier+'_compactIconsEnabled']=prefs.get(original['id']+'_compactIconsEnabled',True)
 # Fresh preview IDs have no per-component color override. Both use the native
 # global/default appearance; production values and categories remain untouched.
 groups=[{'id':'preview-frequent','name':'常用','apps':[v for v in apps if 'Finder.app' in v]}, {'id':'preview-work','name':'工作','apps':[]},{'id':'preview-development','name':'开发','apps':[]},{'id':'preview-entertainment','name':'娱乐','apps':[]}]
 seedprefs['custom.component.'+modified+'.launchCategories.v1']=json.dumps({'groups':groups},ensure_ascii=False).encode()
 seed={'revision':str(uuid.uuid4()),'preferences':seedprefs,'layoutData':json.dumps(preview,ensure_ascii=False).encode()}
 (app/'Contents/Resources/StylePreview.plist').write_bytes(plistlib.dumps(seed))
 framework=app/'Contents/Frameworks';context=framework/'WidgetifyContext.dylib';module=framework/'WidgetifyEnhancements.dylib'
 run('xcrun','swiftc','-target','arm64-apple-macos12.0','-emit-library','-parse-as-library',ROOT/'src/WidgetContext.swift',ROOT/'src/WaterPresentation.swift',ROOT/'src/ShortcutCategories.swift',ROOT/'src/InspirationPresentation.swift',ROOT/'src/InspirationHistory.swift','-o',context,'-Xlinker','-install_name','-Xlinker','@loader_path/WidgetifyContext.dylib')
 run('xcrun','clang','-arch','arm64','-mmacosx-version-min=12.0','-fobjc-arc','-fblocks','-dynamiclib','-framework','AppKit','-framework','UserNotifications','-framework','CoreGraphics','-framework','QuartzCore',*[ROOT/'src'/name for name in ['Enhancements.m','OriginalFolderBridge.m','ComponentIntegration.m','ComponentSettings.m','ReminderSchedule.m','DirectoryReferences.m']],context,'-o',module,'-install_name','@rpath/WidgetifyEnhancements.dylib')
 # Minimal preview permissions: private sandbox only. No shared groups, network,
 # calendar, camera, automation, external folder or production-container access.
 entitlements=a.output/'preview-entitlements.plist';entitlements.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True}))
 run('codesign','--force','--deep','--sign','-','--entitlements',entitlements,app);run('codesign','--verify','--deep','--strict',app)
 (a.output/'preview-manifest.json').write_text(json.dumps({'bundle':BUNDLE,'app':str(app.resolve()),'reference':reference,'modified':modified,'translation':translator,'scope':'Local preview only; no production configuration migration, installation or publication'},ensure_ascii=False,indent=2))
 print(app)
if __name__=='__main__':main()
