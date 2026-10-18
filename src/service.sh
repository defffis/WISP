#!/bin/sh
set -eu
umask 077
BASE=/data/usr/app/wisp
WEBRUN=/tmp/wisp-panel
mkdir -p "$WEBRUN"; chmod 700 "$WEBRUN"
[ ! -f "$WEBRUN/error.log" ] || [ "$(wc -c < "$WEBRUN/error.log")" -le 8192 ] || : > "$WEBRUN/error.log"
exec 8>"$WEBRUN/lock"
flock -n 8 || exit 0
pid_alive() {
 P=$(cat "$WEBRUN/nginx.pid" 2>/dev/null || true)
 case "$P" in ''|*[!0-9]*) return 1;; esac
 [ -r "/proc/$P/cmdline" ] && tr '\000' ' ' < "/proc/$P/cmdline" | grep -Fq "$WEBRUN/nginx.conf"
}
stop() {
 if pid_alive; then kill -QUIT "$P"; fi
 rm -f "$WEBRUN/address"
}
case "${1:-}" in
 stop) stop; exit 0;;
 ensure) [ ! -f "$BASE/removing" ] || exit 0;;
 *) echo 'Usage: service.sh ensure|stop'; exit 2;;
esac
# Fail closed on missing, empty or locked system account password.
HASH=$(awk -F: '$1=="root"{print $2;exit}' /etc/shadow)
case "$HASH" in \$1\$*|\$5\$*|\$6\$*) ;; *) stop; exit 1;; esac
printf 'root:%s\n' "$HASH" > "$WEBRUN/auth.new"
if ! cmp -s "$WEBRUN/auth.new" "$WEBRUN/auth"; then mv "$WEBRUN/auth.new" "$WEBRUN/auth"; else rm -f "$WEBRUN/auth.new"; fi
IP=$(ip -4 addr show dev br-lan | awk '/inet /{sub(/\/.*/,"",$2);print $2}')
printf '%s\n' "$IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { stop; exit 1; }
[ -r "$BASE/tls.crt" ] && [ -r "$BASE/tls.key" ] || { stop; exit 1; }
if pid_alive && [ "$(cat "$WEBRUN/address" 2>/dev/null)" = "$IP" ]; then exit 0; fi
stop
# Rebind only to the current LAN address, never 0.0.0.0 or IPv6.
sed -e "s|__BASE__|$BASE|g" -e "s|__RUN__|$WEBRUN|g" -e "s|__IP__|$IP|g" "$BASE/nginx.conf.in" > "$WEBRUN/nginx.conf"
tr -d '-' < /proc/sys/kernel/random/uuid > "$WEBRUN/csrf"
/usr/sbin/nginx -t -p "$WEBRUN/" -c "$WEBRUN/nginx.conf" 8>&-
# Wait briefly for the previous worker to release its socket.
sleep 1
/usr/sbin/nginx -p "$WEBRUN/" -c "$WEBRUN/nginx.conf" 8>&-
printf '%s\n' "$IP" > "$WEBRUN/address"
