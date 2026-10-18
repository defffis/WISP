#!/bin/sh
# Disposable removal scenarios. No live router configuration or processes are touched.
set -eu
SOURCE=$1
UNINSTALL_LIBRARY=1
. "$SOURCE"
. "$(dirname "$SOURCE")/locale.sh"
TESTROOT=$(mktemp -d /tmp/wisp-remove-fixture.XXXXXX)
[ "$(CDPATH= cd -- "$TESTROOT" && pwd -P)" = "$TESTROOT" ]
trap 'rm -rf "$TESTROOT"' EXIT HUP INT TERM
BASE="$TESTROOT/base"; RUN="$TESTROOT/run"; WEBRUN="$TESTROOT/web"
BOOTMARK="$TESTROOT/boot-attempt"; CRON="$TESTROOT/cron"
load_recovery() { :; }
remove_legacy_ui() { echo legacy >> "$TESTROOT/trace"; }
stop_web() { echo web >> "$TESTROOT/trace"; }
id() { echo 0; }
sync() { :; }
touch() { [ "$1" = /etc/crontabs ] || command touch "$@"; }
value() { cat "$RUN/$1" 2>/dev/null || true; }
write() { printf '%s\n' "$2" > "$RUN/$1"; }
bootid() { echo fixture-boot; }
alive() { [ -f "$TESTROOT/guard-alive" ]; }
sleep() {
 if [ -f "$TESTROOT/guard-alive" ]; then
  [ -f "$RUN/rollback.request" ]; echo guard-recovery >> "$TESTROOT/trace"
  rm -f "$TESTROOT/guard-alive" "$TESTROOT/runtime"; write phase ROLLED_BACK
 fi
}
ip() { [ ! -f "$TESTROOT/inspect-failure" ] || return 1; [ ! -f "$TESTROOT/runtime" ] || echo 'inet 192.168.50.1/24 scope global'; return 0; }
iptables() { [ ! -f "$TESTROOT/inspect-failure" ]; }
ip6tables() { [ ! -f "$TESTROOT/inspect-failure" ]; }
restore() {
 echo recovery >> "$TESTROOT/trace"
 [ ! -f "$TESTROOT/restore-failure" ] || return 1
 rm -f "$TESTROOT/runtime"; write phase ROLLED_BACK
}
reset_case() {
 [ ! -L "$BASE" ] || rm -f "$BASE"
 rm -rf "$BASE" "$RUN" "$WEBRUN"
 rm -f "$TESTROOT/guard-alive" "$TESTROOT/runtime" "$TESTROOT/restore-failure" "$TESTROOT/inspect-failure" "$TESTROOT/trace"
 mkdir -p "$BASE" "$RUN/config" "$WEBRUN" "$TESTROOT/other-app"
 echo do-not-delete > "$TESTROOT/other-app/important"
 echo private-tls-fixture > "$BASE/tls.key"
 echo snapshot-fixture > "$RUN/config/network"
 echo private-auth-fixture > "$WEBRUN/auth"
 echo enabled > "$BASE/enabled"
 write boot fixture-boot; write phase "$1"; write guard 42
 printf '%s\n' '*/1 * * * * /data/usr/app/wisp/wisp.sh vendor-check' '*/1 * * * * /data/usr/app/wisp/wisp.sh tick >/dev/null 2>&1' '*/1 * * * * /data/usr/app/wisp/service.sh ensure >/dev/null 2>&1' '0 5 * * * /data/usr/app/other-app/keep.sh' '# /data/usr/app/wisp/notes' '# /usr/sbin/wifiap_mode.sh check_gw is managed by vendor' '0 6 * * * /data/usr/app/other-app/backup.sh /data/usr/app/wisp/' '*/1 * * * * /bin/sh /data/usr/app/wisp/wisp.sh tick' > "$CRON"
 touch "$BOOTMARK"
}
PASS=0
assert_removed() {
 [ ! -e "$BASE" ] && [ ! -e "$RUN" ] && [ ! -e "$WEBRUN" ] && [ ! -e "$BOOTMARK" ]
 [ "$(cat "$TESTROOT/other-app/important")" = do-not-delete ]
 EXPECTED=$(printf '%s\n' '0 5 * * * /data/usr/app/other-app/keep.sh' '# /data/usr/app/wisp/notes' '# /usr/sbin/wifiap_mode.sh check_gw is managed by vendor' '0 6 * * * /data/usr/app/other-app/backup.sh /data/usr/app/wisp/' '*/1 * * * * /usr/sbin/wifiap_mode.sh check_gw')
 [ "$(cat "$CRON")" = "$EXPECTED" ]
}
for PHASE in OFF SNAPSHOT STARTING PENDING ACTIVE TEST APPLYING ROLLING_BACK ROLLED_BACK ABORTED RECOVERY_FAILED UNKNOWN; do
 reset_case "$PHASE"
 case "$PHASE" in STARTING|PENDING|ACTIVE|TEST|APPLYING|ROLLING_BACK|RECOVERY_FAILED|UNKNOWN) touch "$TESTROOT/runtime";; esac
 remove_run > "$TESTROOT/result"
 assert_removed
 PASS=$((PASS+1)); echo "PASS full removal from $PHASE"
done
reset_case ACTIVE; touch "$TESTROOT/runtime" "$TESTROOT/guard-alive"
remove_run > "$TESTROOT/result"; assert_removed
grep -q guard-recovery "$TESTROOT/trace"; ! grep -qx recovery "$TESTROOT/trace"
PASS=$((PASS+1)); echo 'PASS live guard owns rollback, no competing restore'
reset_case ACTIVE; touch "$TESTROOT/runtime" "$TESTROOT/restore-failure"
! remove_run > "$TESTROOT/result"
[ -f "$BASE/tls.key" ] && [ -f "$RUN/config/network" ] && [ -f "$BASE/remove-error" ]
grep -q wisp "$CRON"; ! grep -q legacy "$TESTROOT/trace"
PASS=$((PASS+1)); echo 'PASS recovery failure retains code, snapshot, keys and cron'
reset_case RECOVERY_FAILED; touch "$TESTROOT/inspect-failure"
! remove_run > "$TESTROOT/result"
[ -f "$BASE/tls.key" ] && [ -f "$RUN/config/network" ]; grep -q wisp "$CRON"
PASS=$((PASS+1)); echo 'PASS inspection failure is not treated as an empty network'
reset_case ACTIVE; touch "$TESTROOT/runtime"; write boot foreign-boot
! remove_run > "$TESTROOT/result"; [ -f "$BASE/tls.key" ] && [ -f "$RUN/config/network" ]
PASS=$((PASS+1)); echo 'PASS foreign boot with active runtime refuses destructive cleanup'
reset_case OFF; write boot foreign-boot
remove_run > "$TESTROOT/result"; assert_removed
PASS=$((PASS+1)); echo 'PASS stale journal without active runtime is fully removed'
reset_case OFF
echo '*/1 * * * * /usr/sbin/wifiap_mode.sh check_gw' >> "$CRON"
remove_run > "$TESTROOT/result"; assert_removed
PASS=$((PASS+1)); echo 'PASS stock vendor cron is not duplicated'
reset_case OFF; touch "$TESTROOT/runtime"
uci() { echo 192.168.50.1; }
remove_run > "$TESTROOT/result"; assert_removed
[ -f "$TESTROOT/runtime" ]; ! grep -qx recovery "$TESTROOT/trace"
PASS=$((PASS+1)); echo 'PASS user-selected stock LAN address is preserved after WISP is OFF'
# Symlink creation may be unavailable on Windows; Linux CI and device check this branch.
reset_case OFF
rm -rf "$BASE"
if ln -s "$TESTROOT/other-app" "$BASE" 2>/dev/null && [ -L "$BASE" ]; then
 ! remove_run > "$TESTROOT/result"
 [ "$(cat "$TESTROOT/other-app/important")" = do-not-delete ]
 PASS=$((PASS+1)); echo 'PASS symlink target cannot be recursively deleted'
fi
printf 'ALL %s REMOVAL FIXTURE TESTS PASSED\n' "$PASS"
