# WISP

**English** · [Русский](README.ru.md)

A compact, authenticated WISP/NAT panel for **Xiaomi Router BE6500 RN02 running stock MiWiFi 1.0.64**. The router receives internet over Wi-Fi and shares a separate local network. Installation leaves WISP off.

Other models, including RD08, and other firmware versions are unverified. An existing working stock wireless repeater connection is required. No firmware flashing, unlocking or persistent network UCI changes.

## Install

1. Download and fully extract `WISP-0.6.0-Windows-installer.zip` from the [latest release](https://github.com/defffis/WISP/releases/tag/v0.6.0).
2. Run `Install-WISP.bat`. Select `ru` or `en` for the installer, panel and its messages. Only the selected localization is installed on the router.
3. Enter the current router IP and SSH port. Verify the SSH host key on first connection; enter the root password directly into SSH.
4. Open `https://<router-IP>:8443/` and sign in with **root and the current SSH password**. Verify the self-signed local certificate through a trusted connection.

From SSH, use `sh install-wisp-0.6.0.sh en` or `sh install-wisp-0.6.0.sh ru`. The installer verifies SHA256, model, firmware, free space and state. Turn WISP off before a normal upgrade; active upgrades are rejected. Reinstall with another language to replace the installed localization.

If another WISP installation uses a different directory, restore and remove that installation first. The installer refuses parallel deployments.

## Use

Choose **Check connection compatibility**, then **Turn WISP on**. The LAN changes to **192.168.50.0/24** and the panel moves to **https://192.168.50.1:8443/**. Reconnect to Wi-Fi, verify internet and local access, then confirm **within three minutes**. Without confirmation, the local guard restores the previous network. Only confirmation enables WISP startup after reboot.

**Turn WISP off** restores standard repeater mode. **Reconnect all Wi-Fi clients** works with WISP both on and off. It disconnects only clients on the two local APs; wired devices and the upstream Wi-Fi connection remain connected. DHCP renewal depends on the client and may keep the same IP address. Reconnection is unavailable during network transitions.

**Remove WISP completely** is available in every state. Type `DELETE` in the English panel or `УДАЛИТЬ` in the Russian panel. Startup is disabled and the previous network recovered before owned files, tasks, keys and journals are deleted. Recovery failures retain data for another attempt. The release includes a standalone **Uninstall-WISP.bat**, which works without the panel or code downloads.

## Safety and limits

All pages, localization assets and API routes require authentication. Mutations additionally check LAN origin and CSRF. Configuration snapshots and TLS material are private; never publish them.

The guard checks STA, gateway, addresses, routes, owned firewall rules, DHCP/DNS process and meaningful network settings. LED schedules and web panel outages do not trigger network recovery.

IPv4 and an original /24 LAN are supported; IPv6 through WISP is blocked. Complex routing is unsupported. No internet-facing access is intended. Existing nginx, OpenSSL, dnsmasq and BusyBox are reused; no additional router binaries are installed.

[Architecture](docs/integration.md) · [Verification scope and safe testing](docs/hardware-tests.md) · [Changes](CHANGELOG.md)

Technical reference: [xiaomi-tp-link-relay-nas](https://github.com/be6500-relay-nas/xiaomi-tp-link-relay-nas). Results for other hardware revisions do not establish RN02 compatibility.
