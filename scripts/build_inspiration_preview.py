#!/usr/bin/env python3
"""Build only an isolated native inspiration prototype, not an installed release."""
import argparse,json,plistlib,subprocess,uuid,datetime
from pathlib import Path
from patch_binary import validate_custom_base
ROOT=Path(__file__).resolve().parents[1]
BUNDLE='local.widgetify.stylepreview.inspiration.nov15'
def run(*args):subprocess.run([str(a) for a in args],check=True)
def main():
 p=argparse.ArgumentParser();p.add_argument('--base-app',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--git-executable',type=Path);p.add_argument('--git-source',type=Path);p.add_argument('--public',action='store_true',help='Use synthetic layouts and defaults; never read local settings or records');a=p.parse_args()
 if a.public and (not a.git_executable or not a.git_source):p.error('Public previews require a reproducible Git executable and its source archive')
 bundle='local.widgetify.stylepreview.inspiration.public' if a.public else BUNDLE
 validate_custom_base(a.base_app/'Contents/MacOS/Widgetify');a.output.mkdir(parents=True,exist_ok=True)
 app=a.output/'Widgetify 灵感预览.app'
 if app.exists():p.error('Choose a fresh output directory')
 run('ditto',a.base_app,app)
 info=plistlib.loads((app/'Contents/Info.plist').read_bytes());reference='c1'*16;idea='c2'*16;translator='c3'*16;water_id='c4'*16
 info.update(CFBundleIdentifier=bundle,CFBundleDisplayName='Widgetify 灵感预览',CFBundleName='Widgetify 灵感预览',WidgetifyStylePreview=True,WidgetifyPreviewUseMainScreen=a.public,WidgetifyPreviewReferenceIDs=[reference],WidgetifyInspirationPreviewIDs=[idea],WidgetifyWaterPreviewID=water_id)
 (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
 if a.public:
  def template(kind,sizes,current,frame):
   return {'name':'widget_name_'+kind,'brief':'widget_brief_'+kind,'type':{kind:{}},'id':'0'*32,'size':[{size:{}} for size in sizes],'currentSize':{current:{}},'winFrame':[[0,0],frame],'screenFrame':[[0,0],[1920,1080]],'screenID':'00000000-0000-0000-0000-000000000000','isFixed':False,'isPined':False,'needPro':kind!='shortcuts'}
  layout=[template('shortcuts',['small','medium','large','xlargeOfVertical','xlargeOfHorizontal'],'medium',[344,179.5]),template('water',['small','large'],'small',[164,179.5]),template('translator',['large','xlargeOfVertical'],'large',[344,359])]
  prefs={}
 else:
  lib=Path.home()/'Library/Containers/local.widgetify.custom/Data/Library'
  layout=json.loads((lib/'Application Support/Widgetify/autosaved.widgetlist4').read_bytes());prefs=plistlib.loads((lib/'Preferences/local.widgetify.custom.plist').read_bytes())
 water=next(x for x in layout if 'water' in x.get('name','').lower())
 shortcut=next(x for x in layout if x.get('name')=='widget_name_shortcuts');translation=next(x for x in layout if x.get('name')=='widget_name_translator')
 preview=[]
 for template,identifier,x,y in [(shortcut,reference,430,490),(translation,translator,430,690),(shortcut,idea,800,690),(water,water_id,800,300)]:
  widget=json.loads(json.dumps(template));widget.update(id=identifier,isFixed=False,isPined=False)
  widget['winFrame'][0]=[x,y]
  if identifier==idea:widget['currentSize']={'large':{}};widget['winFrame'][1]=[344,359]
  preview.append(widget)
 seedprefs={'userDidAddWidgets':True,'WWant_isGuideShowed':True,'initShortcutHasSet':True,'hoverFocus':False,'lastAcknowledgedReleaseNotesVersion':info['CFBundleShortVersionString'],'appVersion':info['CFBundleShortVersionString']}
 for key in ['appLanguage','WWant_widgetBackgroundStyle','WWant_theme','WWant_isPannelColor','WWant_isPannelColorForBase','WWant_isPannelColorForBg']:
  if key in prefs:seedprefs[key]=prefs[key]
 for identifier in [reference,idea]:seedprefs[identifier]=prefs.get(shortcut['id'],[]);seedprefs[identifier+'_compactIconsEnabled']=True
 for key,value in prefs.items():
  if water['id'] in key:seedprefs[key.replace(water['id'],water_id)]=value
 seed={'revision':'inspiration-public-v3' if a.public else 'inspiration-private-water-v2','preferences':seedprefs,'layoutData':json.dumps(preview,ensure_ascii=False).encode()}
 (app/'Contents/Resources/StylePreview.plist').write_bytes(plistlib.dumps(seed))
 def date(day):return (datetime.datetime(2026,11,day,1,40,tzinfo=datetime.timezone.utc)-datetime.datetime(2001,1,1,tzinfo=datetime.timezone.utc)).total_seconds()
 samples=[{'id':'sample-reminder','text':'如果把一次提醒，变成一次小小的互动？','context':'喝水提醒不只报时，也能给人一点期待。','tag':'产品','createdAt':date(12),'additions':[],'archived':False},{'id':'sample-space','text':'给桌面留一点空白，让重要的东西更容易被看见。','context':'不是每一处空间都需要被填满。','tag':'设计','createdAt':date(11),'additions':[],'archived':False},{'id':'sample-opening','text':'给新项目写一个有记忆点的开场。','context':'从一个具体的小问题开始讲。','tag':'表达','createdAt':date(10),'additions':[],'archived':False}]
 (app/'Contents/Resources/InspirationSample.json').write_text(json.dumps(samples,ensure_ascii=False))
 context=app/'Contents/Frameworks/WidgetifyContext.dylib';module=app/'Contents/Frameworks/WidgetifyEnhancements.dylib'
 run('xcrun','swiftc','-target','arm64-apple-macos12.0','-emit-library','-parse-as-library',*[ROOT/'src'/name for name in ['WidgetContext.swift','WaterPresentation.swift','ShortcutCategories.swift','InspirationPresentation.swift','InspirationHistory.swift','InspirationNotion.swift','InspirationIntegration.swift']],'-o',context,'-Xlinker','-install_name','-Xlinker','@loader_path/WidgetifyContext.dylib')
 run('xcrun','clang','-arch','arm64','-mmacosx-version-min=12.0','-fobjc-arc','-fblocks','-dynamiclib','-framework','AppKit','-framework','UserNotifications','-framework','CoreGraphics','-framework','QuartzCore',*[ROOT/'src'/name for name in ['Enhancements.m','OriginalFolderBridge.m','ComponentIntegration.m','ComponentSettings.m','ReminderSchedule.m','DirectoryReferences.m']],context,'-o',module,'-install_name','@rpath/WidgetifyEnhancements.dylib')
 git=a.git_executable.resolve() if a.git_executable else Path(subprocess.check_output(['xcrun','--find','git'],text=True).strip()).resolve()
 helper=app/'Contents/MacOS/InspirationGit';run('ditto',git,helper)
 if a.public:
  notices=app/'Contents/Resources/ThirdParty';notices.mkdir(exist_ok=True)
  run('ditto',git.parent/'COPYING',notices/'Git-COPYING.txt')
  (notices/'Git-source.txt').write_text('Git 2.50.1, built from the unmodified upstream source.\nSource archive supplied with this release: git-2.50.1.tar.xz\nhttps://www.kernel.org/pub/software/scm/git/git-2.50.1.tar.xz\nBuild: make git NO_CURL=YesPlease NO_GETTEXT=YesPlease NO_TCLTK=YesPlease NO_OPENSSL=YesPlease NO_EXPAT=YesPlease CFLAGS="-O2 -mmacosx-version-min=12.0"\n')
 child_entitlements=a.output/'git-entitlements.plist';child_entitlements.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.inherit':True}))
 entitlements=a.output/'preview-entitlements.plist';entitlements.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True}))
 run('codesign','--force','--deep','--sign','-','--entitlements',entitlements,app);run('codesign','--force','--sign','-','--entitlements',child_entitlements,helper);run('codesign','--force','--sign','-','--entitlements',entitlements,app);run('codesign','--verify','--deep','--strict',app)
 (a.output/'preview-manifest.json').write_text(json.dumps({'bundle':bundle,'app':str(app.resolve()),'ideaWidgetID':idea,'scope':'Native-hosted isolated prototype, not a registered production widget'},ensure_ascii=False,indent=2))
 print(app)
if __name__=='__main__':main()
