#!/bin/sh
# Network remains unchanged; an active guard must first be rolled back.
set -eu
umask 077
BASE=/data/usr/app/wisp
RUN=/tmp/wisp
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LANGUAGE=${1:-}
if [ -z "$LANGUAGE" ]; then
 printf 'Panel language / Язык панели [ru/en]: '
 read -r LANGUAGE
fi
case "$LANGUAGE" in ru|en) ;; *) echo 'Choose ru or en'; exit 2;; esac
[ "$(id -u)" = 0 ] || exit 1
# Refuse competing WISP deployments, including installations under another name.
for D in /data/usr/app/*; do
 [ "$D" = "$BASE" ] && continue
 if [ -f "$D/wisp.sh" ] && [ -f "$D/wisp-config.sh" ] && [ -f "$D/VERSION" ]; then
  echo 'Another WISP installation exists. Restore the network and remove it before installing.'
  exit 1
 fi
done
[ "$(uci -q get /usr/share/xiaoqiang/xiaoqiang_version.version.HARDWARE)" = RN02 ] || exit 1
[ "$(uci -q get /usr/share/xiaoqiang/xiaoqiang_version.version.ROM)" = 1.0.64 ] || exit 1
[ ! -f "$BASE/removing" ] || exit 1
[ ! -f "$BASE/enabled" ] || { echo 'Disable WISP before upgrading'; exit 1; }
case "$(cat "$RUN/phase" 2>/dev/null || true)" in ''|ROLLED_BACK|ABORTED|SNAPSHOT) ;; *) echo 'Rollback WISP first'; exit 1;; esac
for C in nginx openssl fcgi-cgi sha256sum flock ip; do command -v "$C" >/dev/null || exit 1; done
[ -r /etc/shadow ] || exit 1
H=$(awk -F: '$1=="root"{print $2;exit}' /etc/shadow)
case "$H" in \$1\$*|\$5\$*|\$6\$*) ;; *) echo 'Set a non-empty root SSH password first'; exit 1;; esac
[ "$(grep -c '/usr/sbin/wifiap_mode.sh check_gw\|wisp/wisp.sh vendor-check' /etc/crontabs/root)" = 1 ] || exit 1
[ "$(df -k /data | tail -1 | awk '{print $(NF-2)}')" -ge 512 ] || { echo '512 KiB free required'; exit 1; }
(cd "$HERE" && sha256sum -c SHA256SUMS)
for F in wisp.sh wisp-config.sh panel.sh api.sh clients.sh service.sh uninstall.sh; do sh -n "$HERE/$F"; done
# Serialize installation and panel mutations. No persistent network UCI changes.
mkdir -p "$BASE"; chmod 700 "$BASE"
exec 9>"$BASE/panel.lock"; flock -n 9 || exit 1
[ ! -f "$BASE/removing" ] || exit 1
[ ! -f "$BASE/enabled" ] || exit 1
T=$(mktemp -d /tmp/wisp-install.XXXXXX)
COMMITTED=0
cleanup() {
 if [ "$COMMITTED" = 0 ] && [ -f "$T/targets" ]; then
  [ ! -x "$BASE/service.sh" ] || "$BASE/service.sh" stop || true
  while read N D; do if [ -f "$T/$N" ]; then cp -p "$T/$N" "$D"; else rm -f "$D"; fi; done < "$T/targets"
  [ ! -x "$BASE/service.sh" ] || "$BASE/service.sh" ensure || true
 fi
 rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
N=0
save() { N=$((N+1)); [ ! -f "$1" ] || cp -p "$1" "$T/$N"; printf '%s %s\n' "$N" "$1" >> "$T/targets"; }
mkdir -p "$BASE/web"
for F in wisp.sh wisp-config.sh panel.sh api.sh clients.sh service.sh uninstall.sh nginx.conf.in VERSION language locale.sh web/locale.js tls.crt tls.key web/index.html web/style.css web/app.js action.fragment README.md; do save "$BASE/$F"; done
save /etc/crontabs/root
# One compressed recovery archive; no accumulating version directories.
tar -czf "$BASE/install-backup.tgz" -C "$T" .
if [ ! -r "$BASE/tls.key" ] || [ ! -r "$BASE/tls.crt" ]; then
 LANIP=$(ip -4 addr show dev br-lan | awk '/inet /{sub(/\/.*/,"",$2);print $2}')
 printf '%s\n' "$LANIP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || exit 1
 openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -subj '/CN=WISP local panel' -addext "subjectAltName=IP:192.168.50.1,IP:$LANIP" -keyout "$T/tls.key" -out "$T/tls.crt" >/dev/null 2>&1
 cp "$T/tls.key" "$BASE/tls.key"; cp "$T/tls.crt" "$BASE/tls.crt"
fi
[ ! -x "$BASE/service.sh" ] || "$BASE/service.sh" stop
for F in wisp.sh wisp-config.sh panel.sh api.sh clients.sh service.sh uninstall.sh nginx.conf.in VERSION web/index.html web/style.css web/app.js; do
 cp "$HERE/$F" "$BASE/$F.new"; chmod 600 "$BASE/$F.new"; mv "$BASE/$F.new" "$BASE/$F"
done
cp "$HERE/locales/$LANGUAGE/locale.sh" "$BASE/locale.sh"
cp "$HERE/locales/$LANGUAGE/locale.js" "$BASE/web/locale.js"
printf '%s\n' "$LANGUAGE" > "$BASE/language"
chmod 600 "$BASE/locale.sh" "$BASE/web/locale.js" "$BASE/language"
chmod 700 "$BASE"/*.sh
awk '{if($0 ~ /\/usr\/sbin\/wifiap_mode\.sh check_gw/) print "*/1 * * * * /data/usr/app/wisp/wisp.sh vendor-check"; else if($0 !~ /wisp\/wisp.sh tick|wisp\/service.sh ensure/) print}' /etc/crontabs/root > "$T/cron"
echo '*/1 * * * * /data/usr/app/wisp/wisp.sh tick >/dev/null 2>&1' >> "$T/cron"
echo '*/1 * * * * /data/usr/app/wisp/service.sh ensure >/dev/null 2>&1' >> "$T/cron"
cat "$T/cron" > /etc/crontabs/root
touch /etc/crontabs
"$BASE/service.sh" ensure 9>&-
sync; COMMITTED=1
echo 'Installed. WISP remains OFF. Open https://<LAN-IP>:8443/; login root with SSH password.'
echo 'Private recovery archive: /data/usr/app/wisp/install-backup.tgz'
