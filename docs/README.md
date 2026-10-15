# C.P Phone GPS v1.1.3 - Health API response logging fix

Based on the successfully recovered v1.1.2 driver. This update changes only health API result classification, ordinary periodic health log levels, and displayed driver version.

- A SmartThings hub may return a `LuaDeviceHealthSetResponse` object instead of boolean `true` from `device:online()`.
- A returned response object is **not** an API rejection, nor does it prove cloud ONLINE.
- A real thrown exception or an explicit `false` result is logged at ERROR level.
- Successful and normal periodic health calls are logged at DEBUG level.
- SmartThings API device health is the authoritative ONLINE/OFFLINE check.
- Unchanged: 60-second scheduling, one-time reset persistence key (v112), NAS polling, location rendering, phone count, existing driver/package ID, device & routines.
- ESL / ESP32 firmware, IP address and BLE display transport are not changed by this update.

**Install:** Extract to a new directory and run `UPDATE-EXISTING.cmd`. Do not delete the driver or the registered device.

**After install:** verify SmartThings `핸드폰 GPS` stays ONLINE and both phone values still update. Logcat should show `GPS_HEALTH_API_RESPONSE` rather than a false `GPS_HEALTH_API_REJECTED` for SDK reply objects.
