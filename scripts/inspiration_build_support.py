"""Reproducible local Git packaging and synthetic integration fixtures."""
import json
import plistlib
from pathlib import Path
import subprocess

def bundle_git(app, output, executable, source):
    executable, source = executable.resolve(), source.resolve()
    if not executable.is_file() or not source.is_file() or not (executable.parent/'COPYING').is_file():
        raise ValueError('Provide the built upstream Git executable, COPYING and source archive')
    helper = app/'Contents/MacOS/InspirationGit'
    subprocess.run(['ditto',str(executable),str(helper)],check=True)
    notices=app/'Contents/Resources/ThirdParty';notices.mkdir(exist_ok=True)
    subprocess.run(['ditto',str(executable.parent/'COPYING'),str(notices/'Git-COPYING.txt')],check=True)
    (notices/'Git-source.txt').write_text('Git 2.50.1, built from the unmodified upstream source.\nSource supplied alongside this application: git-2.50.1.tar.xz\nhttps://www.kernel.org/pub/software/scm/git/git-2.50.1.tar.xz\nBuild: make git NO_CURL=YesPlease NO_GETTEXT=YesPlease NO_TCLTK=YesPlease NO_OPENSSL=YesPlease NO_EXPAT=YesPlease CFLAGS="-O2 -mmacosx-version-min=12.0"\n')
    entitlement=output/'git-entitlements.plist'
    entitlement.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.inherit':True}))
    return helper,entitlement

def integration_seed(version):
    widgets=[]
    for n,(kind,x,y,w,h,current,sizes) in enumerate([
        ('shortcuts',430,490,344,179.5,'medium',['small','medium','large']),
        ('translator',430,100,344,359,'large',['large','xlargeOfVertical']),
        ('water',800,300,164,179.5,'small',['small','large']),
    ]):
        widgets.append({'id':('%02x'%(225+n))*16,'name':'widget_name_'+kind,'brief':'widget_brief_'+kind,'type':{kind:{}},'needPro':kind!='shortcuts','size':[{s:{}} for s in sizes],'currentSize':{current:{}},'screenID':'00000000-0000-0000-0000-000000000000','screenFrame':[[0,0],[1920,1080]],'winFrame':[[x,y],[w,h]],'isFixed':False,'isPined':False})
    return {'revision':'formal-inspiration-integration-v1','preferences':{'userDidAddWidgets':True,'WWant_isGuideShowed':True,'initShortcutHasSet':True,'hoverFocus':False,'lastAcknowledgedReleaseNotesVersion':version,'appVersion':version},'layoutData':json.dumps(widgets).encode()}
