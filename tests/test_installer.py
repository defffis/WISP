"""Installer lifecycle in disposable paths with system/network commands replaced."""
from pathlib import Path
import tempfile,subprocess,json,shutil,os
root=Path(__file__).resolve().parents[1];src=root/'src';out=root/'dist';version=(src/'VERSION').read_text().strip();bash=str(Path(os.environ.get('ProgramFiles','C:/Program Files'))/'Git/bin/bash.exe') if os.name=='nt' else shutil.which('bash')
def unix(p):
 s=p.as_posix();return '/'+s[0].lower()+s[2:] if os.name=='nt' else s
with tempfile.TemporaryDirectory(dir=root) as td:
 t=Path(td);en=t/'external-app';base=t/'addon';base.mkdir();(t/'shadow').write_text('root:$1$fixture$hash:0:0:0:0:0:0:0\n')
 originalcron='*/1 * * * * /usr/sbin/wifiap_mode.sh check_gw\n0 5 * * * harmless\n';(t/'cron').write_text(originalcron)
 def transform(s):
  for a,b in [('BASE=/data/usr/app/wisp','BASE='+unix(base)),('EN=/data/usr/app/external-app','EN='+unix(en)),('RUN=/tmp/wisp','RUN='+unix(t/'journal')),('/etc/crontabs/root',unix(t/'cron')),('/data/usr/app/*',unix(t/'apps')+'/*'),('/etc/shadow',unix(t/'shadow')),('touch /etc/crontabs','touch '+unix(t/'cron'))]:s=s.replace(a,b)
  s=s.replace('HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)','HERE='+unix(src))
  s=s.replace('"$BASE/service.sh" stop',':').replace('"$BASE/service.sh" ensure',':')
  s='flock() { return 0; }; id() { echo 0; }; uci() { case "$*" in *HARDWARE) echo RN02;; *ROM) echo 1.0.64;; esac; }; df() { echo "mock 10000 0 10000 0% /data"; }; command() { case "$*" in "-v "*) return 0;; *) builtin command "$@";; esac; }; ip() { echo "inet 192.168.1.26/24 scope global"; }\n'+s
  s=s.replace(' openssl req -x509', ' # openssl req -x509')
  s=s.replace(' cp "$T/tls.key"', ' echo fixture > "$T/tls.key"; echo fixture > "$T/tls.crt"\n cp "$T/tls.key"')
  return s
 for n,language in enumerate(["ru","en"]):
  f=t/'install.sh';f.write_text(transform((src/'install.sh').read_text()),newline='\n')
  result=subprocess.run([bash,str(f),language],capture_output=True,text=True);assert result.returncode==0,(result.stdout,result.stderr)
  cron=(t/'cron').read_text();assert cron.count('service.sh ensure')==1 and cron.count('wisp.sh tick')==1 and cron.count('vendor-check')==1 and '0 5 * * * harmless' in cron
  assert (base/'language').read_text().strip()==language
  assert (base/'locale.sh').read_bytes()==(src/'locales'/language/'locale.sh').read_bytes()
  assert (base/'web/locale.js').read_bytes()==(src/'locales'/language/'locale.js').read_bytes()
  assert not (base/'locales').exists()
  assert not (base/'enabled').exists() and (base/'web/app.js').is_file() and (base/'install-backup.tgz').stat().st_size>0
 # A second deployment must be rejected without touching this installation.
 other=t/'apps/another-wisp';other.mkdir(parents=True)
 for name in ['wisp.sh','wisp-config.sh','VERSION']:(other/name).write_text('fixture')
 before=(base/'wisp.sh').read_bytes()
 result=subprocess.run([bash,str(f),'en'],capture_output=True,text=True)
 assert result.returncode!=0 and (base/'wisp.sh').read_bytes()==before
 shutil.rmtree(other)
 (base/'enabled').touch();before=(base/'wisp.sh').read_bytes()
 result=subprocess.run([bash,str(f),language],capture_output=True,text=True);assert result.returncode!=0 and (base/'wisp.sh').read_bytes()==before
 (base/'enabled').unlink()
 # A direct uninstall invocation defaults to a read-only plan.
 f.write_text(transform((src/'uninstall.sh').read_text(encoding='utf-8')),encoding='utf-8',newline='\n')
 result=subprocess.run([bash,str(f)],capture_output=True,encoding='utf-8');assert result.returncode==0,(result.stdout,result.stderr)
 assert json.loads(result.stdout)['dry_run'] and 'service.sh ensure' in (t/'cron').read_text()

p=out/f'wisp-{version}-validation.json';j=json.loads(p.read_text(encoding='utf-8'));j['installer_simulation']='PASS: clean install, RU/EN selected pack only, repeat install, active upgrade refusal, default removal dry-run; full removal covered by isolated remover scenarios';p.write_text(json.dumps(j,ensure_ascii=False,indent=2),encoding='utf-8')
print('Isolated install/migrate/reinstall/active-refusal/removal-plan checks passed.')
