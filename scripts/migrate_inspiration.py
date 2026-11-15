#!/usr/bin/env python3
"""Copy local notes and their independent Git history, never overwrite live notes."""
import argparse
import configparser
import hashlib
import json
import math
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


def fingerprint(directory):
    digest=hashlib.sha256()
    for path in sorted(directory.rglob('*')):
        if path.is_symlink():raise ValueError('Symbolic links are not accepted in a private record migration')
        if path.is_file():
            digest.update(str(path.relative_to(directory)).encode());digest.update(b'\0');digest.update(path.read_bytes())
        elif not path.is_dir():raise ValueError('Unsupported file type in private records')
    return digest.hexdigest()


def validate(directory):
    if directory.is_symlink() or not directory.is_dir():raise ValueError('Choose a real local inspiration directory')
    fingerprint(directory)
    document=json.loads((directory/'ideas-v1.json').read_text())
    if type(document.get('version')) is not int or document['version']!=1 or not isinstance(document.get('entries'),list):raise ValueError('Unsupported record format')
    def timestamp(value):return type(value) in (int,float) and math.isfinite(value)
    ids=[]
    for entry in document['entries']:
        if not isinstance(entry,dict) or any(not isinstance(entry.get(k),str) for k in ['id','text','context','tag']) or not entry['id'] or type(entry.get('archived')) is not bool or not timestamp(entry.get('createdAt')) or not isinstance(entry.get('additions'),list):raise ValueError('Invalid inspiration record')
        additions=[]
        for addition in entry['additions']:
            if not isinstance(addition,dict) or not isinstance(addition.get('id'),str) or not addition['id'] or not isinstance(addition.get('text'),str) or not timestamp(addition.get('createdAt')):raise ValueError('Invalid inspiration addition')
            additions.append(addition['id'])
        if len(set(additions))!=len(additions):raise ValueError('Duplicate addition IDs')
        ids.append(entry['id'])
    if len(set(ids))!=len(ids):raise ValueError('Duplicate record IDs must be resolved before migration')
    draft=document.get('draft')
    if not isinstance(draft,dict) or any(not isinstance(draft.get(k),str) for k in ['text','tag']):raise ValueError('Invalid draft')
    if document.get('selectedID') is not None and not isinstance(document['selectedID'],str):raise ValueError('Invalid selection')
    supplements=document.get('supplementDrafts')
    if supplements is not None and (not isinstance(supplements,dict) or any(not isinstance(k,str) or not isinstance(v,str) for k,v in supplements.items())):raise ValueError('Invalid supplement drafts')
    history=directory/'LocalHistory'
    if history.exists():
        if (history/'.inspiration-local-history').read_text()!='Inspiration local history v1\n':raise ValueError('Unrecognized history repository')
        if not (history/'.git').is_dir() or any((history/'.git'/name).exists() for name in ['commondir','objects/info/alternates','objects/info/http-alternates']):raise ValueError('History must be an independent local repository')
        if list((history/'.git').rglob('*.lock')):raise ValueError('History is busy; close the preview and retry')
        config=configparser.ConfigParser(strict=False);config.read(history/'.git/config')
        if any(section.lower().startswith(('remote ','include')) for section in config.sections()):raise ValueError('Migration accepts local history without remotes or external config includes')
        if config.has_option('core','worktree') or config.getboolean('core','bare',fallback=False):raise ValueError('History must have its own local work tree')
        env={k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
        env.update(GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_TERMINAL_PROMPT='0')
        subprocess.run(['/usr/bin/git','--no-optional-locks','-C',str(history),'-c','core.hooksPath=/dev/null','-c','core.fsmonitor=false','fsck','--no-dangling'],env=env,check=True,capture_output=True,timeout=30)
    return document


def empty_target(directory):
    if not directory.exists():return True
    if directory.is_symlink() or not directory.is_dir():return False
    names={p.name for p in directory.iterdir()}
    if not names:return True
    if names!={'ideas-v1.json'}:return False
    d=json.loads((directory/'ideas-v1.json').read_text())
    return d.get('version')==1 and d.get('entries')==[] and not d.get('draft',{}).get('text') and not d.get('draft',{}).get('tag') and not d.get('supplementDrafts')


def migrate(source,target):
    if source.is_symlink() or target.is_symlink():raise ValueError('Directory links are not accepted')
    source,target=source.resolve(),target.absolute()
    if source==target or source in target.parents or target in source.parents:raise ValueError('Source and destination must be separate directories')
    document=validate(source);before=fingerprint(source)
    marker=target/'.migration-v1.json'
    if marker.exists() and json.loads(marker.read_text()).get('sourceFingerprint')==before:return {'status':'already-migrated','entries':len(document['entries'])}
    if not empty_target(target):raise ValueError('Destination contains records; nothing was overwritten')
    target.parent.mkdir(parents=True,exist_ok=True)
    staging=Path(tempfile.mkdtemp(prefix='.inspiration-migration-',dir=target.parent))
    backup=None
    try:
        shutil.copytree(source,staging,dirs_exist_ok=True)
        if fingerprint(staging)!=before or fingerprint(source)!=before:raise ValueError('Source changed during migration; close the preview and retry')
        validate(staging)
        (staging/'.migration-v1.json').write_text(json.dumps({'version':1,'sourceFingerprint':before,'entries':len(document['entries'])}))
        for path in [staging]+list(staging.rglob('*')):path.chmod(0o700 if path.is_dir() else 0o600)
        if target.exists():
            backup=Path(tempfile.mkdtemp(prefix='Inspiration-empty-before-import-',dir=target.parent));backup.rmdir();target.rename(backup)
        try:staging.rename(target)
        except Exception:
            if backup is not None:backup.rename(target)
            raise
    finally:
        if staging.exists():shutil.rmtree(staging)
    return {'status':'migrated','entries':len(document['entries']),'historyPreserved':(target/'LocalHistory/.git').is_dir()}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True);p.add_argument('--target',type=Path,required=True);p.add_argument('--apply',action='store_true');a=p.parse_args()
    if a.apply:print(json.dumps(migrate(a.source,a.target),ensure_ascii=False))
    else:
        d=validate(a.source);print(json.dumps({'entries':len(d['entries']),'targetEmpty':empty_target(a.target),'willApply':False},ensure_ascii=False))
