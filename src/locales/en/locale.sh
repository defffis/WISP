#!/bin/sh
text() {
 case "$1" in
  m42) printf '%s' 'Sign in required.';;
  m43) printf '%s' 'Open the panel using the router IP address.';;
  m44) printf '%s' 'A local connection is required.';;
  m45) printf '%s' 'The panel is starting.';;
  m46) printf '%s' 'Unknown action.';;
  m47) printf '%s' 'Refresh the page.';;
  m48) printf '%s' 'Invalid request.';;
  m49) printf '%s' 'Request too large.';;
  m50) printf '%s' 'Invalid confirmation.';;
  m51) printf '%s' 'Invalid method.';;
  m52) printf '%s' '{"ok":false,"msg":"Reconnection is unavailable while the network is changing."}';;
  m53) printf '%s' '{"ok":false,"msg":"Reconnection is already running."}';;
  m54) printf '%s' '{"ok":false,"msg":"Could not start reconnection."}';;
  m55) printf '%s' 'Test complete. Previous network restored.';;
  m56) printf '%s' 'Previous network restored.';;
  m57) printf '%s' 'Connection was not confirmed in time. Previous network restored.';;
  m58) printf '%s' 'Xiaomi RN02 with firmware 1.0.64 is required.';;
  m59) printf '%s' 'The stock wireless repeater mode is required.';;
  m60) printf '%s' 'No upstream Wi-Fi connection. Check the router connection.';;
  m61) printf '%s' 'Network 192.168.50.0/24 is already in use. Resolve the address conflict first.';;
  m62) printf '%s' 'There are pending network settings. Finish editing and try again.';;
  m63) printf '%s' 'The router is switching connections. Wait and try again.';;
  m64) printf '%s' 'After reconnecting, open the panel at 192.168.50.1:8443.';;
  m65) printf '%s' 'The state changed. Refresh the WISP panel.';;
  m66) printf '%s' 'Connect to this router local network.';;
  m67) printf '%s' 'This network configuration is unsupported by this WISP version.';;
  m68) printf '%s' 'Network settings changed. Previous network restored.';;
  m69) printf '%s' 'Could not verify network settings. Protective recovery performed.';;
  m70) printf '%s' 'Connection or network rules changed. Protective recovery performed.';;
  m71) printf '%s' 'Switching failed. Previous network restored.';;
  m72) printf '%s' 'Required files or system tools are missing. Reinstall WISP.';;
  m73) printf '%s' 'The action failed. Check the connection and try again.';;
  m74) printf '%s' 'Removal did not finish. Recovery data is kept; you can retry removal.';;
  m75) printf '%s' 'Removal did not finish. Data is kept for another attempt.';;
  m76) printf '%s' 'Unsafe component path. Removal stopped.';;
  m77) printf '%s' 'WISP fully removed. Previous network restored.';;
  m78) printf '%s' 'Unsafe component path.';;
  m79) printf '%s' 'The router is busy. Wait and try again.';;
  m80) printf '%s' 'Removal is already running.';;
  m81) printf '%s' 'Removal started. The panel may disconnect.';;
  m82) printf '%s' 'Could not start removal.';;
  m83) printf '%s' 'Explicit DELETE confirmation is required.';;
  *) printf '%s' "$1";;
 esac
}
