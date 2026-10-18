#!/bin/sh
# Only a fixed FastCGI route reaches this file; no user-controlled shell evaluation.
set -u
umask 077
BASE=/data/usr/app/wisp
text() { printf '%s' "$1"; }
[ ! -r "$BASE/locale.sh" ] || . "$BASE/locale.sh"
WEBRUN=/tmp/wisp-panel
reject() {
 printf 'Status: %s\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\n\r\n{"ok":false,"msg":"%s"}\n' "$1" "$2"
 exit 0
}
[ "${REMOTE_USER:-}" = root ] && [ "${HTTPS:-}" = on ] || reject '401 Unauthorized' "$(text m42)"
[ "${SERVER_PORT:-}" = 8443 ] && [ "${HTTP_HOST:-}" = "${SERVER_ADDR:-}:8443" ] || reject '403 Forbidden' "$(text m43)"
# Authenticated LAN clients only. Never trust X-Forwarded-For from a browser.
PEER=${REMOTE_ADDR:-}
printf '%s\n' "$PEER" | awk -F. 'NF!=4{exit 1} {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i+0>255) exit 1}' || reject '403 Forbidden' "$(text m44)"
[ "${PEER%.*}" = "${SERVER_ADDR%.*}" ] && ip -4 route get "$PEER" | grep -q ' dev br-lan ' || reject '403 Forbidden' "$(text m44)"
CSRF=$(cat "$WEBRUN/csrf" 2>/dev/null || true)
case "$CSRF" in ''|*[!a-f0-9]*) reject '503 Unavailable' "$(text m45)";; esac
[ "${#CSRF}" = 32 ] || reject '503 Unavailable' "$(text m45)"
OP=
case "${REQUEST_METHOD:-}" in
 GET) [ "${QUERY_STRING:-}" = status ] || reject '400 Bad Request' "$(text m46)"; OP=status;;
 POST)
  [ "${HTTP_ORIGIN:-}" = "https://${HTTP_HOST}" ] && [ "${HTTP_X_WISP_CSRF:-}" = "$CSRF" ] || reject '403 Forbidden' "$(text m47)"
  [ "${CONTENT_TYPE:-}" = text/plain ] && [ -z "${QUERY_STRING:-}" ] || reject '415 Unsupported Media Type' "$(text m48)"
  N=${CONTENT_LENGTH:-0}; case "$N" in ''|*[!0-9]*|????*) reject '413 Payload Too Large' "$(text m49)";; esac
  [ "$N" -gt 0 ] && [ "$N" -le 96 ] || reject '413 Payload Too Large' "$(text m49)"
  BODY=$(dd bs=1 count="$N" 2>/dev/null)
  [ "${#BODY}" = "$N" ] || reject '400 Bad Request' "$(text m48)"
  case "$BODY" in
   check|start|rollback|reconnect) OP=$BODY;;
   uninstall\ DELETE) OP=uninstall;;
   confirm\ *) ARG=${BODY#confirm }; case "$ARG" in ''|*[!0-9a-f]*) reject '400 Bad Request' "$(text m50)";; esac
    [ "${#ARG}" = 32 ] || reject '400 Bad Request' "$(text m50)"; OP=confirm;;
   *) reject '400 Bad Request' "$(text m46)";;
  esac;;
 *) reject '405 Method Not Allowed' "$(text m51)";;
esac
printf 'Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nX-WISP-CSRF: %s\r\n\r\n' "$CSRF"
case "$OP" in uninstall) exec sh "$BASE/uninstall.sh" queue DELETE;; confirm) exec sh "$BASE/panel.sh" confirm "$ARG";; *) exec sh "$BASE/panel.sh" "$OP";; esac
