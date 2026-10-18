"""Status/action contract with private state files and no network commands."""
import json, os, shutil, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASH = str(Path(os.environ.get('ProgramFiles','C:/Program Files'))/'Git/bin/bash.exe') if os.name=='nt' else shutil.which('bash')

def unix(path):
    s=path.as_posix()
    return '/'+s[0].lower()+s[2:] if os.name=='nt' else s

with tempfile.TemporaryDirectory(dir=ROOT) as td:
    t=Path(td);base=t/'base';run=t/'run';base.mkdir();run.mkdir()
    for name in ['VERSION','wisp-config.sh','locale.sh']: shutil.copyfile(ROOT/'src'/name,base/name)
    core=(ROOT/'src/wisp.sh').read_text(encoding='utf-8').replace('BASE=/data/usr/app/wisp','BASE='+unix(base)).replace('RUN=/tmp/wisp','RUN='+unix(run))
    marker='[ "${WISP_LIBRARY:-0}" != 1 ] || return 0'
    mocks='''
now() { echo 100; }
bootid() { echo boot; }
alive() { [ "$1" = 42 ]; }
preflight() { [ ! -f "$BASE/deny" ] || { fail pending_uci_changes; return 1; }; }
start() { echo called > "$BASE/start-called"; }
flock() { return 0; }
'''
    core=core.replace(marker,mocks+'\n'+marker)
    (base/'wisp.sh').write_text(core,encoding='utf-8',newline='\n')
    panel=(ROOT/'src/panel.sh').read_text(encoding='utf-8').replace('BASE=/data/usr/app/wisp','BASE='+unix(base))
    (t/'panel.sh').write_text(panel,encoding='utf-8',newline='\n')
    def state(**fields):
        for k,v in fields.items(): (run/k).write_text(str(v),encoding='ascii')
    def call(op='status',host='192.168.1.26:8088',peer='192.168.1.3'):
        env=dict(os.environ,HTTP_HOST=host,REMOTE_ADDR=peer)
        result=subprocess.run([BASH,str(t/'panel.sh'),op],capture_output=True,encoding='utf-8',env=env,timeout=10)
        assert result.returncode==0,(result.stdout,result.stderr)
        return json.loads(result.stdout)
    state(phase='ROLLED_BACK',test_end=999,token='a'*32,reason='manual')
    j=call();assert j['remaining']==0 and j['transaction']=='' and j['persistent'] is False
    assert j['version']==(ROOT/'src/VERSION').read_text().strip() and j['reason_message'] and not j['can_confirm']
    state(phase='malicious"phase')
    assert call()['phase']=='UNKNOWN'
    state(phase='PENDING',deadline=280,boot='boot',guard=42)
    j=call();assert j['remaining']==180 and not j['can_confirm'] and len(j['transaction'])==32
    assert call(host='192.168.50.1:8443',peer='192.168.50.2')['can_confirm']
    assert not call(host='192.168.50.1:8443',peer='10.0.0.2')['can_confirm']
    state(deadline=99)
    j=call(host='192.168.50.1:8443',peer='192.168.50.2');assert not j['can_confirm'] and not j['transaction']
    state(phase='ROLLED_BACK')
    sentinel=run/'retain';sentinel.write_text('state')
    assert call('check')['ok'] and sentinel.exists() and not (base/'start-called').exists()
    (base/'deny').touch();j=call('check');assert not j['ok'] and 'настройки' in j['msg'];(base/'deny').unlink()
    state(phase='ACTIVE')
    assert not call('start')['ok'] and not (base/'start-called').exists()
    assert not call('nonsense')['ok']

    (base/'clients.sh').write_text('printf \'%s\\n\' \'{"phase":"RUNNING","requested":2,"failed":0}\'\n',encoding='utf-8',newline='\n')
    assert call()['clients']==dict(phase='RUNNING',requested=2,failed=0)
    (base/'remove-error').touch();assert call()['remove_error']
    (base/'removing').touch();assert call()['phase']=='REMOVING'
    assert not call('start')['ok'] and not (base/'start-called').exists()

checks=[dict(test=s,result='PASS') for s in [
    'Idle JSON, no stale countdown/token, boolean persistence',
    'Unknown phase cannot inject JSON',
    'Confirmation gated by current boot, live guard, time and new LAN',
    'Check is read-only and preserves the previous journal',
    'Action errors are localized without exposing command output',
    'Concurrent-state start and unknown operations rejected',
    'Client task status is included without initiating reconnect',
    'Removal progress/error is visible and other actions are blocked']]
(ROOT/'work/panel-results.json').write_text(json.dumps(checks,indent=2),encoding='utf-8')
print(f'{len(checks)} isolated panel contract checks passed.')
