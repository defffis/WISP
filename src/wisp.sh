#!/bin/sh
# Standalone WISP 0.6.0: RN02/1.0.64, existing wl02 STA, IPv4, runtime only.
set -u
umask 077
BASE=/data/usr/app/wisp
text() { printf '%s' "$1"; }
[ ! -r "$BASE/locale.sh" ] || . "$BASE/locale.sh"
RUN=/tmp/wisp
SWITCH=/tmp/wisp-switching.lock
LAN=192.168.50.1
PREFIX=192.168.50.0/24
STA=wl02
BR=br-lan
CODE=${WISP_CODE_DIR:-$BASE}
. "$CODE/wisp-config.sh"
[ -r "$BASE/locale.sh" ] || { [ ! -r "$CODE/locale.sh" ] || . "$CODE/locale.sh"; }
WISP_VERSION=$(cat "$CODE/VERSION" 2>/dev/null || echo development)
fail() { WISP_ERROR=$1; echo "WISP: $*" >&2; return 1; }
now() { cut -d. -f1 /proc/uptime; }
bootid() { cat /proc/sys/kernel/random/boot_id; }
value() { cat "$RUN/$1" 2>/dev/null || true; }
write() { printf '%s\n' "$2" > "$RUN/$1.new" && mv "$RUN/$1.new" "$RUN/$1"; }
log() { if [ -f "$BASE/events.log" ] && [ "$(wc -c < "$BASE/events.log")" -gt 16384 ]; then mv "$BASE/events.log" "$BASE/events.log.1"; fi; printf '%s %s\n' "$(now)" "$*" >> "$BASE/events.log"; }
ipv4() { printf '%s\n' "$1" | awk -F. 'NF!=4{exit 1} {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i+0>255) exit 1}'; }
alive() {
  case "$1" in ''|*[!0-9]*) return 1;; esac
  GC=$(value guard-command); [ -n "$GC" ] || GC="$BASE/wisp.sh"
  case "$GC" in /data/usr/app/*/wisp.sh) ;; *) return 1;; esac
  [ -r "/proc/$1/cmdline" ] && tr '\000' ' ' < "/proc/$1/cmdline" | grep -Fq "$GC _guard"
}
local_peer() {
  ipv4 "$1" && [ "${1%.*}" = "${OLD%.*}" ] || return 1
  case "${1##*.}" in 0|255) return 1;; esac
  ip -4 route get "$1" | grep -q " dev $BR "
}
reconnect_clients() {
  [ "$(value reconnect)" = 1 ] || return 0
  RECONNECT_END=$(( $(now) + 15 ))
  log 'reconnecting LAN Wi-Fi clients; uplink remains connected'
  for SPEC in '/var/run/hostapd-wifi0 wl1' '/var/run/hostapd-wifi1 wl0'; do
    set -- $SPEC
    CLIENTS=$(timeout 5 hostapd_cli -p "$1" -i "$2" list_sta 2>/dev/null) || { log "client enumeration failed: $2"; continue; }
    for MAC in $CLIENTS; do
      [ "$(now)" -lt "$RECONNECT_END" ] || { log 'client reconnect time budget exhausted'; return 0; }
      printf '%s\n' "$MAC" | grep -qE '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' || continue
      REPLY=$(timeout 1 hostapd_cli -p "$1" -i "$2" deauthenticate "$MAC" reason=3 2>/dev/null) || REPLY=FAIL
      case "$REPLY" in *OK*) log "client reconnect requested on $2: $MAC";; *) log "client reconnect failed on $2: $MAC";; esac
    done
  done
  return 0
}
preflight() {
  case "${WISP_RECONNECT:-0}" in 0|1) ;; *) fail 'reconnect must be 0 or 1'; return 1;; esac
  if [ "${WISP_RECONNECT:-0}" = 1 ]; then
    command -v hostapd_cli >/dev/null && command -v timeout >/dev/null || { fail 'client reconnect tools missing'; return 1; }
  fi
  [ "$(id -u)" = 0 ] || { fail 'root required'; return 1; }
  [ "$(uci -q get /usr/share/xiaoqiang/xiaoqiang_version.version.HARDWARE)" = RN02 ] || { fail unsupported_model; return 1; }
  [ "$(uci -q get /usr/share/xiaoqiang/xiaoqiang_version.version.ROM)" = 1.0.64 ] || { fail unsupported_firmware; return 1; }
  [ "$(uci -q get xiaoqiang.common.NETMODE)" = wifiapmode ] || { fail wrong_network_mode; return 1; }
  [ "$(uci -q get xiaoqiang.common.active_apcli)" = "$STA" ] || { fail wrong_sta_interface; return 1; }
  [ "$(uci -q get network.lan.proto)" = static ] || { fail unsupported_lan_mode; return 1; }
  [ "$(uci -q get network.lan.netmask)" = 255.255.255.0 ] || { fail unsupported_netmask; return 1; }
  OLD=$(uci -q get network.lan.ipaddr); GW=$(uci -q get network.lan.gateway)
  ipv4 "$OLD" && ipv4 "$GW" || return 1
  [ "${OLD%.*}" = "${GW%.*}" ] || return 1
  [ "${OLD%.*}" != 192.168.50 ] || { fail subnet_conflict; return 1; }
  [ "$(ip -4 addr show dev "$BR" | awk '/inet /{print $2}')" = "$OLD/24" ] || { fail unexpected_lan_address; return 1; }
  [ -d "/sys/class/net/$BR/brif/$STA" ] || return 1
  iw dev "$STA" link | grep -q '^Connected to ' || { fail sta_disconnected; return 1; }
  iw dev "$STA" info | grep -q '4addr: on' || { fail unsupported_sta_mode; return 1; }
  ip -4 route show default | grep -q "^default via $GW dev $BR" || return 1
  [ "$(ip -4 route show default | wc -l)" -eq 1 ] || { fail multiple_gateways; return 1; }
  ! ip -4 route show table all | grep -q '192\.168\.50\.' || { fail subnet_conflict; return 1; }
  ! uci -q show dhcp | grep -q "\.interface='lan'" || { fail existing_lan_dhcp; return 1; }
  [ -z "$(uci -q changes network)$(uci -q changes wireless)$(uci -q changes dhcp)" ] || { fail pending_uci_changes; return 1; }
  for c in ip iw brctl iptables ip6tables iptables-save dnsmasq start-stop-daemon sha256sum ping pgrep arping netstat flock; do command -v "$c" >/dev/null || { fail missing_tool; return 1; }; done
  [ -r /proc/sys/kernel/random/uuid ] || return 1
  ping -I "$BR" -c 1 -W 2 "$GW" >/dev/null 2>&1 || { fail gateway_ping_failed; return 1; }
  [ -f /etc/crontabs/root ] && grep -q 'wisp/wisp.sh vendor-check' /etc/crontabs/root || { fail component_not_installed; return 1; }
  [ -z "$(pgrep -f 'wifiap_mode.sh check_gw|dhcp_apclient.sh start' 2>/dev/null)" ] || { fail vendor_busy; return 1; }
  [ ! -d "$RUN" ] || [ "${WISP_CHECK_ONLY:-0}" = 1 ] || { fail transaction_exists; return 1; }
  [ ! -e "$SWITCH" ] || { fail switch_busy; return 1; }
  if [ "${WISP_ORIGIN:-ssh}" = boot ]; then
    PEER=boot
  elif [ "${WISP_ORIGIN:-ssh}" = panel ]; then
    PEER=${REMOTE_ADDR:-}
    local_peer "$PEER" || { fail local_connection_required; return 1; }
  else
  case "${SSH_CONNECTION:-}" in '' ) fail local_connection_required; return 1;; esac
  PEER=${SSH_CONNECTION%% *}
  local_peer "$PEER" || { fail local_connection_required; return 1; }
  fi
  for t in filter nat mangle; do ! iptables -t "$t" -S 2>/dev/null | grep -q 'EWISP_' || { fail stale_firewall_rules; return 1; }; done
  ! ip6tables -S 2>/dev/null | grep -q EWISP_ || return 1
}
snapshot() {
  mkdir "$RUN" || return 1
  write phase SNAPSHOT || return 1
  write boot "$(bootid)" && write old "$OLD" && write gateway "$GW" && write peer "$PEER" || return 1
  write forwarding "$(cat /proc/sys/net/ipv4/ip_forward)" || return 1
  mkdir "$RUN/config" || return 1
  for f in network wireless dhcp firewall xiaoqiang; do cp -p "/etc/config/$f" "$RUN/config/$f" || return 1; done
  (cd /etc/config && sha256sum network wireless dhcp firewall xiaoqiang) > "$RUN/config.sha256" || return 1
  ip -4 addr show > "$RUN/addresses.before"
  ip -4 route show table all > "$RUN/routes.before"
  ip -4 rule show > "$RUN/rules.before"
  iptables-save > "$RUN/firewall.before" || return 1
  TOKEN=$(tr -d '-' < /proc/sys/kernel/random/uuid)
  [ ${#TOKEN} -eq 32 ] || return 1
  write token "$TOKEN" && write deadline "$(( $(now) + 180 ))" || return 1
  sync
}

lock_switch() {
 (set -C; echo $$ > "$SWITCH") 2>/dev/null
}
unlock_switch() { [ "$(cat "$SWITCH" 2>/dev/null)" = "$$" ] && rm -f "$SWITCH"; return 0; }
rules() {
  iptables -N EWISP_IN && iptables -N EWISP_FWD && iptables -N EWISP_WAN && iptables -t nat -N EWISP_NAT && iptables -t nat -N EWISP_DNS && iptables -t mangle -N EWISP_MG && iptables -t mangle -N EWISP_OUT || return 1
  ip6tables -N EWISP_V6 || return 1
  iptables -A EWISP_IN -i "$STA" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT &&
  iptables -A EWISP_IN -i "$STA" -j DROP &&
  iptables -A EWISP_IN -i "$BR" -s "$PREFIX" -j ACCEPT &&
  iptables -A EWISP_WAN -i "$STA" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT &&
  iptables -A EWISP_WAN -i "$STA" -j DROP &&
  iptables -A EWISP_FWD -i "$BR" -s "$PREFIX" -o "$STA" -j ACCEPT &&
  iptables -t nat -A EWISP_NAT -s "$PREFIX" -o "$STA" -j MASQUERADE &&
  iptables -t nat -A EWISP_DNS -s "$PREFIX" -d "$LAN" -p udp --dport 53 -j DNAT --to-destination "$LAN:5354" &&
  iptables -t nat -A EWISP_DNS -s "$PREFIX" -d "$LAN" -p tcp --dport 53 -j DNAT --to-destination "$LAN:5354" &&
  iptables -t mangle -A EWISP_MG -i "$STA" -j ACCEPT &&
  iptables -t mangle -A EWISP_OUT -d "$(value gateway)" -j ACCEPT &&
  ip6tables -A EWISP_V6 -i "$STA" -j DROP && ip6tables -A EWISP_V6 -o "$STA" -j DROP || return 1
  iptables -I INPUT 1 -j EWISP_IN && iptables -I FORWARD 1 -j EWISP_WAN && iptables -A FORWARD -j EWISP_FWD &&
  iptables -t nat -I PREROUTING 1 -j EWISP_DNS && iptables -t nat -I POSTROUTING 1 -j EWISP_NAT &&
  iptables -t mangle -I PREROUTING 1 -j EWISP_MG &&
  iptables -t mangle -I OUTPUT 1 -j EWISP_OUT &&
  ip6tables -I INPUT 1 -j EWISP_V6 && ip6tables -I FORWARD 1 -j EWISP_V6
}
unrules() {
  for spec in 'filter INPUT EWISP_IN' 'filter FORWARD EWISP_WAN' 'filter FORWARD EWISP_FWD' 'nat PREROUTING EWISP_DNS' 'nat POSTROUTING EWISP_NAT' 'mangle PREROUTING EWISP_MG' 'mangle OUTPUT EWISP_OUT'; do
    set -- $spec
    while iptables -t "$1" -C "$2" -j "$3" 2>/dev/null; do iptables -t "$1" -D "$2" -j "$3" || return 1; done
  done
  for spec in 'filter EWISP_IN' 'filter EWISP_WAN' 'filter EWISP_FWD' 'nat EWISP_NAT' 'nat EWISP_DNS' 'mangle EWISP_MG' 'mangle EWISP_OUT'; do set -- $spec; iptables -t "$1" -F "$2" 2>/dev/null; iptables -t "$1" -X "$2" 2>/dev/null; done
  for chain in INPUT FORWARD; do
    while ip6tables -C "$chain" -j EWISP_V6 2>/dev/null; do ip6tables -D "$chain" -j EWISP_V6 || return 1; done
  done
  ip6tables -F EWISP_V6 2>/dev/null; ip6tables -X EWISP_V6 2>/dev/null
  return 0
}
apply_runtime() {
  OLD=$(value old); GW=$(value gateway)
  rules || return 1
  write phase APPLYING || return 1
  brctl delif "$BR" "$STA" && iw dev "$STA" set 4addr off || return 1
  ip addr add "$LAN/24" dev "$BR" || return 1
  ip addr del "$OLD/24" dev "$BR" && ip addr add "$OLD/24" dev "$STA" || return 1
  ip route replace default via "$GW" dev "$STA" || return 1
  arping -U -I "$STA" -c 2 "$OLD" >/dev/null 2>&1 || return 1
  echo 1 > /proc/sys/net/ipv4/ip_forward || return 1
  dnsmasq --conf-file=/dev/null --keep-in-foreground --bind-interfaces --interface="$BR" \
    --listen-address="$LAN" --port=5354 --no-resolv --server=127.0.0.1#53 \
    --dhcp-authoritative --dhcp-range=192.168.50.100,192.168.50.199,255.255.255.0,2m \
    --dhcp-option=3,"$LAN" --dhcp-option=6,"$LAN" \
    --dhcp-leasefile="$RUN/leases" --pid-file="$RUN/dns.pid" > "$RUN/dns.log" 2>&1 &
  write dns_owner "$!" || return 1
  sleep 2
  kill -0 "$(value dns_owner)" 2>/dev/null || return 1
  write phase PENDING || return 1
  panel_update
  reconnect_clients
}
panel_update() {
  # A failed web service must never roll back a healthy network.
  [ ! -x "$BASE/service.sh" ] || "$BASE/service.sh" ensure >/dev/null 2>&1 || true
}
health_fail() { HEALTH_REASON=$1; HEALTH_SOFT=${2:-0}; return 1; }
healthy() {
  HEALTH_REASON=unknown; HEALTH_SOFT=0
  [ "$(value boot)" = "$(bootid)" ] || { health_fail boot_changed; return 1; }
  [ ! -d "/sys/class/net/$BR/brif/$STA" ] || { health_fail sta_rejoined_bridge; return 1; }
  ip -4 addr show dev "$BR" | grep -q "inet $LAN/24 " || { health_fail lan_address_missing; return 1; }
  ip -4 route show default | grep -q "^default via $(value gateway) dev $STA" || { health_fail default_route_changed; return 1; }
  kill -0 "$(value dns_owner)" 2>/dev/null || { health_fail dhcp_dns_process_dead; return 1; }
  iptables -C INPUT -j EWISP_IN && iptables -C FORWARD -j EWISP_WAN && iptables -C FORWARD -j EWISP_FWD &&
  iptables -t nat -C POSTROUTING -j EWISP_NAT && iptables -t nat -C PREROUTING -j EWISP_DNS &&
  iptables -t mangle -C PREROUTING -j EWISP_MG && iptables -t mangle -C OUTPUT -j EWISP_OUT && ip6tables -C FORWARD -j EWISP_V6 && ip6tables -C INPUT -j EWISP_V6 || { health_fail own_firewall_hooks_missing; return 1; }
  config_unchanged || { health_fail "${CONFIG_REASON:-config_changed}"; return 1; }
  iw dev "$STA" link | grep -q '^Connected to ' || { health_fail sta_disconnected 1; return 1; }
  ping -I "$STA" -c 1 -W 2 "$(value gateway)" >/dev/null 2>&1 || { health_fail gateway_ping_failed 1; return 1; }
}
restore_runtime() {
  [ -d "$RUN" ] || return 0
  [ "$(value boot)" = "$(bootid)" ] || { fail 'old boot journal: inspect manually'; return 1; }
  OLD=$(value old); GW=$(value gateway)
  ipv4 "$OLD" && ipv4 "$GW" || return 1
  rm -f "$BASE/enabled"; sync
  write phase ROLLING_BACK
  DP=$(value dns_owner)
  case "$DP" in ''|*[!0-9]*) ;; *)
    if [ -r "/proc/$DP/cmdline" ] && tr '\000' ' ' < "/proc/$DP/cmdline" | grep -Fq "$RUN/leases"; then kill "$DP" 2>/dev/null; fi;; esac
  RC=0
  ip addr del "$OLD/24" dev "$STA" 2>/dev/null || true
  iw dev "$STA" set 4addr on || RC=1
  [ -d "/sys/class/net/$BR/brif/$STA" ] || brctl addif "$BR" "$STA" || RC=1
  ip -4 addr show dev "$BR" | grep -q "inet $OLD/24 " || ip addr add "$OLD/24" dev "$BR" || RC=1
  ip route replace default via "$GW" dev "$BR" || RC=1
  arping -U -I "$BR" -c 2 "$OLD" >/dev/null 2>&1 || RC=1
  ip addr del "$LAN/24" dev "$BR" 2>/dev/null || true
  FWD=$(value forwarding)
  case "$FWD" in 0|1) echo "$FWD" > /proc/sys/net/ipv4/ip_forward || RC=1;; *) RC=1;; esac
  unrules || RC=1
  if [ "$RC" -eq 0 ]; then
    write phase ROLLED_BACK
    log 'rolled back; original persistent configuration was never modified'
    panel_update
    reconnect_clients
  else write phase RECOVERY_FAILED; log 'runtime recovery failed; persistent config unchanged'; fi
  return "$RC"
}
rollback_reason() {
  write reason "$1"
  printf '%s\n' "$1" > "$BASE/last-rollback-reason"
  restore
}

restore() {
  [ -d "$RUN" ] || return 0
  if ! mkdir "$RUN/restore.lock" 2>/dev/null; then
    RP=$(cat "$RUN/restore.lock/pid" 2>/dev/null)
    case "$RP" in ''|*[!0-9]*) return 1;; esac
    [ ! -d "/proc/$RP" ] || return 1
    rm -f "$RUN/restore.lock/pid"
    rmdir "$RUN/restore.lock" && mkdir "$RUN/restore.lock" || return 1
  fi
  echo $$ > "$RUN/restore.lock/pid"
  restore_runtime; RR=$?
  rm -f "$RUN/restore.lock/pid"
  rmdir "$RUN/restore.lock"
  return "$RR"
}
adopt_guard() {
  PREVIOUS=${1:-}
  [ "$(value phase)" = ACTIVE ] && [ -f "$BASE/enabled" ] &&
    [ "$(value boot)" = "$(bootid)" ] && [ "$(value guard)" = "$PREVIOUS" ] && alive "$PREVIOUS" || return 1
  healthy || return 1
  PREVIOUS_COMMAND=$(value guard-command); [ -n "$PREVIOUS_COMMAND" ] || PREVIOUS_COMMAND="$BASE/wisp.sh"
  kill -STOP "$PREVIOUS" || return 1
  # A detached rescue always thaws the previous process if takeover is interrupted.
  (trap '' HUP; sleep 15; alive "$PREVIOUS" && kill -CONT "$PREVIOUS"; :) </dev/null >/dev/null 2>&1 &
  if ! healthy || ! write guard "$$"; then kill -CONT "$PREVIOUS"; return 1; fi
  if ! write guard-command "$BASE/wisp.sh"; then write guard "$PREVIOUS"; kill -CONT "$PREVIOUS"; return 1; fi
  kill -KILL "$PREVIOUS" || { write guard-command "$PREVIOUS_COMMAND"; write guard "$PREVIOUS"; kill -CONT "$PREVIOUS"; return 1; }
  log 'active transaction adopted; network unchanged'
  write adopted "$WISP_VERSION"
}
guard() {
  trap '' HUP
  trap 'write rollback.request yes' INT TERM
  if [ -n "${1:-}" ]; then
    adopt_guard "$1" || exit 1
  else
  [ "$(value phase)" = STARTING ] && [ "$(value boot)" = "$(bootid)" ] || exit 1
  mkdir "$RUN/guard.lock" 2>/dev/null || exit 1
  trap '' HUP
  trap 'write rollback.request yes' INT TERM
  write guard "$$" || exit 1
  lock_switch || { write phase ABORTED; exit 1; }
  # Recheck the snapshot and vendor process after acquiring the shared lock.
  if ! config_unchanged || [ -f "$RUN/rollback.request" ] || pgrep -f 'wifiap_mode.sh check_gw|dhcp_apclient.sh start' >/dev/null; then
    write phase ABORTED; unlock_switch; exit 1
  fi
  log 'starting runtime WISP transaction'
  apply_runtime || { rollback_reason apply_failed; unlock_switch; exit 1; }
  case "$(value mode)" in
    test) write phase TEST; write test_end "$(( $(now) + $(value duration) ))"; unlock_switch;;
    boot) write phase ACTIVE; unlock_switch;;
  esac
  fi
  BAD=0; SOFT_SINCE=0; CONFIG_SINCE=0; LAST_REASON=
  while :; do
    [ ! -f "$RUN/rollback.request" ] || { rollback_reason manual; break; }
    PH=$(value phase)
    case "$PH" in
      PENDING)
        if [ "$(now)" -ge "$(value deadline)" ]; then log 'confirmation timeout'; rollback_reason confirmation_timeout; break; fi
        if [ -f "$RUN/confirm.request" ]; then
          if healthy; then printf '%s\n' "$(value reconnect)" > "$BASE/reconnect.new" && mv "$BASE/reconnect.new" "$BASE/reconnect" && printf '%s\n' enabled > "$BASE/enabled.new" && mv "$BASE/enabled.new" "$BASE/enabled" || { restore; break; }; sync; write phase ACTIVE; unlock_switch; log 'confirmed; persistent boot enabled';
          else restore; break; fi
        fi;;
      TEST) if [ "$(now)" -ge "$(value test_end)" ]; then log 'test timer expired'; rollback_reason test_complete; break; fi;;
      ACTIVE) ;;
      *) restore; break;;
    esac
    HEALTH_REASON=unknown; HEALTH_SOFT=0
    if healthy; then
      [ -z "$LAST_REASON" ] || log "health recovered after $LAST_REASON"
      BAD=0; SOFT_SINCE=0; CONFIG_SINCE=0; LAST_REASON=
    else
      if [ "$LAST_REASON" != "$HEALTH_REASON" ]; then
        log "health failed: $HEALTH_REASON; transient=$HEALTH_SOFT"
        LAST_REASON=$HEALTH_REASON
      fi
      case "$HEALTH_REASON" in
      config_changed*|config_check_error)
        BAD=0; SOFT_SINCE=0
        [ "$CONFIG_SINCE" != 0 ] || CONFIG_SINCE=$(now)
        if [ "$(( $(now) - CONFIG_SINCE ))" -ge 30 ]; then
          printf '%s\n' "$HEALTH_REASON" > "$BASE/last-rollback-reason"
          log "rollback: configuration check failed for 30 seconds: $HEALTH_REASON"; rollback_reason "$HEALTH_REASON"; break
        fi;;
      *)
      CONFIG_SINCE=0
      if [ "$HEALTH_SOFT" = 1 ]; then
        BAD=0
        [ "$SOFT_SINCE" != 0 ] || SOFT_SINCE=$(now)
        [ "$(( $(now) - SOFT_SINCE ))" -lt 120 ] || { printf '%s\n' "$HEALTH_REASON" > "$BASE/last-rollback-reason"; log "rollback: connectivity failure for 120 seconds: $HEALTH_REASON"; rollback_reason "$HEALTH_REASON"; break; }
      else
        SOFT_SINCE=0; BAD=$((BAD + 1))
        [ "$BAD" -lt 3 ] || { printf '%s\n' "$HEALTH_REASON" > "$BASE/last-rollback-reason"; log "rollback: three critical health failures: $HEALTH_REASON"; rollback_reason "$HEALTH_REASON"; break; }
      fi
      ;;
      esac
    fi
    sleep 5
  done
  unlock_switch
}
start() {
  preflight || return 1
  snapshot || { fail 'snapshot failed; network unchanged'; return 1; }
  write mode "${WISP_MODE:-normal}" && write duration "${WISP_DURATION:-180}" || return 1
  write reconnect "${WISP_RECONNECT:-0}" || return 1
  write phase STARTING || return 1
  echo "Reconnect by Wi-Fi or cable; open https://$LAN:8443/ ."
  echo "Within 180 seconds: sh $BASE/wisp.sh confirm $TOKEN"
  start-stop-daemon -S -b -m -p "$RUN/launcher.pid" -x /bin/sh -- -c 'unset WISP_LIBRARY; exec sh "$1/wisp.sh" _guard </dev/null >>"$2/guard.log" 2>&1 9>&-' wisp-launch "$BASE" "$RUN" || { write phase ABORTED; return 1; }
  log 'guard scheduled'
}
confirm() {
  [ "$(value phase)" = PENDING ] || { fail no_pending_transaction; return 1; }
  [ "${1:-}" = "$(value token)" ] || { fail wrong_transaction; return 1; }
  [ "$(now)" -lt "$(value deadline)" ] || { fail confirmation_expired; return 1; }
  if [ "${WISP_ORIGIN:-ssh}" = panel ]; then
    # HTTP_HOST preserves the browser destination; SERVER_ADDR changes after DNAT.
    case "${HTTP_HOST:-}" in "$LAN:8443") ;; *) fail new_lan_required; return 1;; esac
    set -- "${REMOTE_ADDR:-}" 0 "$LAN" 0
  else
    set -- ${SSH_CONNECTION:-}
  fi
  [ "$#" -eq 4 ] && [ "$3" = "$LAN" ] || { fail new_lan_required; return 1; }
  ipv4 "$1" && [ "${1%.*}" = 192.168.50 ] || return 1
  case "$1" in "$LAN"|192.168.50.0|192.168.50.255) return 1;; esac
  [ "$(value boot)" = "$(bootid)" ] && alive "$(value guard)" || return 1
  write confirm.request yes
  echo 'Confirmation requested; check status for ACTIVE.'
}
tick() {
  if [ -f "$BASE/removing" ]; then sh "$BASE/uninstall.sh" resume; return $?; fi
  [ -d "$RUN" ] || { boot_resume; return $?; }
  case "$(value phase)" in STARTING|PENDING|ACTIVE|TEST|APPLYING)
    if ! alive "$(value guard)"; then
      [ "$(value phase)" != STARTING ] || [ "$(now)" -ge "$(( $(value deadline) - 165 ))" ] || return 0
      mkdir "$RUN/recover.lock" 2>/dev/null || return 1
      restore; RC=$?; rmdir "$RUN/recover.lock"; return "$RC"
    fi;; esac
}
vendor_check() {
  if [ -f "$BASE/removing" ]; then tick; return $?; fi
  tick || return 1
  case "$(value phase)" in SNAPSHOT|STARTING|PENDING|ACTIVE|TEST|APPLYING|ROLLING_BACK|RECOVERY_FAILED) return 0;; esac
  /usr/sbin/wifiap_mode.sh check_gw
}
boot_resume() {
  [ -f "$BASE/enabled" ] || return 0
  [ ! -f /tmp/wisp-boot-attempt ] || return 0
  # Wait for the stock STA to be ready. Never change persistent network UCI.
  [ "$(now)" -ge 30 ] || return 0
  WISP_ORIGIN=boot; WISP_MODE=boot
  WISP_RECONNECT=$(cat "$BASE/reconnect" 2>/dev/null || echo 0)
  case "$WISP_RECONNECT" in 0|1) ;; *) WISP_RECONNECT=0;; esac
  if preflight; then
    printf '%s\n' "$(bootid)" > /tmp/wisp-boot-attempt
    start
  elif [ "$(now)" -ge 600 ]; then
    printf '%s\n' "$(bootid)" > /tmp/wisp-boot-attempt
    rm -f "$BASE/enabled"; sync; log 'boot readiness timeout; persistent WISP disabled'
  fi
}
test_start() {
  case "${1:-}" in ''|*[!0-9]*) fail 'test duration: integer seconds'; return 1;; esac
  [ "$1" -ge 60 ] && [ "$1" -le 3600 ] || { fail 'test duration 60..3600 seconds'; return 1; }
  [ ! -f "$BASE/enabled" ] || { fail disable_before_test; return 1; }
  WISP_MODE=test; WISP_DURATION=$1; start
}
[ "${WISP_LIBRARY:-0}" != 1 ] || return 0
case "${1:-}" in
  plan) preflight && echo "Runtime IPv4 WISP: $STA uplink $OLD/24 gateway $GW; LAN $LAN/24. No network UCI commits. Reboot returns original bridge.";;
  start) start;;
  test) test_start "${2:-}";;
  _guard) [ -d "$RUN" ] && guard "${2:-}";;
  confirm) confirm "${2:-}";;
  rollback) rm -f "$BASE/enabled"; sync; if alive "$(value guard)" || [ "$(value phase)" = STARTING ]; then write rollback.request yes; echo 'Rollback requested'; else restore; fi;;
  tick) tick;;
  vendor-check) vendor_check;;
  status) echo "version=$WISP_VERSION"; echo "phase=$(value phase)"; echo "lan=$LAN"; echo "guard=$(value guard)"; echo "deadline_uptime=$(value deadline)";;
  reset) if alive "$(value guard)"; then fail 'guard still running'; exit 1; fi; case "$(value phase)" in ROLLED_BACK|ABORTED|SNAPSHOT) rm -rf "$RUN";; *) fail 'rollback before reset'; exit 1;; esac;;
  *) echo "Usage: $0 plan|start|status|confirm TOKEN|rollback|reset"; exit 2;;
esac
