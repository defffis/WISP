# Architecture

BusyBox shell controls the existing wl02 station and wl1/wl0 access points. No firmware flashing, unlocking or UCI commits. A separate nginx instance binds HTTPS 8443 to the current LAN address; all UI files and API require root Basic authentication. POST requests also require the exact local Origin and a CSRF token.

Guard checks STA, gateway, address, route, own firewall rules, DNS/DHCP process and meaningful network configuration. LED and night schedules do not trigger recovery. Activation requires confirmation within 180 seconds. Unconfirmed activation returns to the stock repeater after a reboot. Confirmed WISP resumes through its own cron job.

Private state: /data/usr/app/wisp; volatile journal: /tmp/wisp; web state: /tmp/wisp-panel. Only the selected locale.sh and web/locale.js are installed.

Wi-Fi client reconnection is available in ACTIVE, OFF, ROLLED_BACK and ABORTED states, and rejects transitions or removal. Only MAC addresses enumerated from the two LAN APs are deauthenticated. DHCP renewal depends on the client and does not guarantee a different address.

Removal first disables startup and recovers the previous network; on uncertainty it retains recovery files. The Windows removal BAT embeds its recovery payload.
