# Verification scope

Target: Xiaomi Router BE6500 RN02, stock MiWiFi 1.0.64. RD08 and other models/firmware are not verified. Prior versions were exercised on this RN02; this version must have its own recorded validation.

Isolated tests mock network/system mutations and check recovery, API authentication, UI, installers and removal. Hardware checks are recorded separately. Client deauthentication, full live removal and reboot are disruptive and are not implied by read-only checks.

Use a local connection and keep SSH access plus a private backup. Install first with WISP off. Review diagnostics before activation; reconnect and confirm within three minutes only after checking internet and LAN access. Do not install during a pending transaction.

## 0.6.0 device results

Installed on RN02 / stock 1.0.64 with the confirmed connection preserved as ACTIVE. The new guard owns the existing network journal. IP addresses, routes and Wi-Fi association were preserved; only the owned DHCP/DNS process was restarted with existing leases to move its paths. All five network configuration files were unchanged.

The installed Russian shell/browser localization matches its source hashes; the English pack is absent from the router. Source, state and cron now use neutral WISP paths. Previous WISP files, aliases and staging files were removed after verification. A private full backup is retained on the operator PC, outside this repository. Installed usage: 132 KiB; /data free: 3252 KiB at the check.

Native sh passed 20 isolated removal scenarios and production client functions with AP commands replaced, for ACTIVE/OFF/ROLLED_BACK/ABORTED plus transition/removal rejection. Live dry-run found eight AP clients without disconnecting them. Browser desktop/mobile previews of the authenticated live panel passed through a local read-only proxy; credentials were restricted to the router origin. HTML, localization and API reject anonymous requests; malformed removal, foreign Origin and wrong CSRF were rejected.

Client checks passed DNS53 UDP/TCP, A/AAAA, NXDOMAIN, DNS5354, OS DNS, primary router access, public HTTPS and mandatory panel login with its pinned certificate. Public probes loaded no router credentials.

**Not performed on the working network:** mass Wi-Fi deauthentication in either mode, full live removal, a new enable/confirm/disable cycle, or a physical reboot. These are covered only by the specified isolated scenarios and prior version evidence; no broader hardware compatibility is claimed. English UI/backend and installation were verified in isolation, not by changing the live router language.
