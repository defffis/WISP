#!/bin/sh
# Real UCI + real checksum tests against private fixtures. No live UCI writes.
set -eu
CANDIDATE=$1
WISP_LIBRARY=1
export WISP_LIBRARY
. "$CANDIDATE"
set -eu
T=$(mktemp -d /tmp/wisp-config-test.XXXXXX)
trap 'rm -rf "$T"' EXIT HUP INT TERM
BASE="$T/base"
RUN="$T/run"
mkdir -p "$BASE" "$RUN" "$T/live"
# Redirect reads made by the production check into fixtures, in this shell only.
cd() {
  if [ "${1:-}" = /etc/config ]; then command cd "$T/live"; else command cd "$@"; fi
}
uci() { command uci -c "$T/live" "$@"; }
reset_fixture() {
  for CF in network wireless dhcp firewall; do printf 'original-%s\n' "$CF" > "$T/live/$CF"; done
  cat > "$T/live/xiaoqiang" <<'EOF'
config xiaoqiang 'common'
 option NETMODE 'wifiapmode'
 option active_apcli 'wl02'
 option BLUE_LED '0'
 option BLUE_LED_TIMER '1'
EOF
  (command cd "$T/live"; sha256sum network wireless dhcp firewall xiaoqiang) > "$RUN/config.sha256"
}
PASS=0
expect_ok() {
  if ! config_unchanged; then echo "FAIL expected pass: $1 ($CONFIG_REASON)"; exit 1; fi
  PASS=$((PASS+1)); echo "PASS $1"
}
expect_bad() {
  if config_unchanged; then echo "FAIL expected refusal: $1"; exit 1; fi
  [ "$CONFIG_REASON" = "$2" ] || { echo "FAIL wrong reason: $CONFIG_REASON, expected $2"; exit 1; }
  PASS=$((PASS+1)); echo "PASS $1"
}
edit() { sed "$1" "$T/live/xiaoqiang" > "$T/edited"; mv "$T/edited" "$T/live/xiaoqiang"; }
reset_fixture
expect_ok baseline
edit "s/BLUE_LED '0'/BLUE_LED '1'/"
expect_ok scheduled_LED_on
edit "s/BLUE_LED '1'/BLUE_LED '0'/"
expect_ok scheduled_LED_off
printf " option BLUE_LED_TIMER_OPEN '07:00'\n option BLUE_LED_TIMER_CLOSE '22:00'\n option ROUTER_NAME 'renamed'\n" >> "$T/live/xiaoqiang"
expect_ok LED_schedule_and_router_name
edit "s/NETMODE 'wifiapmode'/NETMODE 'router'/"
expect_bad real_network_mode_change config_changed_xiaoqiang_NETMODE
reset_fixture
edit "s/active_apcli 'wl02'/active_apcli 'wl99'/"
expect_bad STA_selection_change config_changed_xiaoqiang_active_apcli
reset_fixture
edit '/option NETMODE/d'
expect_bad missing_NETMODE config_check_error
reset_fixture
edit '/option active_apcli/d'
expect_bad missing_STA config_check_error
reset_fixture
printf "config 'unterminated\n" > "$T/live/xiaoqiang"
expect_bad malformed_UCI config_check_error
reset_fixture
rm "$T/live/xiaoqiang"
expect_bad missing_UCI_package config_check_error
for target in network wireless dhcp firewall; do
  reset_fixture
  printf 'modified\n' >> "$T/live/$target"
  expect_bad "changed_$target" "config_changed_$target"
done
reset_fixture
rm "$RUN/config.sha256"
expect_bad missing_snapshot_manifest config_check_error
reset_fixture
sed '/ network$/d' "$RUN/config.sha256" > "$T/manifest"
mv "$T/manifest" "$RUN/config.sha256"
expect_bad missing_network_checksum config_check_error
reset_fixture
grep ' network$' "$RUN/config.sha256" >> "$RUN/config.sha256.extra"
cat "$RUN/config.sha256.extra" >> "$RUN/config.sha256"
expect_bad duplicate_network_checksum config_check_error
reset_fixture
edit "s/NETMODE 'wifiapmode'/NETMODE 'router'/"
edit "s/active_apcli 'wl02'/active_apcli 'wl99'/"
expect_bad multiple_network_invariants config_changed_xiaoqiang_NETMODE_xiaoqiang_active_apcli
reset_fixture
expect_ok restoration_to_valid_state
echo "ALL $PASS CONFIG GUARD TESTS PASSED"
