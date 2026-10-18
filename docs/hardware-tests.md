# Verification scope

Target: Xiaomi Router BE6500 RN02, stock MiWiFi 1.0.64. RD08 and other models/firmware are not verified. Prior versions were exercised on this RN02; this version must have its own recorded validation.

Isolated tests mock network/system mutations and check recovery, API authentication, UI, installers and removal. Hardware checks are recorded separately. Client deauthentication, full live removal and reboot are disruptive and are not implied by read-only checks.

Use a local connection and keep SSH access plus a private backup. Install first with WISP off. Review diagnostics before activation; reconnect and confirm within three minutes only after checking internet and LAN access. Do not install during a pending transaction.
