#!/bin/sh
# Exact owned paths only. Recovery must succeed before any private state is deleted.
set -u
umask 077
BASE=/data/usr/app/wisp
text() { printf '%s' "$1"; }
RUN=/tmp/wisp
WEBRUN=/tmp/wisp-panel
BOOTMARK=/tmp/wisp-boot-attempt
CRON=/etc/crontabs/root
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REMOVE_CODE=${WISP_CODE_DIR:-$HERE}
if [ -r "$BASE/locale.sh" ]; then . "$BASE/locale.sh"; elif [ -r "$REMOVE_CODE/locale.sh" ]; then . "$REMOVE_CODE/locale.sh"; fi
json() { printf '{"ok":%s,"msg":"%s"}\n' "$1" "$2"; }
safe_paths() {
 for D in "$BASE" "$RUN" "$WEBRUN"; do
  [ ! -L "$D" ] || return 1
  [ ! -d "$D" ] || [ "$(CDPATH= cd -- "$D" && pwd -P)" = "$D" ] || return 1
 done
}
remover_alive() {
 RP=$(cat "$BASE/remove.pid" 2>/dev/null || true)
 case "$RP" in ''|*[!0-9]*) return 1;; esac
 [ -r "/proc/$RP/cmdline" ] && tr '\000' ' ' < "/proc/$RP/cmdline" | grep -qF '/uninstall.sh worker'
}
load_recovery() {
 [ -r "$REMOVE_CODE/wisp.sh" ] && [ -r "$REMOVE_CODE/wisp-config.sh" ] || return 1
 WISP_LIBRARY=1; WISP_CODE_DIR=$REMOVE_CODE
 . "$REMOVE_CODE/wisp.sh"
}
own_runtime() {
 OADDR=$(ip -4 addr show dev br-lan) || return 2
 OWN_ADDR=0; KEEP_ADDR=0
 if printf '%s\n' "$OADDR" | grep -q 'inet 192.168.50.1/24 '; then
  case "$(value phase)" in ''|OFF|SNAPSHOT|ROLLED_BACK|ABORTED)
   # After WISP was turned off, the user may have chosen this address in MiWiFi.
   COMMITTED=$(uci -q get network.lan.ipaddr) || return 2
   if [ "$COMMITTED" = 192.168.50.1 ]; then KEEP_ADDR=1
   elif [ "$COMMITTED" = "$(value old)" ] && [ "$(value boot)" = "$(bootid)" ]; then OWN_ADDR=1
   else return 2; fi;;
   *) OWN_ADDR=1;;
  esac
 fi
 for TABLE in filter nat mangle; do
  ORULES=$(iptables -t "$TABLE" -S) || return 2
  if printf '%s\n' "$ORULES" | grep -q EWISP_; then [ "$KEEP_ADDR" = 0 ] || return 2; return 0; fi
 done
 ORULES=$(ip6tables -S) || return 2
 if printf '%s\n' "$ORULES" | grep -q EWISP_; then [ "$KEEP_ADDR" = 0 ] || return 2; return 0; fi
 [ "$OWN_ADDR" = 0 ] || return 0
 return 1
}
cron_has() {
 awk -v cmd="$1" -v arg="$2" '
  {i=substr($1,1,1)=="@" ? 2 : 6; if($i=="sh" || $i=="/bin/sh") i++;
   if($i==cmd && $(i+1)==arg) found=1} END{exit !found}' "$3"
}
remove_cron() {
 CT=$(mktemp /tmp/wisp-remove-cron.XXXXXX) || return 1
 HAD=0; cron_has /data/usr/app/wisp/wisp.sh vendor-check "$CRON" && HAD=1
 awk '{i=substr($1,1,1)=="@" ? 2 : 6; if($i=="sh" || $i=="/bin/sh") i++; if(index($i,"/data/usr/app/wisp/")!=1) print}' "$CRON" > "$CT" || { rm -f "$CT"; return 1; }
 if [ "$HAD" = 1 ] && ! cron_has /usr/sbin/wifiap_mode.sh check_gw "$CT"; then
  echo '*/1 * * * * /usr/sbin/wifiap_mode.sh check_gw' >> "$CT"
 fi
 # Replace the resolved crontab atomically; preserve mode and unrelated jobs.
 REAL_CRON=$(readlink -f "$CRON") || { rm -f "$CT"; return 1; }
 BEFORE=$(sha256sum "$REAL_CRON") || { rm -f "$CT"; return 1; }
 NEW_CRON=$(mktemp "$(dirname "$REAL_CRON")/.wisp-remove.XXXXXX") || { rm -f "$CT"; return 1; }
 if ! cp -p "$REAL_CRON" "$NEW_CRON" || ! cat "$CT" > "$NEW_CRON" || [ "$(sha256sum "$REAL_CRON")" != "$BEFORE" ]; then
  rm -f "$CT" "$NEW_CRON"; return 1
 fi
 mv "$NEW_CRON" "$REAL_CRON"; RC=$?; rm -f "$CT"
 [ "$RC" = 0 ] || { rm -f "$NEW_CRON"; return 1; }
 touch /etc/crontabs
}
stop_web() {
 WP=$(cat "$WEBRUN/nginx.pid" 2>/dev/null || true)
 case "$WP" in ''|*[!0-9]*) return 0;; esac
 if [ -r "/proc/$WP/cmdline" ] && tr '\000' ' ' < "/proc/$WP/cmdline" | grep -Fq "$WEBRUN/nginx.conf"; then
  kill -QUIT "$WP" || return 1
  N=0
  while [ -r "/proc/$WP/cmdline" ] && tr '\000' ' ' < "/proc/$WP/cmdline" | grep -Fq "$WEBRUN/nginx.conf"; do
   [ "$N" -lt 8 ] || return 1; sleep 1; N=$((N+1))
  done
 fi
}
remove_fail() {
 if [ -d "$BASE" ]; then
  echo "$1" > "$BASE/remove-error"
  rm -f "$BASE/removing" "$BASE/remove.pid"
 fi
 json false "$(text m75)"
 return 1
}
remove_run() {
 safe_paths || { json false "$(text m76)"; return 1; }
 [ "$(id -u)" = 0 ] || return 1
 load_recovery || { remove_fail missing_recovery; return 1; }
 # Prevent restart after a lost browser connection or a reboot during removal.
 rm -f "$BASE/enabled"; sync
 if [ -d "$RUN" ]; then
  [ "$(value boot)" != "$(bootid)" ] || { write reconnect 1; write rollback.request yes; }
  GP=$(value guard)
  if alive "$GP"; then
   # The existing guard owns recovery; do not race its APPLYING/restore section.
   write reconnect 1; write rollback.request yes
   N=0
   while alive "$GP"; do [ "$N" -lt 40 ] || { remove_fail guard_busy; return 1; }; sleep 1; N=$((N+1)); done
  fi
 fi
 PRESENT=0; own_runtime || PRESENT=$?
 if [ "$PRESENT" = 2 ]; then remove_fail inspect_failed; return 1; fi
 if [ "$PRESENT" = 0 ]; then
  [ -d "$RUN" ] && [ "$(value boot)" = "$(bootid)" ] || { remove_fail missing_journal; return 1; }
  # A dead guard / partial rollback can be repaired with the same recovery code.
  write reconnect 1
  restore || { remove_fail recovery_failed; return 1; }
 fi
 PRESENT=0; own_runtime || PRESENT=$?
 [ "$PRESENT" = 1 ] || { remove_fail runtime_left_or_unknown; return 1; }
 # Stop only our optional client task before its journal is removed.
 CP=$(value clients.pid)
 case "$CP" in ''|*[!0-9]*) ;; *)
  if [ -r "/proc/$CP/cmdline" ] && tr '\000' ' ' < "/proc/$CP/cmdline" | grep -Fq "$BASE/clients.sh _worker"; then
   kill "$CP" || { remove_fail clients_busy; return 1; }
   sleep 1
   if [ -r "/proc/$CP/cmdline" ] && tr '\000' ' ' < "/proc/$CP/cmdline" | grep -Fq "$BASE/clients.sh _worker"; then remove_fail clients_busy; return 1; fi
  fi;;
 esac
 # Also stop an owned orphan DNS process in an otherwise completed transaction.
 DP=$(value dns_owner)
 case "$DP" in ''|*[!0-9]*) ;; *)
  if [ -r "/proc/$DP/cmdline" ] && tr '\000' ' ' < "/proc/$DP/cmdline" | grep -Fq "$RUN/leases"; then
   kill "$DP" || { remove_fail dns_busy; return 1; }
   sleep 1
   if [ -r "/proc/$DP/cmdline" ] && tr '\000' ' ' < "/proc/$DP/cmdline" | grep -Fq "$RUN/leases"; then remove_fail dns_busy; return 1; fi
  fi;;
 esac
 stop_web || { remove_fail web_busy; return 1; }
 remove_cron || { remove_fail cron_failed; return 1; }
 safe_paths || { remove_fail unsafe_path; return 1; }
 # The worker executes its recovery library from RAM, outside these trees.
 rm -rf "$RUN" "$WEBRUN" "$BASE" || return 1
 rm -f "$BOOTMARK"
 sync
 json true "$(text m77)"
}
remove_queue() {
 safe_paths || { json false "$(text m78)"; return 1; }
 [ "$(id -u)" = 0 ] || return 1
 if [ -d "$BASE" ]; then
  exec 9>"$BASE/panel.lock"; flock -n 9 || { json false "$(text m79)"; return 1; }
  if remover_alive; then json true "$(text m80)"; return 0; fi
 fi
 T=$(mktemp -d /tmp/wisp-remove-worker.XXXXXX) || return 1
 chmod 700 "$T"
 for F in uninstall.sh wisp.sh wisp-config.sh VERSION locale.sh; do cp "$REMOVE_CODE/$F" "$T/$F" || { rm -rf "$T"; return 1; }; done
 if [ -d "$BASE" ]; then
  rm -f "$BASE/remove-error"
  printf '%s\n' requested > "$BASE/removing"
  PIDFILE="$BASE/remove.pid"
 else PIDFILE="$T/worker.pid"; fi
 if start-stop-daemon -S -b -m -p "$PIDFILE" -x /bin/sh -- -c 'exec sh "$1/uninstall.sh" worker </dev/null >/dev/null 2>&1 9>&-' wisp-remove "$T"; then
  json true "$(text m81)"
 else
  rm -f "$BASE/removing"; rm -rf "$T"; json false "$(text m82)"; return 1
 fi
}
[ "${UNINSTALL_LIBRARY:-0}" != 1 ] || return 0
case "${1:-plan}" in
 plan) safe_paths && printf '{"ok":true,"dry_run":true,"phase":"%s"}\n' "$(cat "$RUN/phase" 2>/dev/null | tr -cd 'A-Z_')";;
 queue) [ "${2:-}" = DELETE ] || { json false "$(text m83)"; exit 1; }; remove_queue;;
 resume) [ ! -f "$BASE/removing" ] || remove_queue;;
 worker)
  trap '' HUP
  # Complete the CGI/SSH acknowledgement before changing the caller's network.
  sleep 3
  RR=1; LOCKED=1
  if [ -d "$BASE" ]; then exec 9>"$BASE/panel.lock"; flock -n 9 || LOCKED=0; fi
  if [ "$LOCKED" = 1 ]; then remove_run; RR=$?; fi
  case "$HERE" in /tmp/wisp-remove-worker.*) rm -rf "$HERE";; esac
  exit "$RR";;
 *) echo 'Usage: uninstall.sh plan|queue DELETE'; exit 2;;
esac
