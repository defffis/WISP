#!/bin/sh
# Network invariants. LED schedules are deliberately outside this contract.
config_changed_reason() {
  [ "$CONFIG_REASON" != config_check_error ] || CONFIG_REASON=config_changed
  CONFIG_REASON="${CONFIG_REASON}_$1"
}
config_unchanged() {
  CONFIG_REASON=config_check_error
  CONFIG_BAD=0
  # Keep full-file protection for actual network configs. Retain the original
  # five-file snapshot for diagnostics and compatibility with existing journals.
  # Each of the four expected records MUST be present exactly once and pass.
  CONFIG_REPORT=$( (cd /etc/config &&
    awk '$2=="network" || $2=="wireless" || $2=="dhcp" || $2=="firewall"' "$RUN/config.sha256" |
      sha256sum -c -) 2>&1) || CONFIG_BAD=1
  for CF in network wireless dhcp firewall; do
    if [ "$(printf '%s\n' "$CONFIG_REPORT" | grep -c "^$CF: OK$")" != 1 ]; then
      CONFIG_BAD=1
      if printf '%s\n' "$CONFIG_REPORT" | grep -q "^$CF: FAILED"; then
        config_changed_reason "$CF"
      fi
    fi
  done
  # The vendor LED scheduler legitimately commits xiaoqiang every night/day.
  # Only compare the invariants required by preflight and runtime topology.
  # Read failures fail closed; never print configuration values or credentials.
  for CK in NETMODE active_apcli; do
    case "$CK" in NETMODE) EXPECTED=wifiapmode;; active_apcli) EXPECTED=$STA;; esac
    if CV=$(uci -q get "xiaoqiang.common.$CK"); then
      if [ "$CV" != "$EXPECTED" ]; then
        CONFIG_BAD=1
        config_changed_reason "xiaoqiang_$CK"
        CONFIG_REPORT="$CONFIG_REPORT
xiaoqiang.common.$CK: CHANGED"
      fi
    else
      CONFIG_BAD=1
      CONFIG_REPORT="$CONFIG_REPORT
xiaoqiang.common.$CK: READ_FAILED"
    fi
  done
  [ "$CONFIG_BAD" = 0 ] && return 0
  # Diagnostics contain key names and checksum status, never option values.
  { printf 'uptime=%s\n' "$(now)"; printf '%s\n' "$CONFIG_REPORT"; } > "$BASE/config-health.log.new"
  mv "$BASE/config-health.log.new" "$BASE/config-health.log"
  return 1
}
