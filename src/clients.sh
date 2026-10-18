#!/bin/sh
# Only LAN AP clients are reconnected; never the wl02 uplink or Ethernet.
set -u
umask 077
BASE=/data/usr/app/wisp
WISP_LIBRARY=1
. "$BASE/wisp.sh"
client_alive() {
 CP=$(value clients.pid)
 case "$CP" in ''|*[!0-9]*) return 1;; esac
 [ -r "/proc/$CP/cmdline" ] && tr '\000' ' ' < "/proc/$CP/cmdline" | grep -Fq "$BASE/clients.sh _worker"
}
client_phase() {
 CS=$(value clients.state)
 case "$CS" in QUEUED|RUNNING)
  CT=$(value clients.time); case "$CT" in ''|*[!0-9]*) CT=0;; esac
  client_alive || { [ "$CS" = QUEUED ] && [ "$(( $(now) - CT ))" -lt 5 ]; } || CS=FAILED;;
  DONE|PARTIAL|FAILED) ;; *) CS=IDLE;;
 esac
 printf '%s\n' "$CS"
}
client_status() {
 CD=$(value clients.done); CF=$(value clients.failed)
 case "$CD" in ''|*[!0-9]*|????*) CD=0;; esac
 case "$CF" in ''|*[!0-9]*|????*) CF=0;; esac
 printf '{"phase":"%s","requested":%s,"failed":%s}\n' "$(client_phase)" "$CD" "$CF"
}
client_stable() {
 [ ! -f "$BASE/removing" ] || return 1
 case "$(value phase)" in
 ACTIVE) [ "$(value boot)" = "$(bootid)" ] && alive "$(value guard)" && healthy;;
 ''|OFF|ROLLED_BACK|ABORTED) [ ! -f "$BASE/enabled" ] && ! alive "$(value guard)";;
 *) return 1;;
 esac
}
client_ready() {
 command -v hostapd_cli >/dev/null && command -v timeout >/dev/null && client_stable
}
ap_available() { [ -S "$1/$2" ]; }
client_walk() {
 DONE=0; ERRORS=0; SEEN=0
 CE=$(( $(now) + 20 ))
 for SPEC in '/var/run/hostapd-wifi0 wl1' '/var/run/hostapd-wifi1 wl0'; do
  set -- $SPEC
  ap_available "$1" "$2" || continue
  LIST=$(timeout 5 hostapd_cli -p "$1" -i "$2" list_sta 2>/dev/null) || { ERRORS=$((ERRORS+1)); continue; }
  if printf '%s\n' "$LIST" | grep -qE '^(FAIL|UNKNOWN COMMAND|Could not connect|Failed to)'; then ERRORS=$((ERRORS+1)); continue; fi
  for MAC in $LIST; do
   printf '%s\n' "$MAC" | grep -qE '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' || continue
   SEEN=$((SEEN+1))
   [ "${CLIENT_PLAN:-0}" = 1 ] && continue
   if [ -f "$BASE/removing" ] || ! client_stable || [ "$(now)" -ge "$CE" ]; then ERRORS=$((ERRORS+1)); return 1; fi
   ANSWER=$(timeout 1 hostapd_cli -p "$1" -i "$2" deauthenticate "$MAC" reason=3 2>/dev/null) || ANSWER=FAIL
   case "$ANSWER" in *OK*) DONE=$((DONE+1));; *) ERRORS=$((ERRORS+1));; esac
  done
 done
 [ "$ERRORS" = 0 ]
}
client_worker() {
 exec 7>"$RUN/clients.lock"
 flock -n 7 || exit 1
 write clients.state RUNNING
 # Allow the acknowledgement to reach the browser before Wi-Fi is interrupted.
 sleep 2
 if ! client_ready; then write clients.state FAILED; exit 1; fi
 CRESULT=0; client_walk || CRESULT=$?
 write clients.done "$DONE"; write clients.failed "$ERRORS"
 if [ "$CRESULT" = 0 ]; then write clients.state DONE; else write clients.state PARTIAL; fi
 log "Wi-Fi reconnect: requested=$DONE failures=$ERRORS; uplink and DHCP server unchanged"
}
client_queue() {
 client_ready || { echo "$(text m52)"; return 0; }
 case "$(client_phase)" in QUEUED|RUNNING) echo "$(text m53)"; return 0;; esac
 mkdir -p "$RUN"; chmod 700 "$RUN"
 write clients.time "$(now)"; write clients.state QUEUED
 write clients.done 0; write clients.failed 0
 if start-stop-daemon -S -b -m -p "$RUN/clients.pid" -x /bin/sh -- -c 'exec sh "$1/clients.sh" _worker </dev/null >/dev/null 2>&1 9>&-' wisp-clients "$BASE"; then
  echo '{"ok":true,"scheduled":true}'
 else write clients.state FAILED; echo "$(text m54)"; fi
}
[ "${CLIENTS_LIBRARY:-0}" != 1 ] || return 0
case "${1:-}" in
 status) client_status;;
 plan) CLIENT_PLAN=1 client_walk && printf '{"ok":true,"wifi_clients":%s,"dry_run":true}\n' "$SEEN";;
 queue) client_queue;;
 _worker) client_worker;;
 *) echo 'Usage: clients.sh plan|status|queue'; exit 2;;
esac
