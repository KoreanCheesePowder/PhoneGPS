-- C.P Edge telemetry helper for 치즈가루 시스템 모니터.
-- Passive by design: telemetry failures never change device state or control flow.
local socket = require "cosock.socket"
local json = require "st.json"
local capabilities = require "st.capabilities"
local log = require "log"

local M = {}
local BOOT_TS = os.time()
local UDP_PORT = 8791
local BROADCAST_TARGETS = { "255.255.255.255", "192.168.1.255" }
local START_FIELD = "cp_monitor_started_v1"
local states = {}

local function key(device)
  return tostring((device and (device.id or device.device_network_id)) or "unknown")
end

local function state(device)
  local k = key(device)
  if not states[k] then
    states[k] = {
      rx_count = 0, tx_count = 0, event_count = 0, error_count = 0,
      rx_bytes = 0, tx_bytes = 0, connection = "unknown",
      last_rx = nil, last_tx = nil, last_event = nil, last_error = nil,
      last_poll = nil, poll_status = nil, poll_error = nil,
      rssi = nil, lqi = nil, meta = {}
    }
  end
  return states[k]
end

local function latest(device, cap, attr)
  if not device or not device.get_latest_state or not cap or not attr then return nil end
  local ok, value = pcall(function()
    return device:get_latest_state("main", cap.ID, attr.NAME)
  end)
  if ok then return value end
  return nil
end

local function device_states(device)
  local result = {}
  local mapping = {
    battery = { capabilities.battery, capabilities.battery and capabilities.battery.battery },
    temperature = { capabilities.temperatureMeasurement, capabilities.temperatureMeasurement and capabilities.temperatureMeasurement.temperature },
    humidity = { capabilities.relativeHumidityMeasurement, capabilities.relativeHumidityMeasurement and capabilities.relativeHumidityMeasurement.humidity },
    presence = { capabilities.presenceSensor, capabilities.presenceSensor and capabilities.presenceSensor.presence },
    water = { capabilities.waterSensor, capabilities.waterSensor and capabilities.waterSensor.water },
    illuminance = { capabilities.illuminanceMeasurement, capabilities.illuminanceMeasurement and capabilities.illuminanceMeasurement.illuminance },
    switch = { capabilities.switch, capabilities.switch and capabilities.switch.switch },
  }
  for name, pair in pairs(mapping) do
    local value = latest(device, pair[1], pair[2])
    if value ~= nil then result[name] = value end
  end
  return result
end

local function resolve_target(device, meta)
  local prefs = (device and device.preferences) or {}
  local host = meta.target_host
  local port = meta.target_port
  if (not host or host == "") and meta.host_pref then host = prefs[meta.host_pref] end
  if (not port or tostring(port) == "") and meta.port_pref then port = prefs[meta.port_pref] end
  if port ~= nil then port = tonumber(port) or port end
  return host, port
end

local function payload(device)
  local s = state(device)
  local meta = s.meta or {}
  local host, port = resolve_target(device, meta)
  return {
    schema = 1,
    source = "cp-edge-monitor",
    driver_name = meta.driver_name or "C.P Edge Driver",
    driver_version = meta.driver_version or "-",
    package_key = meta.package_key or meta.driver_name or "unknown",
    transport = meta.transport or "unknown",
    target_name = meta.target_name or "",
    target_host = host or "",
    target_port = port,
    device_id = tostring((device and device.id) or ""),
    device_network_id = tostring((device and device.device_network_id) or ""),
    device_label = tostring((device and device.label) or ""),
    profile_id = tostring((device and device.profile and device.profile.id) or ""),
    driver_status = "running",
    boot_ts = BOOT_TS,
    uptime_s = math.max(0, os.time() - BOOT_TS),
    heartbeat_ts = os.time(),
    connection = s.connection,
    last_rx = s.last_rx,
    last_tx = s.last_tx,
    rx_count = s.rx_count,
    tx_count = s.tx_count,
    rx_bytes = s.rx_bytes,
    tx_bytes = s.tx_bytes,
    last_event = s.last_event,
    event_count = s.event_count,
    last_poll = s.last_poll,
    poll_status = s.poll_status,
    poll_error = s.poll_error,
    last_error = s.last_error,
    error_count = s.error_count,
    rssi = s.rssi,
    lqi = s.lqi,
    states = device_states(device),
  }
end

local function try_send(host, encoded, broadcast)
  local sock, err = socket.udp()
  if not sock then return false, err end
  pcall(function() sock:settimeout(0.05) end)
  if broadcast then pcall(function() sock:setoption("broadcast", true) end) end
  local ok, a, b = pcall(function() return sock:sendto(encoded, host, UDP_PORT) end)
  pcall(function() sock:close() end)
  if not ok then return false, a end
  if not a then return false, b end
  return true
end

function M.send(device)
  local ok, encoded = pcall(json.encode, payload(device))
  if not ok or not encoded then return false end
  local s = state(device)
  local meta = s.meta or {}
  local sent = false
  local prefs = (device and device.preferences) or {}
  if meta.direct_monitor_pref then
    local direct = tostring(prefs[meta.direct_monitor_pref] or "")
    if direct ~= "" then
      local good = try_send(direct, encoded, false)
      sent = good or sent
    end
  end
  for _, host in ipairs(BROADCAST_TARGETS) do
    local good = try_send(host, encoded, true)
    sent = good or sent
  end
  return sent
end

function M.start(device, meta)
  if not device then return end
  local s = state(device)
  s.meta = meta or s.meta or {}
  local already = false
  pcall(function() already = device:get_field(START_FIELD) == true end)
  if already then return end
  pcall(function() device:set_field(START_FIELD, true, { persist = false }) end)
  local ok, err = pcall(function()
    device.thread:call_with_delay(5, function() pcall(M.send, device) end, "cp-monitor-initial")
    device.thread:call_on_schedule(60, function() pcall(M.send, device) end, "cp-monitor-heartbeat")
  end)
  if not ok then log.debug("C.P monitor schedule unavailable: " .. tostring(err)) end
end

function M.rx(device, bytes, detail)
  local s = state(device); s.rx_count = s.rx_count + 1; s.rx_bytes = s.rx_bytes + (tonumber(bytes) or 0); s.last_rx = os.time()
  if detail then s.last_event = tostring(detail) end
end
function M.tx(device, bytes, detail)
  local s = state(device); s.tx_count = s.tx_count + 1; s.tx_bytes = s.tx_bytes + (tonumber(bytes) or 0); s.last_tx = os.time()
  if detail then s.last_event = tostring(detail) end
end
function M.event(device, name)
  local s = state(device); s.event_count = s.event_count + 1; s.last_event = tostring(name or "event")
end
function M.poll(device, ok, err)
  local s = state(device); s.last_poll = os.time(); s.poll_status = ok and "success" or "failed"; s.poll_error = ok and nil or tostring(err or "poll failed")
  if not ok then M.error(device, err or "poll failed") end
end
function M.error(device, err)
  local s = state(device); s.error_count = s.error_count + 1; s.last_error = tostring(err or "unknown")
end
function M.connection(device, value, err)
  local s = state(device); s.connection = tostring(value or "unknown")
  if err then s.last_error = tostring(err) end
end
function M.mark_zigbee(device, zb_rx, detail)
  local s = state(device); s.rx_count = s.rx_count + 1; s.last_rx = os.time(); s.last_event = tostring(detail or "zigbee-rx")
  if zb_rx then
    local ok1, rssi = pcall(function() return zb_rx.rssi end); if ok1 and rssi ~= nil then s.rssi = tonumber(rssi) or rssi end
    local ok2, lqi = pcall(function() return zb_rx.lqi end); if ok2 and lqi ~= nil then s.lqi = tonumber(lqi) or lqi end
  end
end

return M
