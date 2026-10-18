"""Exercise the production remover against isolated directories and command fixtures."""
from pathlib import Path
import os,shutil,subprocess,json,tempfile
ROOT=Path(__file__).resolve().parents[1]
BASH=str(Path(os.environ.get('ProgramFiles','C:/Program Files'))/'Git/bin/bash.exe') if os.name=='nt' else shutil.which('bash')
def unix(p):
 s=p.as_posix();return '/'+s[0].lower()+s[2:] if os.name=='nt' else s
result=subprocess.run([BASH,str(ROOT/'tests/test_remove.sh'),unix(ROOT/'src/uninstall.sh')],capture_output=True,encoding='utf-8',timeout=90 if os.name=='nt' else 25)
assert result.returncode==0,(result.stdout,result.stderr)
checks=[dict(test=s[5:],result='PASS') for s in result.stdout.splitlines() if s.startswith('PASS ')]
assert len(checks)>=18
for args in [[],['queue']]:
 p=subprocess.run([BASH,str(ROOT/'src/uninstall.sh'),*args],capture_output=True,encoding='utf-8',timeout=5)
 if not args:assert p.returncode==0 and json.loads(p.stdout)['dry_run']
 else:assert p.returncode!=0 and json.loads(p.stdout)['ok'] is False
checks.append(dict(test='Default is dry-run; queue without explicit DELETE is rejected',result='PASS'))

(ROOT/'work/remove-results.json').write_text(json.dumps(checks,indent=2),encoding='utf-8')
print(result.stdout.strip());print('Default dry-run and explicit confirmation passed.')
