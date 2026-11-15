#!/usr/bin/env python3
"""Clone a signed production candidate without recompiling its approved UI code."""
import argparse,hashlib,json,plistlib,subprocess
from pathlib import Path
from inspiration_build_support import integration_seed

def main():
 p=argparse.ArgumentParser();p.add_argument('--app',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
 info=plistlib.loads((a.app/'Contents/Info.plist').read_bytes())
 if info.get('CFBundleIdentifier')!='local.widgetify.custom' or not info.get('WidgetifyInspirationEnabled'):p.error('Use the production integration candidate')
 a.output.mkdir(parents=True,exist_ok=True);app=a.output/'Widgetify 正式接入预览.app'
 if app.exists():p.error('Use a fresh output directory')
 subprocess.run(['ditto',str(a.app),str(app)],check=True)
 info.update(CFBundleIdentifier='local.widgetify.stylepreview.integration.v0211',CFBundleName='Widgetify 正式接入预览',CFBundleDisplayName='Widgetify 正式接入预览',WidgetifyStylePreview=False,WidgetifyIntegrationTest=True,WidgetifyPreviewUseMainScreen=True)
 (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
 (app/'Contents/Resources/StylePreview.plist').write_bytes(plistlib.dumps(integration_seed(info['CFBundleShortVersionString'])))
 entitlement=a.output/'entitlements.plist';entitlement.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True}))
 subprocess.run(['codesign','--force','--sign','-','--entitlements',str(entitlement),str(app)],check=True)
 subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
 fingerprints={}
 for name in ['WidgetifyContext.dylib','WidgetifyEnhancements.dylib']:
  source=hashlib.sha256((a.app/'Contents/Frameworks'/name).read_bytes()).hexdigest();actual=hashlib.sha256((app/'Contents/Frameworks'/name).read_bytes()).hexdigest()
  if source!=actual:raise RuntimeError('Preview code differs from production')
  fingerprints[name]=source
 (a.output/'preview-manifest.json').write_text(json.dumps({'app':str(app.resolve()),'productionApp':str(a.app.resolve()),'modules':fingerprints,'isolated':True},indent=2))
 print(app)
if __name__=='__main__':main()
