#!/bin/sh
# Private adapter; HTTP authentication and CSRF are checked by api.sh.
set -u
BASE=/data/usr/app/wisp
WISP_LIBRARY=1
. "$BASE/wisp.sh"
WISP_ORIGIN=panel
WISP_MODE=normal
WISP_DURATION=180
message_for() {
 case "$1" in
  test_complete) echo "$(text m55)";;
  manual) echo "$(text m56)";;
  confirmation_timeout|confirmation_expired) echo "$(text m57)";;
  unsupported_model|unsupported_firmware) echo "$(text m58)";;
  wrong_network_mode|wrong_sta_interface|unsupported_sta_mode) echo "$(text m59)";;
  sta_disconnected|gateway_ping_failed) echo "$(text m60)";;
  subnet_conflict) echo "$(text m61)";;
  pending_uci_changes) echo "$(text m62)";;
  switch_busy|vendor_busy|transaction_exists) echo "$(text m63)";;
  new_lan_required) echo "$(text m64)";;
  no_pending_transaction|wrong_transaction) echo "$(text m65)";;
  local_connection_required) echo "$(text m66)";;
  existing_lan_dhcp|unsupported_lan_mode|unsupported_netmask|multiple_gateways|unexpected_lan_address) echo "$(text m67)";;
  config_changed*) echo "$(text m68)";;
  config_check_error) echo "$(text m69)";;
  own_firewall_hooks_missing|default_route_changed|lan_address_missing|sta_rejoined_bridge) echo "$(text m70)";;
  apply_failed) echo "$(text m71)";;
  missing_tool|component_not_installed) echo "$(text m72)";;
  '') echo '';;
  *) echo "$(text m73)";;
 esac
}
reply() {
 # Messages are fixed strings without interpolation from command output.
 printf '{"ok":%s,"msg":"%s"}\n' "$1" "$(message_for "${2:-}")"
}
status_json() {
 PH=$(value phase); [ -n "$PH" ] || PH=OFF
 case "$PH" in OFF|SNAPSHOT|STARTING|PENDING|ACTIVE|TEST|APPLYING|ROLLING_BACK|ROLLED_BACK|ABORTED|RECOVERY_FAILED) ;; *) PH=UNKNOWN;; esac
 [ ! -f "$BASE/removing" ] || PH=REMOVING
 LEFT=0; END=
 case "$PH" in PENDING) END=$(value deadline);; TEST) END=$(value test_end);; esac
 case "$END" in ''|*[!0-9]*) ;; *) LEFT=$((END - $(now))); [ "$LEFT" -ge 0 ] || LEFT=0;; esac
 EN=false; [ ! -f "$BASE/enabled" ] || EN=true
 CAN=false; TK=
 if [ "$PH" = PENDING ] && [ "$LEFT" -gt 0 ] && alive "$(value guard)" && [ "$(value boot)" = "$(bootid)" ]; then
  TK=$(value token); case "$TK" in *[!0-9a-f]*) TK=;; esac
  [ "${#TK}" = 32 ] || TK=
  case "${HTTP_HOST:-}" in "$LAN:8443")
   if ipv4 "${REMOTE_ADDR:-}"; then
    case "${REMOTE_ADDR:-}" in "$LAN"|192.168.50.0|192.168.50.255) ;; 192.168.50.*) CAN=true;; esac
   fi;;
  esac
 fi
 REASON=$(value reason)
 case "$PH" in ROLLED_BACK|ABORTED|RECOVERY_FAILED) ;; *) REASON=;; esac
 REMOVE_MSG=
 [ ! -f "$BASE/remove-error" ] || REMOVE_MSG="$(text m74)"
 CLIENT_JSON=$(sh "$BASE/clients.sh" status 2>/dev/null) || CLIENT_JSON='{"phase":"IDLE","requested":0,"failed":0}'
 printf '{"ok":true,"clients":%s,"remove_error":"%s","version":"%s","phase":"%s","persistent":%s,"remaining":%s,"transaction":"%s","can_confirm":%s,"reason_message":"%s","lan":"%s"}\n' "$CLIENT_JSON" "$REMOVE_MSG" "$WISP_VERSION" "$PH" "$EN" "$LEFT" "$TK" "$CAN" "$(message_for "$REASON")" "$LAN"
}
prepare_start() {
 case "$(value phase)" in
  ''|ROLLED_BACK|ABORTED|SNAPSHOT)
   [ ! -f "$BASE/enabled" ] && ! alive "$(value guard)" || { fail transaction_exists; return 1; }
   [ ! -d "$RUN" ] || rm -rf "$RUN";;
  *) fail transaction_exists; return 1;;
 esac
}
OP=${1:-}
case "$OP" in
 status) status_json; exit 0;;
 check)
  case "$(value phase)" in ''|ROLLED_BACK|ABORTED|SNAPSHOT) ;; *) reply false transaction_exists; exit 0;; esac
  WISP_CHECK_ONLY=1
  if preflight > "$BASE/panel-last.log" 2>&1; then reply true; else reply false "${WISP_ERROR:-unknown}"; fi
  exit 0;;
 start|test|confirm|rollback|reconnect) ;;
 *) reply false unknown; exit 0;;
esac
[ ! -f "$BASE/removing" ] || { reply false transaction_exists; exit 0; }
exec 9>"$BASE/panel.lock"
flock -n 9 || { reply false transaction_exists; exit 0; }
if [ "$OP" = reconnect ]; then sh "$BASE/clients.sh" queue; exit $?; fi
RC=1
case "$OP" in
 start|test)
  if [ "$OP" = test ]; then WISP_RECONNECT=${3:-0}; else WISP_RECONNECT=${2:-0}; fi
  case "$WISP_RECONNECT" in 0|1) ;; *) reply false unknown; exit 0;; esac
  if prepare_start; then
   if [ "$OP" = test ]; then test_start "${2:-}" > "$BASE/panel-last.log" 2>&1; RC=$?
   else start > "$BASE/panel-last.log" 2>&1; RC=$?; fi
  fi;;
 confirm) confirm "${2:-}" > "$BASE/panel-last.log" 2>&1; RC=$?;;
 rollback)
  rm -f "$BASE/enabled"; sync
  if [ ! -d "$RUN" ]; then RC=0
  elif alive "$(value guard)"; then write rollback.request yes; RC=$?
  else rollback_reason manual > "$BASE/panel-last.log" 2>&1; RC=$?; fi;;
esac
if [ "$RC" = 0 ]; then reply true; else reply false "${WISP_ERROR:-unknown}"; fi
