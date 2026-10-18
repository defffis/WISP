"""Service preflight fails closed before launching a server, in disposable paths."""
import os,shutil,subprocess,tempfile,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BASH=str(Path(os.environ.get('ProgramFiles','C:/Program Files'))/'Git/bin/bash.exe') if os.name=='nt' else shutil.which('bash')
def unix(p):
 s=p.as_posix();return '/'+s[0].lower()+s[2:] if os.name=='nt' else s
results=[]
with tempfile.TemporaryDirectory(dir=ROOT/'work') as td:
 t=Path(td);base=t/'base';run=t/'run';base.mkdir()
 source=(ROOT/'src/service.sh').read_text().replace('BASE=/data/usr/app/wisp','BASE='+unix(base)).replace('WEBRUN=/tmp/wisp-panel','WEBRUN='+unix(run)).replace('/etc/shadow',unix(t/'shadow'))
 source=source.replace('/usr/sbin/nginx','test_nginx')
 for name,shadow,address in [('empty password','root::0:0:0','192.168.50.1'),('locked password','root:!$1$hash:0:0','192.168.50.1'),('absent account','other:$1$hash:0:0','192.168.50.1'),('multiple LAN IPs','root:$1$hash:0:0','192.168.50.1\n192.168.1.26'),('missing TLS key','root:$1$hash:0:0','192.168.50.1')]:
  (t/'shadow').write_text(shadow)
  mock='flock() { :; }; ip() { printf \'%s\\n\' '+ ' '.join("'inet "+ip+"/24 scope global'" for ip in address.splitlines())+'; }; test_nginx() { echo launched > "'+unix(t/'launched')+'"; }\n'
  f=t/'test.sh';f.write_text(mock+source,newline='\n');p=subprocess.run([BASH,str(f),'ensure'],capture_output=True,text=True)
  assert p.returncode!=0 and not (t/'launched').exists(),(name,p.stdout,p.stderr)
  results.append(dict(test='Fail closed: '+name,result='PASS'))
(ROOT/'work/service-results.json').write_text(json.dumps(results,indent=2))
print(f'{len(results)} isolated service fail-closed checks passed.')
