from pathlib import Path
import base64,hashlib,io,json,os,shutil,subprocess,tarfile,zipfile
ROOT=Path(__file__).resolve().parents[1]
SRC=ROOT/'src';OUT=ROOT/'dist';OUT.mkdir(exist_ok=True)
VERSION=(SRC/'VERSION').read_text(encoding='ascii').strip()
BASH=(str(Path(os.environ.get('ProgramFiles','C:/Program Files'))/'Git/bin/bash.exe') if os.name=='nt' else shutil.which('bash'))
NAMES=['wisp.sh','wisp-config.sh','panel.sh','api.sh','clients.sh','service.sh','install.sh','uninstall.sh','nginx.conf.in','VERSION','web/index.html','web/app.js','web/style.css','web/locale.js','locale.sh','locales/ru/locale.js','locales/ru/locale.sh','locales/en/locale.js','locales/en/locale.sh']
for n in NAMES:
 data=(SRC/n).read_bytes();assert b'\r' not in data and not data.startswith(b'\xef\xbb\xbf')
 if n.endswith('.sh'):subprocess.run([BASH,'-n',str(SRC/n)],check=True)
subprocess.run(['node','--check',str(SRC/'web/app.js')],check=True)
sums=''.join(f'{hashlib.sha256((SRC/n).read_bytes()).hexdigest()}  {n}\n' for n in NAMES).encode()
(SRC/'SHA256SUMS').write_bytes(sums)
archive=OUT/f'wisp-{VERSION}.tar.gz'
with tarfile.open(archive,'w:gz') as t:
 for n in NAMES+['SHA256SUMS']:
  data=sums if n=='SHA256SUMS' else (SRC/n).read_bytes()
  info=tarfile.TarInfo(n);info.size=len(data);info.mode=0o755 if n.endswith('.sh') else 0o644;info.mtime=0;t.addfile(info,io.BytesIO(data))
loader='''#!/bin/sh
set -eu
umask 077
T=$(mktemp -d /tmp/wisp-package.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM
N=$(awk '/^__WISP_PACKAGE__$/ {print NR+1;exit}' "$0")
tail -n +"$N" "$0" | base64 -d > "$T/p.tar.gz"
printf '%s  %s\\n' '__HASH__' "$T/p.tar.gz" | sha256sum -c -
tar -xzf "$T/p.tar.gz" -C "$T"
sh "$T/install.sh" "$@"
exit 0
__WISP_PACKAGE__
'''.replace('__HASH__',hashlib.sha256(archive.read_bytes()).hexdigest())
b64=base64.b64encode(archive.read_bytes()).decode()
installer=OUT/f'install-wisp-{VERSION}.sh'
installer.write_text(loader+'\n'.join(b64[i:i+76] for i in range(0,len(b64),76))+'\n',encoding='ascii',newline='\n')
subprocess.run([BASH,'-n',str(installer)],check=True)
# Standalone uninstaller carries only recovery code and runs from RAM.
remove_tar=io.BytesIO()
with tarfile.open(fileobj=remove_tar,mode='w:gz') as t:
 for n in ['uninstall.sh','wisp.sh','wisp-config.sh','VERSION','locale.sh']:
  data=(SRC/n).read_bytes();info=tarfile.TarInfo(n);info.size=len(data);info.mode=0o700;info.mtime=0;t.addfile(info,io.BytesIO(data))
remove_bytes=remove_tar.getvalue()
remove_loader=loader.replace(hashlib.sha256(archive.read_bytes()).hexdigest(),hashlib.sha256(remove_bytes).hexdigest()).replace('sh "$T/install.sh" "$@"','sh "$T/uninstall.sh" queue DELETE')
remove_b64=base64.b64encode(remove_bytes).decode()
remover=OUT/f'uninstall-wisp-{VERSION}.sh'
remover.write_text(remove_loader+'\n'.join(remove_b64[i:i+76] for i in range(0,len(remove_b64),76))+'\n',encoding='ascii',newline='\n')
subprocess.run([BASH,'-n',str(remover)],check=True)
remove_ps=(ROOT/'windows/Uninstall-WISP.ps1.in').read_text(encoding='utf-8-sig').replace('__VERSION__',VERSION).replace('__REMOVER_BASE64__',base64.b64encode(remover.read_bytes()).decode()).replace('__REMOVER_HASH__',hashlib.sha256(remover.read_bytes()).hexdigest())
remove_ps64=base64.b64encode(remove_ps.encode('utf-8')).decode()
# The BAT is self-contained. No adjacent PS1, download, token or saved password is needed.
remove_bat='@echo off\nchcp 65001 >nul\nsetlocal\nset "WISP_REMOVE_BAT=%~f0"\npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$data=[IO.File]::ReadAllText($env:WISP_REMOVE_BAT); $part=($data -split \'__WISP_PS_PAYLOAD__\\r?\\n\',2)[1]; & ([ScriptBlock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part.Trim()))))"\nset "removeResult=%ERRORLEVEL%"\npause\nexit /b %removeResult%\n__WISP_PS_PAYLOAD__\n'+remove_ps64+'\n'
(OUT/'Uninstall-WISP.bat').write_text(remove_bat,encoding='ascii',newline='\r\n')
ps=(ROOT/'windows/Install-WISP.ps1.in').read_text(encoding='utf-8-sig').replace('__VERSION__',VERSION).replace('__INSTALLER_HASH__',hashlib.sha256(installer.read_bytes()).hexdigest())
(OUT/'Install-WISP.ps1').write_text(ps,encoding='utf-8-sig',newline='\r\n')
shutil.copyfile(ROOT/'windows/Install-WISP.bat',OUT/'Install-WISP.bat')
# Empty host database: SSH asks before trusting a new router, and refuses changed keys.
(OUT/'wisp-installer-known-hosts.txt').write_bytes(b'')
shutil.copyfile(ROOT/'README.md',OUT/f'wisp-{VERSION}-README.md')
shutil.copyfile(ROOT/'README.ru.md',OUT/'README.ru.md')
with zipfile.ZipFile(OUT/f'WISP-{VERSION}-Windows-installer.zip','w',compression=zipfile.ZIP_DEFLATED) as z:
 for n in ['Install-WISP.bat','Install-WISP.ps1',installer.name,'Uninstall-WISP.bat','wisp-installer-known-hosts.txt',f'wisp-{VERSION}-README.md','README.ru.md']:z.write(OUT/n,n)
checks=json.loads((ROOT/'work/test-results.json').read_text(encoding='utf-8'))
assert all(c['result']=='PASS' for c in checks)
report={'version':VERSION,'local_checks':checks,'shell_and_javascript_syntax':'PASS','hardware':'See docs/hardware-tests.md; no reboot claimed'}
(OUT/f'wisp-{VERSION}-validation.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
files=[p for p in OUT.iterdir() if p.is_file() and p.stat().st_size and p.name!='SHA256SUMS.txt']
(OUT/'SHA256SUMS.txt').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in sorted(files)),encoding='ascii')
print(f'Built {VERSION} release assets.')
