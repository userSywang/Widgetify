#!/usr/bin/env python3
"""Publish an existing build with Git and GitHub CLI; no browser upload."""
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--repo', default='userSywang/Widgetify')
    args = parser.parse_args()
    gh = shutil.which('gh') or '/opt/homebrew/bin/gh'
    env = os.environ.copy()
    proxy = subprocess.run(['git','config','--get','http.proxy'], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    if proxy:
        env.setdefault('HTTP_PROXY', proxy)
        env.setdefault('HTTPS_PROXY', proxy)
    def run(*command, capture=False, retry=False):
        for attempt in range(3 if retry else 1):
            result = subprocess.run([str(c) for c in command], cwd=ROOT, env=env, capture_output=True, text=True)
            if result.returncode == 0:
                if not capture:
                    print(result.stdout, end='')
                    print(result.stderr, end='')
                return result
            transient = any(word in result.stderr.lower() for word in ('eof','tls','ssl','timeout','connection','502','503'))
            if not retry or not transient or attempt == 2:
                raise subprocess.CalledProcessError(result.returncode, command, output=result.stdout, stderr=result.stderr)
            print('Retrying interrupted network request.', flush=True)
            time.sleep(2)
    version = (ROOT/'VERSION').read_text().strip()
    tag = 'v'+version
    artifacts = args.artifacts.resolve()
    installer = artifacts/f'Widgetify-{version}-macOS-arm64.zip'
    info = plistlib.loads((artifacts/'Widgetify.app/Contents/Info.plist').read_bytes())
    if info['CFBundleShortVersionString'] != version or not installer.is_file():
        parser.error('Build artifacts do not match VERSION')
    if run('git','status','--porcelain',capture=True).stdout.strip():
        parser.error('Commit source changes before publishing')
    if subprocess.run([gh,'release','view',tag,'--repo',args.repo],cwd=ROOT,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode == 0:
        parser.error('Release already exists; use a new version instead of replacing history')
    source = artifacts/f'Widgetify-{version}-source.zip'
    run('git','archive','--format=zip','--prefix=Widgetify-source-'+version+'/',f'--output={source}','HEAD')
    checksums = artifacts/'SHA256SUMS.txt'
    checksums.write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in (installer,source)))
    changelog = (ROOT/'CHANGELOG.md').read_text()
    section = changelog.split('## '+tag+' — ',1)[1].split('\n',1)[1].split('\n## ',1)[0].strip()
    notes = artifacts/'release-notes.md'
    notes.write_text(section+'\n\n下载 `'+installer.name+'`，解压得到 Widgetify.app。喝水测试直接显示应用弹窗；每日弹窗需要软件保持运行。\n\n本仓库保存实际编写的增强源码与修改工具，不是原厂完整源码。仅支持 Apple 芯片；Apple 天气等开发者授权限制仍存在。\n')
    run('git','push','origin','HEAD:main',retry=True)
    existing_tag = subprocess.run(['git','rev-parse','--verify','refs/tags/'+tag],cwd=ROOT,capture_output=True,text=True)
    if existing_tag.returncode == 0:
        if existing_tag.stdout.strip() != run('git','rev-parse','HEAD',capture=True).stdout.strip():
            parser.error('Existing version tag does not match HEAD')
    else:
        run('git','tag',tag)
    run('git','push','origin',tag,retry=True)
    # Publish only after every attachment is present and verified. Upload files
    # sequentially so a dropped proxy connection can be retried independently.
    run(gh,'release','create',tag,'--repo',args.repo,'--verify-tag','--draft','--title','Widgetify '+tag,'--notes-file',notes,retry=True)
    for asset in (checksums,source,installer):
        run(gh,'release','upload',tag,asset,'--repo',args.repo,'--clobber',retry=True)
    releases = json.loads(run(gh,'api',f'repos/{args.repo}/releases?per_page=100',capture=True,retry=True).stdout)
    result = next(release for release in releases if release['tag_name'] == tag)
    assets = {a['name']:a for a in result['assets']}
    for p in (installer,source,checksums):
        asset = assets[p.name]
        if asset['state'] != 'uploaded' or asset['size'] != p.stat().st_size:
            raise RuntimeError('Uploaded asset verification failed: '+p.name)
        expected = 'sha256:'+hashlib.sha256(p.read_bytes()).hexdigest()
        if asset.get('digest') and asset['digest'] != expected:
            raise RuntimeError('SHA-256 mismatch: '+p.name)
    run(gh,'release','edit',tag,'--repo',args.repo,'--draft=false','--latest',retry=True)
    result = json.loads(run(gh,'api',f'repos/{args.repo}/releases/tags/{tag}',capture=True,retry=True).stdout)
    if result['draft']:
        raise RuntimeError('Release is still a draft')
    print('Verified release:',result['html_url'])

if __name__ == '__main__':
    main()
