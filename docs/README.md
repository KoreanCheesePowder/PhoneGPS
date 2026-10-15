# C.P Phone GPS Edge v1.1.2 - offline recovery

1. Extract ZIP to a NEW folder and run `UPDATE-EXISTING.cmd`.
2. Do not remove or re-register the SmartThings device. All existing settings, routines and profiles stay intact.
3. Installation checks the actual SmartThings device health after packaging / update.
4. If OFFLINE remains, run `smartthings edge:drivers:logcat 8a672fc6-aee8-4b64-a138-f55346366687` and look for `GPS_BOOT`, `GPS_HEALTH_TICK`, `GPS_HEALTH_CALL`, `GPS_HEALTH_API_ACCEPTED` / `GPS_HEALTH_API_REJECTED`.
5. Use `HEALTH-CHECK.cmd` to save cloud health and preferences to docs/LAST-HEALTH-CHECK.txt.

Changes:
- New v1.1.2 startup schedules the GPS poll timer before health checks.
- Health API runs in its own cosock coroutine to avoid blocking driver lifecycle.
- One-time OFFLINE then ONLINE transition on first v1.1.2 startup to resync stale cloud availability after a hub/network outage. It does NOT repeat this every restart or poll.
- Retry ONLINE every 60 seconds and log API acknowledgement or failure.
- HTTP location/API response and failure handling unchanged; NAS sleep does not force SmartThings device offline.
- IP settings are preserved; the new default for fresh devices is 192.168.1.53:8787. Existing .92 preferences must be manually changed in SmartThings to .53.
- Device and driver ID, location/ESL UI, metadata and capabilities are preserved.

Existing driver ID: 8a672fc6-aee8-4b64-a138-f55346366687
Existing device ID: 7cd5ac18-6432-41c6-b298-d0bd6b5bf757
Existing hub: c9e6b370-41a7-499a-ae95-3496747cd165
Existing channel: cd373cad-c1db-4b2a-943b-6ed6fb51d2fa

Offline / online SDK responses do not prove SmartThings cloud UI status. Installer reads actual device health. Successful installation on a real hub cannot be tested offline.
