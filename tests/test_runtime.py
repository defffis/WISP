from pathlib import Path
import subprocess, tempfile, json, shutil, os

ROOT = Path(__file__).resolve().parents[1]
(ROOT / 'work').mkdir(exist_ok=True)
BASH = (str(Path(os.environ.get('ProgramFiles','C:/Program Files'))/'Git/bin/bash.exe') if os.name=='nt' else shutil.which('bash'))
source = (ROOT / 'src/wisp.sh').read_text(encoding='utf-8')
library = source.rsplit('case "${1:-}" in', 1)[0]
results = []

def run(name, script):
    with tempfile.TemporaryDirectory(dir=ROOT) as tmp:
        p = Path(tmp)
        (p / 'base').mkdir()
        shutil.copyfile(ROOT / 'src/wisp-config.sh', p / 'base/wisp-config.sh')
        shutil.copyfile(ROOT / 'src/VERSION', p / 'base/VERSION')
        unix = p.as_posix()
        if os.name == 'nt': unix = '/' + unix[0].lower() + unix[2:]
        (p / 'base/wisp-config.sh').write_text((ROOT / 'src/wisp-config.sh').read_text(encoding='utf-8').replace('/etc/config',f'{unix}/config'),encoding='utf-8',newline='\n')
        lib = library.replace('BASE=/data/usr/app/wisp', f'BASE={unix}/base')
        lib = lib.replace('RUN=/tmp/wisp', f'RUN={unix}/run')
        lib = lib.replace('SWITCH=/tmp/wisp-switching.lock', f'SWITCH={unix}/switch')
        lib = lib.replace('/proc/sys/net/ipv4/ip_forward', f'{unix}/forwarding')
        lib = lib.replace('/tmp/wisp-boot-attempt', f'{unix}/boot-attempt')
        lib = lib.replace('/sys/class/net/', f'{unix}/net/')
        lib = lib.replace('/etc/config', f'{unix}/config')
        setup = '''
set -e
mkdir -p "$BASE" "$RUN" "${BASE%/base}/config"
now() { echo 100; }
bootid() { echo boot-one; }
write boot boot-one
write old 192.168.1.26
write gateway 192.168.1.1
write forwarding 0
write phase PENDING
write token 0123456789abcdef0123456789abcdef
write deadline 280
TRACE="$BASE/trace"
ip() { echo "ip $*" >> "$TRACE"; return 0; }
iw() { echo "iw $*" >> "$TRACE"; return 0; }
brctl() { echo "brctl $*" >> "$TRACE"; return 0; }
arping() { echo "arping $*" >> "$TRACE"; return 0; }
iptables() { echo "iptables $*" >> "$TRACE"; case " $* " in *' -C '*) return 1;; esac; return 0; }
ip6tables() { echo "ip6tables $*" >> "$TRACE"; case " $* " in *' -C '*) return 1;; esac; return 0; }
wired_peer() { return 0; }
'''
        test = p / 'test.sh'
        test.write_text(lib + setup + script, encoding='utf-8', newline='\n')
        r = subprocess.run([BASH, str(test)], capture_output=True, text=True, timeout=15)
        if r.returncode:
            raise AssertionError(f'{name}: {r.returncode}\n{r.stdout}\n{r.stderr}')
        results.append({'test': name, 'result': 'PASS'})

run('IPv4 validation rejects injection and out-of-range values', '''
ipv4 192.168.1.26
! ipv4 '1.2.3.999'
! ipv4 '1.2.3.4;reboot'
! ipv4 '1.2.3'
''')
run('Rollback restores original IP, bridge, route, forwarding and only own chains', '''
restore
[ "$(value phase)" = ROLLED_BACK ]
grep -q 'ip addr add 192.168.1.26/24 dev br-lan' "$TRACE"
grep -q 'brctl addif br-lan wl02' "$TRACE"
grep -q 'iw dev wl02 set 4addr on' "$TRACE"
grep -q 'ip route replace default via 192.168.1.1 dev br-lan' "$TRACE"
! grep -Eq 'iptables -t [a-z]+ -F$|uci|reboot|network restart' "$TRACE"
[ "$(cat "${BASE%/base}/forwarding")" = 0 ]
''')
run('Partial apply can be rolled back twice', '''
write phase APPLYING
restore
restore
[ "$(value phase)" = ROLLED_BACK ]
''')
run('Recovery error remains explicit and is not reported as successful', '''
iw() { return 1; }
! restore
[ "$(value phase)" = RECOVERY_FAILED ]
''')
run('Journal from different boot cannot mutate current network', '''
write boot other-boot
! restore
[ ! -e "$TRACE" ]
''')
run('Bad token and old management session cannot confirm', '''
alive() { return 0; }
SSH_CONNECTION='192.168.50.2 40000 192.168.50.1 22'
! confirm wrong
[ ! -f "$RUN/confirm.request" ]
SSH_CONNECTION='192.168.1.52 40000 192.168.1.26 22'
! confirm 0123456789abcdef0123456789abcdef
[ ! -f "$RUN/confirm.request" ]
''')
run('Confirmation requires fresh LAN SSH, live guard and deadline', '''
alive() { return 0; }
SSH_CONNECTION='192.168.50.2 40000 192.168.50.1 22'
confirm 0123456789abcdef0123456789abcdef
[ -f "$RUN/confirm.request" ]
rm "$RUN/confirm.request"
write deadline 100
! confirm 0123456789abcdef0123456789abcdef
[ ! -f "$RUN/confirm.request" ]
''')
run('Timeout triggers rollback even when health is good', '''
write phase STARTING
write deadline 100
lock_switch() { return 0; }
unlock_switch() { return 0; }
config_unchanged() { return 0; }
pgrep() { return 1; }
apply_runtime() { write phase PENDING; }
healthy() { return 0; }
guard
[ "$(value phase)" = ROLLED_BACK ]
''')
run('Wireless peer can confirm with valid token and new LAN address', '''
alive() { return 0; }
wired_peer() { return 1; }
SSH_CONNECTION='192.168.50.2 40000 192.168.50.1 22'
confirm 0123456789abcdef0123456789abcdef
[ -f "$RUN/confirm.request" ]
''')
run('Failure during apply triggers immediate rollback', '''
write phase STARTING
lock_switch() { return 0; }
unlock_switch() { return 0; }
config_unchanged() { return 0; }
pgrep() { return 1; }
apply_runtime() { write phase APPLYING; return 1; }
! (guard)
[ "$(value phase)" = ROLLED_BACK ]
''')
run('Three failed health checks trigger rollback', '''
write phase STARTING
lock_switch() { return 0; }
unlock_switch() { return 0; }
config_unchanged() { return 0; }
pgrep() { return 1; }
apply_runtime() { write phase PENDING; }
healthy() { return 1; }
sleep() { :; }
guard
[ "$(value phase)" = ROLLED_BACK ]
''')
run('Cron recovers when guard is dead', '''
write phase ACTIVE
alive() { return 1; }
tick
[ "$(value phase)" = ROLLED_BACK ]
[ ! -d "$RUN/recover.lock" ]
''')
run('Cron does not race live guard or initial launch', '''
alive() { return 0; }
tick
[ ! -e "$TRACE" ]
alive() { return 1; }
write phase STARTING
tick
[ ! -e "$TRACE" ]
''')

run('WAN isolation precedes existing VPN accepts; outbound allow follows existing policy', '''
rules
grep -q 'iptables -I FORWARD 1 -j EWISP_WAN' "$TRACE"
grep -q 'iptables -A FORWARD -j EWISP_FWD' "$TRACE"
grep -q 'EWISP_WAN -i wl02 -j DROP' "$TRACE"
''')
run('DNS DNAT and outbound masquerade have separate hooks', '''
rules
grep -q 'iptables -t nat -I PREROUTING 1 -j EWISP_DNS' "$TRACE"
grep -q 'iptables -t nat -I POSTROUTING 1 -j EWISP_NAT' "$TRACE"
! grep -q 'EWISP_NAT.*DNAT' "$TRACE"
! grep -q 'EWISP_DNS.*MASQUERADE' "$TRACE"
''')

run('Alternate starting IP and gateway drive rollback without external app redirects', '''
for spec in '10.23.7.42 10.23.7.1' '172.20.8.19 172.20.8.254' '192.168.8.99 192.168.8.1'; do
  set -- $spec
  write old "$1"; write gateway "$2"
  : > "$TRACE"
  rules
  ! grep -q 8088 "$TRACE"
  restore
  grep -Fq "ip addr add $1/24 dev br-lan" "$TRACE"
  grep -Fq "ip route replace default via $2 dev br-lan" "$TRACE"
  ! grep -Fq '192.168.1.26' "$TRACE"
done
''')

run('Timed test expires and does not persist enabled state', '''
write phase STARTING; write mode test; write duration 60
lock_switch() { :; }; unlock_switch() { :; }; config_unchanged() { return 0; }; pgrep() { return 1; }
apply_runtime() { write phase PENDING; }; healthy() { return 0; }
sleep() { now() { echo 161; }; }
guard
[ "$(value phase)" = ROLLED_BACK ]
[ ! -f "$BASE/enabled" ]
''')
run('Duration validation rejects unsafe or unbounded values', '''
start() { write requested "$WISP_DURATION"; }
! test_start 0; ! test_start 3601; ! test_start '1;reboot'
test_start 60; [ "$(value requested)" = 60 ]
test_start 3600; [ "$(value requested)" = 3600 ]
touch "$BASE/enabled"; ! test_start 180
''')
run('Normal confirmation persists only after healthy guard accepts it', '''
write phase STARTING; write mode normal; write confirm.request yes
lock_switch() { :; }; unlock_switch() { :; }; config_unchanged() { return 0; }; pgrep() { return 1; }
apply_runtime() { write phase PENDING; }; healthy() { return 0; }
sleep() { [ -f "$BASE/enabled" ]; write observed yes; write rollback.request yes; }
guard
[ "$(value observed)" = yes ]
[ ! -f "$BASE/enabled" ]
''')
run('Panel confirmation uses browser host after DNAT and accepts WiFi', '''
alive() { return 0; }; WISP_ORIGIN=panel; REMOTE_ADDR=192.168.50.2; SERVER_ADDR=192.168.1.26
HTTP_HOST=192.168.1.26:8088
! confirm 0123456789abcdef0123456789abcdef
HTTP_HOST=192.168.50.1:8443; REMOTE_ADDR=192.168.1.52
! confirm 0123456789abcdef0123456789abcdef
REMOTE_ADDR=192.168.50.2; wired_peer() { return 1; }
confirm 0123456789abcdef0123456789abcdef
[ -f "$RUN/confirm.request" ]
''')
run('Boot transaction activates without interactive confirmation and rolls back on health failure', '''
write phase STARTING; write mode boot; touch "$BASE/enabled"
lock_switch() { :; }; unlock_switch() { :; }; config_unchanged() { return 0; }; pgrep() { return 1; }
apply_runtime() { write phase PENDING; }; healthy() { return 1; }; sleep() { :; }
guard
[ "$(value phase)" = ROLLED_BACK ]
[ ! -f "$BASE/enabled" ]
''')

run('Boot resume attempts once per boot and readiness timeout clears desired state', '''
rm -rf "$RUN"; touch "$BASE/enabled"
preflight() { return 0; }; start() { echo boot >> "$TRACE"; }
boot_resume; boot_resume
[ "$(wc -l < "$TRACE")" = 1 ]
rm -f "${BASE%/base}/boot-attempt"
preflight() { return 1; }; now() { echo 601; }
boot_resume
[ ! -f "$BASE/enabled" ]
''')

run('Local LAN start permits WiFi and rejects off-LAN or uplink routes', '''
OLD=192.168.1.26
ip() { echo '192.168.1.52 dev br-lan src 192.168.1.26'; }
local_peer 192.168.1.52
! local_peer 192.168.50.52
! local_peer 192.168.1.255
ip() { echo '192.168.1.52 dev wl02 src 192.168.1.26'; }
! local_peer 192.168.1.52
''')
run('Brief connectivity interruption recovers without rollback', '''
write phase STARTING; write mode boot; touch "$BASE/enabled"
lock_switch() { :; }; unlock_switch() { :; }; config_unchanged() { return 0; }; pgrep() { return 1; }
apply_runtime() { write phase PENDING; }
STEP=0
now() { echo "$((100 + STEP * 5))"; }
sleep() { STEP=$((STEP+1)); }
healthy() {
 if [ "$STEP" -lt 4 ]; then health_fail gateway_ping_failed 1; return 1; fi
 [ -f "$BASE/enabled" ]
 write recovered yes; write rollback.request yes; return 0
}
guard
[ "$(value recovered)" = yes ]
grep -q 'health recovered' "$BASE/events.log"
''')
run('Connectivity failure lasting 120 seconds triggers diagnosed rollback', '''
write phase STARTING; write mode boot; touch "$BASE/enabled"
lock_switch() { :; }; unlock_switch() { :; }; config_unchanged() { return 0; }; pgrep() { return 1; }
apply_runtime() { write phase PENDING; }
STEP=0
now() { echo "$((100 + STEP * 30))"; }
sleep() { STEP=$((STEP+1)); }
healthy() { health_fail sta_disconnected 1; return 1; }
guard
[ "$(value phase)" = ROLLED_BACK ]
grep -q 'connectivity failure for 120 seconds: sta_disconnected' "$BASE/events.log"
''')

run('Reconnect is opt-in and targets only validated clients on LAN APs', '''
timeout() { shift; "$@"; }
hostapd_cli() {
 echo "$*" >> "$TRACE"
 case " $* " in *' list_sta '*) printf 'aa:bb:cc:dd:ee:ff\\nmalformed\\n';; *) echo OK;; esac
}
reconnect_clients
[ ! -f "$TRACE" ]
write reconnect 1
reconnect_clients
grep -q 'wl1 deauthenticate aa:bb:cc:dd:ee:ff reason=3' "$TRACE"
grep -q 'wl0 deauthenticate aa:bb:cc:dd:ee:ff reason=3' "$TRACE"
! grep -Eq 'wl02|deauthenticate malformed' "$TRACE"
''')

run('Config checker records mismatching file names without reading values', '''
uci() { case "$*" in *NETMODE) echo wifiapmode;; *active_apcli) echo wl02;; esac; }
sha256sum() { printf 'network: OK\\nwireless: FAILED\\n'; return 1; }
! config_unchanged
[ "$CONFIG_REASON" = config_changed_wireless ]
grep -q 'wireless: FAILED' "$BASE/config-health.log"
sha256sum() { echo 'checksum manifest unavailable' >&2; return 1; }
! config_unchanged
[ "$CONFIG_REASON" = config_check_error ]
''')
run('Short-lived config check failure recovers without rollback', '''
write phase STARTING; write mode boot; touch "$BASE/enabled"
lock_switch() { :; }; unlock_switch() { :; }; config_unchanged() { return 0; }; pgrep() { return 1; }
apply_runtime() { write phase PENDING; }
STEP=0
now() { echo "$((100 + STEP * 5))"; }
sleep() { STEP=$((STEP+1)); }
healthy() {
 if [ "$STEP" -lt 4 ]; then health_fail config_check_error; return 1; fi
 [ -f "$BASE/enabled" ]; write recovered yes; write rollback.request yes; return 0
}
guard
[ "$(value recovered)" = yes ]
''')
run('Persistent config drift still rolls back after 30 seconds', '''
write phase STARTING; write mode boot; touch "$BASE/enabled"
lock_switch() { :; }; unlock_switch() { :; }; config_unchanged() { return 0; }; pgrep() { return 1; }
apply_runtime() { write phase PENDING; }
STEP=0
now() { echo "$((100 + STEP * 10))"; }
sleep() { STEP=$((STEP+1)); }
healthy() { health_fail config_changed_network; return 1; }
guard
[ "$(value phase)" = ROLLED_BACK ]
[ "$(cat "$BASE/last-rollback-reason")" = config_changed_network ]
grep -q 'configuration check failed for 30 seconds' "$BASE/events.log"
''')

run('Guard adoption refuses an unconfirmed or unhealthy transaction before stopping anything', '''
write phase PENDING; write guard 42; touch "$BASE/enabled"
alive() { return 0; }; healthy() { return 0; }; kill() { echo "kill $*" >> "$TRACE"; }
! adopt_guard 42
[ ! -f "$TRACE" ]
write phase ACTIVE; healthy() { return 1; }
! adopt_guard 42
[ ! -f "$TRACE" ]
''')
run('Guard adoption keeps all network state and retires only the validated previous guard', '''
write phase ACTIVE; write guard 42; touch "$BASE/enabled"
alive() { [ "$1" = 42 ]; }; healthy() { return 0; }
kill() { echo "kill $*" >> "$TRACE"; }; sleep() { :; }
adopt_guard 42
[ "$(value guard)" = "$$" ]
[ "$(value adopted)" = "$WISP_VERSION" ]
[ "$(value phase)" = ACTIVE ] && [ -f "$BASE/enabled" ]
grep -q "kill -STOP 42" "$TRACE"
grep -q "kill -KILL 42" "$TRACE"
! grep -Eq "brctl|iw |ip addr|ip route|MASQUERADE|EWISP_NAT" "$TRACE"
''')
run('Guard adoption resumes the old process if the final health check fails', '''
write phase ACTIVE; write guard 42; touch "$BASE/enabled"
alive() { return 0; }; COUNT=0; healthy() { COUNT=$((COUNT+1)); [ "$COUNT" = 1 ]; }
kill() { echo "kill $*" >> "$TRACE"; }; sleep() { :; }
! adopt_guard 42
[ "$(value guard)" = 42 ]
grep -q "kill -CONT 42" "$TRACE"
! grep -q "kill -KILL" "$TRACE"
''')
run('Network health no longer calls the external app redirect or web service', '''
panel_refresh() { echo unexpected >> "$TRACE"; return 1; }
panel_update() { echo unexpected >> "$TRACE"; return 1; }
bootid() { echo boot-one; }; ip() { case "$*" in *addr*) echo "inet 192.168.50.1/24 scope global";; *default*) echo "default via 192.168.1.1 dev wl02";; esac; }
kill() { :; }; iptables() { :; }; ip6tables() { :; }; config_unchanged() { :; }; iw() { echo "Connected to AP"; }; ping() { :; }
healthy
[ ! -f "$TRACE" ]
''')

run('Pending full removal delegates to remover and suppresses boot/vendor actions', '''
touch "$BASE/removing"
sh() { echo "sh $*" >> "$TRACE"; }
boot_resume() { return 99; }
tick
vendor_check
[ "$(wc -l < "$TRACE")" = 2 ]
grep -q 'uninstall.sh resume' "$TRACE"
[ -f "$BASE/removing" ]
''')

for f in (ROOT / 'src').glob('*.sh'):
    subprocess.run([BASH, '-n', str(f)], check=True, capture_output=True)
results.append({'test': 'Shell syntax for every package script', 'result': 'PASS'})
(ROOT / 'work/test-results.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
print(f'{len(results)} checks passed; network commands were simulated locally.')
