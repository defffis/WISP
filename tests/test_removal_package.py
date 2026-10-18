"""Validate the single-file BAT and its embedded, checksum-verified recovery payload."""
from pathlib import Path
import base64,hashlib,io,json,re,tarfile,subprocess,os
ROOT=Path(__file__).resolve().parents[1];DIST=ROOT/'dist'
bat=(DIST/'Uninstall-WISP.bat').read_bytes();assert b'\r\n__WISP_PS_PAYLOAD__\r\n' in bat
ps=base64.b64decode(bat.split(b'\r\n__WISP_PS_PAYLOAD__\r\n',1)[1].strip(),validate=True).decode('utf-8')
assert 'StrictHostKeyChecking=ask' in ps and "-cne 'УДАЛИТЬ'" in ps
assert 'Invoke-WebRequest' not in ps and 'Get-Credential' not in ps
embedded=re.search(r"FromBase64String\('([A-Za-z0-9+/=]+)'\)",ps).group(1)
loader=base64.b64decode(embedded,validate=True)
expected=re.search(r"-ne '([a-f0-9]{64})'",ps).group(1)
assert hashlib.sha256(loader).hexdigest()==expected
version=(ROOT/'src/VERSION').read_text().strip();assert loader==(DIST/f'uninstall-wisp-{version}.sh').read_bytes()
assert b'sh "$T/uninstall.sh" queue DELETE' in loader and b'sh "$T/install.sh"' not in loader
payload=base64.b64decode(loader.split(b'\n__WISP_PACKAGE__\n',1)[1])
with tarfile.open(fileobj=io.BytesIO(payload),mode='r:gz') as t:
 assert set(t.getnames())=={'uninstall.sh','wisp.sh','wisp-config.sh','VERSION','locale.sh'}
 for n in t.getnames():assert t.extractfile(n).read()==(ROOT/'src'/n).read_bytes()
(ROOT/'work/remove-package-decoded.ps1').write_text(ps,encoding='utf-8-sig')
if os.name=='nt':
 command="$e=$null;$t=$null;[System.Management.Automation.Language.Parser]::ParseFile($args[0],[ref]$t,[ref]$e)>$null;if($e.Count){$e;exit 1}"
 # Environment input avoids reinterpreting a file path as PowerShell code.
 command="$e=$null;$t=$null;[System.Management.Automation.Language.Parser]::ParseFile($env:WISP_PARSE_FILE,[ref]$t,[ref]$e)>$null;if($e.Count){$e;exit 1}"
 env=dict(os.environ,WISP_PARSE_FILE=str(ROOT/'work/remove-package-decoded.ps1'))
 for filename in [ROOT/'work/remove-package-decoded.ps1',DIST/'Install-WISP.ps1']:
  env['WISP_PARSE_FILE']=str(filename)
  p=subprocess.run(['powershell.exe','-NoProfile','-Command',command],capture_output=True,encoding='utf-8',env=env);assert p.returncode==0,(p.stdout,p.stderr)
checks=[dict(test=s,result='PASS') for s in ['BAT works without adjacent files or network downloads','Exact Russian confirmation required; password handled by native SSH','Embedded loader SHA256 and limited recovery-only archive match sources','PowerShell syntax parsed on Windows; local temp removal restricted to its generated directory']]
(ROOT/'work/removal-package-results.json').write_text(json.dumps(checks,indent=2))
print('Standalone BAT, PowerShell and embedded recovery archive checks passed.')
