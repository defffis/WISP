"""Client reconnect logic with fake AP sockets/commands and real state files."""
from pathlib import Path
import os,subprocess,tempfile,shutil,json
ROOT=Path(__file__).resolve().parents[1]
BASH=str(Path(os.environ.get('ProgramFiles','C:/Program Files'))/'Git/bin/bash.exe') if os.name=='nt' else shutil.which('bash')
def unix(p):
 s=p.as_posix();return '/'+s[0].lower()+s[2:] if os.name=='nt' else s
checks=[]
with tempfile.TemporaryDirectory(dir=ROOT/'work') as td:
 t=Path(td);base=t/'base';run=t/'run';base.mkdir();run.mkdir()
 for n in ['wisp-config.sh','VERSION','locale.sh']:shutil.copyfile(ROOT/'src'/n,base/n)
 core=(ROOT/'src/wisp.sh').read_text().replace('BASE=/data/usr/app/wisp','BASE='+unix(base)).replace('RUN=/tmp/wisp','RUN='+unix(run))
 (base/'wisp.sh').write_text(core,newline='\n')
 source=(ROOT/'src/clients.sh').read_text(encoding='utf-8').split('[ "${CLIENTS_LIBRARY:-0}" != 1 ]')[0].replace('BASE=/data/usr/app/wisp','BASE='+unix(base))
 def case(name,body):
  for p in run.iterdir():p.unlink()
  (base/'trace').unlink(missing_ok=True)
  setup='''
now() { echo 100; }; bootid() { echo fixture-boot; }; alive() { [ "$1" = 42 ]; }; healthy() { return 0; }
write boot fixture-boot; write guard 42; write phase ACTIVE
TRACE="$BASE/trace"
ap_available() { return 0; }; timeout() { shift; "$@"; }
hostapd_cli() {
 echo "$*" >> "$TRACE"
 case " $* " in *' list_sta '*) printf 'aa:bb:cc:dd:ee:ff\\ninvalid;reboot\\n';; *) echo OK;; esac
}
'''
  f=t/'test.sh';f.write_text(source+setup+body,encoding='utf-8',newline='\n')
  p=subprocess.run([BASH,str(f)],capture_output=True,encoding='utf-8',timeout=10);assert p.returncode==0,(name,p.stdout,p.stderr);checks.append(dict(test=name,result='PASS'))
 case('Dry-run counts valid stations on both LAN APs, no deauthentication', '''
set -e
CLIENT_PLAN=1 client_walk
[ "$SEEN" = 2 ]; [ "$DONE" = 0 ]; ! grep -q deauthenticate "$TRACE"
! grep -q wl02 "$TRACE"
''')
 case('Reconnect only validated Wi-Fi clients, no uplink or wired command', '''
set -e
client_walk
[ "$DONE" = 2 ] && [ "$ERRORS" = 0 ]
grep -q 'wl1 deauthenticate aa:bb:cc:dd:ee:ff reason=3' "$TRACE"
grep -q 'wl0 deauthenticate aa:bb:cc:dd:ee:ff reason=3' "$TRACE"
! grep -Eq 'wl02|ip link|brctl|dnsmasq|invalid;reboot' "$TRACE"
''')
 case('Inactive WISP refuses queue before any AP operation', '''
set -e
write phase PENDING
! client_ready
client_queue > "$BASE/result"
grep -q '"ok":false' "$BASE/result"
[ ! -e "$TRACE" ]
''')
 for phase in ['OFF','ROLLED_BACK','ABORTED','']:
  case('Reconnect supported in repeater state '+repr(phase), 'set -e\nwrite phase "'+phase+'"\nwrite guard 0\nclient_ready\nclient_walk\n[ "$DONE" = 2 ]\n')
 case('Deletion or state transition aborts further client disruption', '''
set -e
write phase ROLLING_BACK
! client_walk
[ "$DONE" = 0 ]
! grep -q deauthenticate "$TRACE"
''')
 case('AP command failures are counted, never reported as full success', '''
set -e
hostapd_cli() { case " $* " in *' list_sta '*) echo aa:bb:cc:dd:ee:ff;; *) echo FAIL;; esac; }
! client_walk
[ "$DONE" = 0 ] && [ "$ERRORS" = 2 ]
''')
 case('Controller FAIL reply with exit zero is not an empty successful client list', '''
set -e
hostapd_cli() { echo FAIL; return 0; }
! client_walk
[ "$DONE" = 0 ] && [ "$ERRORS" = 2 ]
''')
 case('Disabled APs are skipped without restarting a radio', '''
set -e
ap_available() { [ "$2" = wl0 ]; }
client_walk
[ "$DONE" = 1 ]; ! grep -q wl1 "$TRACE"
''')
 case('Stale queued worker becomes retryable and status counters cannot inject JSON', '''
set -e
client_alive() { return 1; }; write clients.state QUEUED; write clients.time 1
write clients.done '0,"bad":true'; write clients.failed 'bad'
client_status > "$BASE/result"
grep -q '"phase":"FAILED"' "$BASE/result"
grep -q '"requested":0,"failed":0' "$BASE/result"
''')
(ROOT/'work/clients-results.json').write_text(json.dumps(checks,indent=2),encoding='utf-8')
print(f'{len(checks)} isolated Wi-Fi reconnect scenarios passed.')
