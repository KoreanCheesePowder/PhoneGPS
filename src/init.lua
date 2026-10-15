local CP_MONITOR_META = { driver_name = "C.P Phone GPS", driver_version = "v1.1.3", package_key = "cp-phone-gps-edge-v105", target_name = "PhoneGPS NAS", host_pref = "nasIp", port_pref = "apiPort", transport = "http", direct_monitor_pref = "nasIp" }
local cp_monitor = require "cp_monitor"
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local log = require "log"
local cosock = require "cosock"
local http = cosock.asyncify "socket.http"
local ltn12 = require "ltn12"
local json = require "st.json"

local CAP_SUMMARY = "buildbook37604.phoneGpsSummary"
local CAP_LOCATION = "buildbook37604.phoneGpsLocation"
local CAP_INFO = "buildbook37604.phoneGpsInfo"

local summary_cap = capabilities[CAP_SUMMARY]
local location_cap = capabilities[CAP_LOCATION]
local info_cap = capabilities[CAP_INFO]

local DRIVER_VERSION = "v1.1.3"
local DEVICE_DNI = "cp-phone-gps"
local DEFAULT_PROFILE = "cp-phone-gps-2"
local POLL_TIMER_FIELD = "phone_gps_poll_timer_v1"
local FAILURES_FIELD = "phone_gps_failures_v1"
local PROFILE_FIELD = "phone_gps_profile_v1"
local ONLINE_TIMER_FIELD = "phone_gps_online_timer_v110"
local LAST_ONLINE_FIELD = "phone_gps_last_online_v110"
local ONLINE_CONFIRM_SECONDS = 60

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function clamp_count(value)
  local n = tonumber(value) or 2
  n = math.floor(n)
  if n < 1 then n = 1 end
  if n > 4 then n = 4 end
  return n
end

local function profile_for_count(count)
  return "cp-phone-gps-" .. tostring(clamp_count(count))
end

local function compact_address(value)
  local s = trim(value)
  s = s:gsub("^부산광역시%s+", "")
  s = s:gsub("^부산시%s+", "")
  s = s:gsub("%s+", " ")
  return trim(s)
end

local function compact_distance(value, meters)
  local s = trim(value)
  if s ~= "" then
    s = s:gsub("%s+", "")
    return s
  end

  local m = tonumber(meters)
  if not m then return "-" end
  if m < 1000 then
    return tostring(math.floor(m + 0.5)) .. "m"
  end
  return string.format("%.2fkm", m / 1000)
end

local function component_exists(device, component_id)
  return device.profile and device.profile.components and device.profile.components[component_id] ~= nil
end

local function emit_info(device)
  if not component_exists(device, "info") then return end
  local info_component = device.profile.components["info"]
  if info_cap and info_cap.author then
    device:emit_component_event(info_component, info_cap.author("치즈가루", {state_change = true}))
  end
  if info_cap and info_cap.driverVersion then
    device:emit_component_event(info_component, info_cap.driverVersion(DRIVER_VERSION, {state_change = true}))
  end
end

local function emit_waiting(device)
  if summary_cap and summary_cap.summary then
    device:emit_event(summary_cap.summary("위치 데이터 대기", {state_change = true}))
  end

  local count = clamp_count(device.preferences and device.preferences.displayCount)
  for i = 1, count do
    local component_id = "phone" .. tostring(i)
    if component_exists(device, component_id) and location_cap and location_cap.location then
      device:emit_component_event(
        device.profile.components[component_id],
        location_cap.location("-위치 데이터 대기", {state_change = true})
      )
    end
  end
end

-- PhoneGPS virtual LAN device is kept online independently of NAS HTTP availability.
-- Important: SmartThings may have stale cloud availability following a hub outage.
-- Never block the init lifecycle waiting for a health API response.  Network and
-- health API calls run in separate cosock tasks, after the polling timer is set.
local HEALTH_TIMER_FIELD = "phone_gps_health_timer_v112"
local HEALTH_BUSY_FIELD = "phone_gps_health_busy_v112"
local HEALTH_LAST_ATTEMPT_FIELD = "phone_gps_health_last_attempt_v112"
local HEALTH_RESET_DONE_FIELD = "phone_gps_health_reset_done_v112"
local HEALTH_INTERVAL_SECONDS = 60
local HEALTH_BUSY_TIMEOUT_SECONDS = 90

local function read_field(device, name)
  local ok, result = pcall(function() return device:get_field(name) end)
  if ok then return result end
  log.error("GPS_HEALTH_FIELD_READ_FAILED " .. tostring(result))
  return nil
end

local function availability_call(device, wanted, reason)
  local op = wanted and "ONLINE" or "OFFLINE"
  log.debug(string.format("GPS_HEALTH_CALL %s version=%s reason=%s device=%s",
    op, DRIVER_VERSION, tostring(reason), tostring(device.id)))
  local invoke_ok, status, detail = pcall(function()
    if wanted then return device:online() end
    return device:offline()
  end)

  if not invoke_ok then
    log.error(string.format("GPS_HEALTH_API_EXCEPTION %s reason=%s error=%s",
      op, tostring(reason), tostring(status)))
    return false
  end
  if status == false or (status == nil and detail ~= nil) then
    log.error(string.format("GPS_HEALTH_API_REJECTED %s reason=%s status=%s detail=%s",
      op, tostring(reason), tostring(status), tostring(detail)))
    return false
  end

  -- The hub SDK can return LuaDeviceHealthSetResponse userdata rather than true.
  -- Its presence is not an explicit rejection and is not proof of cloud ONLINE.
  -- The final health state must be verified through SmartThings devices:health.
  if status == true then
    log.debug(string.format("GPS_HEALTH_API_ACCEPTED %s reason=%s device=%s",
      op, tostring(reason), tostring(device.id)))
  elseif status == nil then
    log.debug(string.format("GPS_HEALTH_API_NO_STATUS %s reason=%s device=%s",
      op, tostring(reason), tostring(device.id)))
  else
    log.debug(string.format("GPS_HEALTH_API_RESPONSE %s reason=%s reply_type=%s device=%s",
      op, tostring(reason), type(status), tostring(device.id)))
  end
  return true
end

-- This function returns immediately even if the SDK health API yields.
local function online_async(device, reason, force)
  local now = os.time()
  local last_attempt = tonumber(read_field(device, HEALTH_LAST_ATTEMPT_FIELD)) or 0
  local active_since = tonumber(read_field(device, HEALTH_BUSY_FIELD)) or 0
  if active_since > 0 and now - active_since < HEALTH_BUSY_TIMEOUT_SECONDS then
    log.debug("GPS_HEALTH_PENDING reason=" .. tostring(reason))
    return
  end
  if active_since > 0 then
    log.error("GPS_HEALTH_PREVIOUS_REQUEST_TIMEOUT elapsed=" .. tostring(now - active_since))
  end
  if not force and last_attempt > 0 and now - last_attempt < HEALTH_INTERVAL_SECONDS then return end
  device:set_field(HEALTH_BUSY_FIELD, now, { persist = false })
  device:set_field(HEALTH_LAST_ATTEMPT_FIELD, now, { persist = false })
  local started, spawn_err = pcall(function()
    cosock.spawn(function()
      local ok, err = pcall(availability_call, device, true, reason)
      if not ok then log.error("GPS_HEALTH_TASK_ERROR " .. tostring(err)) end
      device:set_field(HEALTH_BUSY_FIELD, nil, { persist = false })
    end, "cp-phone-gps-online")
  end)
  if not started then
    device:set_field(HEALTH_BUSY_FIELD, nil, { persist = false })
    log.error("GPS_HEALTH_SPAWN_FAILED " .. tostring(spawn_err))
  end
end

local function stop_online_timer(device)
  local timer = read_field(device, HEALTH_TIMER_FIELD)
  if timer then
    pcall(function() device.thread:cancel_timer(timer) end)
    device:set_field(HEALTH_TIMER_FIELD, nil, { persist = false })
  end
end

local function start_online_timer(device)
  stop_online_timer(device)
  log.debug("GPS_HEALTH_INIT version=" .. DRIVER_VERSION .. " device=" .. tostring(device.id))
  -- One-time offline/online transition resends a distinct state change to the
  -- platform if the hub and the cloud disagree following the network outage.
  -- Run only on upgrading to v1.1.2; not at every poll or every hub restart.
  local reset_done = read_field(device, HEALTH_RESET_DONE_FIELD) == true
  if not reset_done then
    device:set_field(HEALTH_RESET_DONE_FIELD, true, { persist = true })
    local started, err = pcall(function()
      cosock.spawn(function()
        local ok, detail = pcall(availability_call, device, false, "recovery-transition")
        if not ok then log.error("GPS_HEALTH_RESET_ERROR " .. tostring(detail)) end
        -- Schedule the online transition after the offline call has completed.
        device.thread:call_with_delay(3, function()
          online_async(device, "recovery-transition", true)
        end, "phone-gps-recovery-transition")
      end, "cp-phone-gps-recovery-reset")
    end)
    if not started then
      log.error("GPS_HEALTH_RESET_SPAWN_FAILED " .. tostring(err))
      device.thread:call_with_delay(3, function()
        online_async(device, "reset-fallback", true)
      end, "phone-gps-reset-fallback")
    end
  else
    device.thread:call_with_delay(2, function()
      online_async(device, "restart", true)
    end, "phone-gps-online-initial")
  end
  local timer = device.thread:call_on_schedule(HEALTH_INTERVAL_SECONDS, function()
    log.debug("GPS_HEALTH_TICK version=" .. DRIVER_VERSION .. " device=" .. tostring(device.id))
    online_async(device, "periodic", false)
  end, "phone-gps-health-v112")
  device:set_field(HEALTH_TIMER_FIELD, timer, { persist = false })
  if not timer then log.error("GPS_HEALTH_TIMER_CREATE_FAILED") end
end

local function confirm_device_online(device, force)
  online_async(device, "nas-api-success", force == true)
end

local function local_base_url(device)
  local ip = trim(device.preferences and device.preferences.nasIp)
  if ip == "" then return nil end
  local port = tonumber(device.preferences and device.preferences.apiPort) or 8787
  return string.format("http://%s:%d", ip, port)
end

local function http_json_request(device, path, method, body)
  local base = local_base_url(device)
  if not base then
    error("NAS IP 설정 필요")
  end

  local chunks = {}
  local payload = body or ""
  local headers = {
    ["Accept"] = "application/json"
  }

  local req = {
    url = base .. path,
    method = method or "GET",
    sink = ltn12.sink.table(chunks),
    headers = headers,
    create = function()
      local sock = cosock.socket.tcp()
      sock:settimeout(20)
      return sock
    end
  }

  if payload ~= "" then
    headers["Content-Type"] = "application/json"
    headers["Content-Length"] = tostring(#payload)
    req.source = ltn12.source.string(payload)
  elseif (method or "GET") == "POST" then
    payload = "{}"
    headers["Content-Type"] = "application/json"
    headers["Content-Length"] = tostring(#payload)
    req.source = ltn12.source.string(payload)
  end

  pcall(cp_monitor.tx, device, payload and #payload or 1, method.." "..path)
  local ok, code, _, status = http.request(req)
  if not ok or tonumber(code) ~= 200 then
    error(string.format("PhoneGPS API request failed: %s %s", tostring(code), tostring(status)))
  end

  local raw = table.concat(chunks)
  pcall(cp_monitor.rx, device, #raw, "HTTP "..tostring(code))
  local decoded = json.decode(raw)
  if type(decoded) ~= "table" then
    error("PhoneGPS API JSON decode failed")
  end
  return decoded
end


local function sync_settings_to_nas(device)
  local display_count = clamp_count(device.preferences and device.preferences.displayCount)
  local esl_refresh = tonumber(device.preferences and device.preferences.eslRefreshSeconds) or 60
  esl_refresh = math.max(30, math.min(3600, math.floor(esl_refresh)))

  local body = json.encode({
    display_count = display_count,
    esl_refresh_seconds = esl_refresh
  })

  local ok, result = pcall(function()
    return http_json_request(device, "/api/settings", "POST", body)
  end)

  if not ok then
    log.warn("PhoneGPS settings sync failed: " .. tostring(result))
    return false
  end

  log.info(string.format(
    "PhoneGPS settings synced: display_count=%d esl_refresh_seconds=%d",
    display_count,
    esl_refresh
  ))
  return true
end

local function normalize_phones(payload)
  local phones = payload and payload.phones
  if type(phones) ~= "table" then
    return {}
  end
  return phones
end

local function emit_phone_data(device, payload)
  local phones = normalize_phones(payload)
  local count = clamp_count(device.preferences and device.preferences.displayCount)
  local summary_parts = {}

  for i = 1, count do
    local p = phones[i]
    local component_id = "phone" .. tostring(i)

    if component_exists(device, component_id) and location_cap and location_cap.location then
      local text
      local dist = "-"

      if type(p) == "table" then
        local addr = compact_address(p.road_address or p.display_address or p.address)
        dist = compact_distance(p.distance_from_home, p.distance_from_home_m)

        if addr == "" then
          local lat = tonumber(p.latitude)
          local lon = tonumber(p.longitude)
          if lat and lon then
            addr = string.format("%.5f, %.5f", lat, lon)
          else
            addr = "위치 확인 불가"
          end
        end

        text = "-" .. addr .. ", " .. dist
      else
        text = "-데이터 없음"
      end

      device:emit_component_event(
        device.profile.components[component_id],
        location_cap.location(text, {state_change = true})
      )

      if i <= 2 then
        table.insert(summary_parts, "Phone" .. tostring(i) .. " " .. dist)
      end
    end
  end

  if count > 2 then
    table.insert(summary_parts, "+" .. tostring(count - 2))
  end

  if summary_cap and summary_cap.summary then
    local text = #summary_parts > 0 and table.concat(summary_parts, " · ") or "위치 데이터 없음"
    device:emit_event(summary_cap.summary(text, {state_change = true}))
  end
end

local function fetch_current(device)
  return http_json_request(device, "/api/phones", "GET")
end

local function refresh_current(device)
  return http_json_request(device, "/api/refresh", "POST", "{}")
end

local function poll_local_data(driver, device, force_refresh)
  local ok, result = pcall(function()
    if force_refresh then
      return refresh_current(device)
    end
    return fetch_current(device)
  end)

  if ok then
    pcall(cp_monitor.poll, device, true)
    confirm_device_online(device, false)
    emit_phone_data(device, result)
    device:set_field(FAILURES_FIELD, 0)
    return true
  end

  local failures = (tonumber(device:get_field(FAILURES_FIELD)) or 0) + 1
  device:set_field(FAILURES_FIELD, failures)
  pcall(cp_monitor.poll, device, false, tostring(result))
  log.warn(string.format("PhoneGPS local API failed (%d): %s", failures, tostring(result)))

  if summary_cap and summary_cap.summary then
    device:emit_event(summary_cap.summary("PhoneGPS 연결 오류", {state_change = true}))
  end
  -- Do not call device:offline() for temporary PhoneGPS NAS/API failures.
  -- The failure remains visible in the summary and system-monitor telemetry.
  return false
end

local function stop_poll_timer(device)
  local timer = device:get_field(POLL_TIMER_FIELD)
  if timer then
    pcall(function() device.thread:cancel_timer(timer) end)
    device:set_field(POLL_TIMER_FIELD, nil)
  end
end

local function start_poll_timer(driver, device)
  stop_poll_timer(device)

  local seconds = tonumber(device.preferences and device.preferences.refreshSeconds) or 60
  seconds = math.max(30, math.min(3600, seconds))

  device.thread:call_with_delay(2, function()
    poll_local_data(driver, device, false)
  end, "phone-gps-initial")

  local timer = device.thread:call_on_schedule(seconds, function()
    poll_local_data(driver, device, false)
  end, "phone-gps-poll")

  device:set_field(POLL_TIMER_FIELD, timer)
end

local function apply_display_profile(device)
  local count = clamp_count(device.preferences and device.preferences.displayCount)
  local wanted = profile_for_count(count)
  local current = tostring(device:get_field(PROFILE_FIELD) or "")

  if current ~= wanted then
    log.info("PhoneGPS profile -> " .. wanted)
    device:set_field(PROFILE_FIELD, wanted, {persist = true})
    device:try_update_metadata({profile = wanted})
  end
end

local function find_device(driver)
  for _, device in ipairs(driver:get_devices()) do
    if device.device_network_id == DEVICE_DNI then
      return device
    end
  end
  return nil
end

local function ensure_device(driver)
  if find_device(driver) then return end

  driver:try_create_device({
    type = "LAN",
    device_network_id = DEVICE_DNI,
    label = "C.P Phone GPS",
    profile = DEFAULT_PROFILE,
    manufacturer = "C.P",
    model = "Phone GPS",
    vendor_provided_label = "C.P Phone GPS"
  })
end

local function discovery_handler(driver, opts, should_continue)
  ensure_device(driver)
end

local function added(driver, device)
  log.warn(string.format("GPS_BOOT VERSION=%s device=%s nas=%s:%s", DRIVER_VERSION,
    tostring(device.id), tostring(device.preferences and device.preferences.nasIp),
    tostring(device.preferences and device.preferences.apiPort)))
  pcall(cp_monitor.start, device, CP_MONITOR_META)
  -- Install the normal data polling worker BEFORE health reconciliation.
  local poll_ok, poll_err = pcall(start_poll_timer, driver, device)
  if not poll_ok then log.error("GPS_POLL_START_FAILED " .. tostring(poll_err)) end
  local recovery_ok, recovery_err = pcall(start_online_timer, device)
  if not recovery_ok then log.error("GPS_HEALTH_START_FAILED " .. tostring(recovery_err)) end
  local meta_ok, meta_err = pcall(function()
    apply_display_profile(device)
    emit_info(device)
    emit_waiting(device)
  end)
  if not meta_ok then log.error("GPS_METADATA_START_FAILED " .. tostring(meta_err)) end
  device.thread:call_with_delay(3, function()
    sync_settings_to_nas(device)
  end, "phone-gps-settings-initial")
end

local function info_changed(driver, device, event, args)
  local old_prefs = args and args.old_st_store and args.old_st_store.preferences or {}
  local new_prefs = device.preferences or {}

  local old_count = clamp_count(old_prefs.displayCount)
  local new_count = clamp_count(new_prefs.displayCount)

  if old_count ~= new_count then
    apply_display_profile(device)
    device.thread:call_with_delay(2, function()
      emit_info(device)
      poll_local_data(driver, device, false)
    end, "phone-gps-profile-refresh")
  end

  device:set_field(FAILURES_FIELD, 0)
  start_poll_timer(driver, device)
  start_online_timer(device)

  device.thread:call_with_delay(1, function()
    sync_settings_to_nas(device)
  end, "phone-gps-settings-sync")
end

local function removed(driver, device)
  stop_poll_timer(device)
  stop_online_timer(device)
end

local function refresh_handler(driver, device, command)
  log.warn("GPS_REFRESH_RECEIVED version=" .. DRIVER_VERSION)
  online_async(device, "manual-refresh", true)
  poll_local_data(driver, device, true)
end

local driver = Driver("cp-phone-gps", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    added = added,
    init = added,
    infoChanged = info_changed,
    removed = removed
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh_handler
    }
  }
})

driver:run()
