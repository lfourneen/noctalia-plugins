--!nonstrict

local listeners = require("./listeners.luau")
local trafficSampler = require("./traffic.luau")
local previousTraffic = nil

local TICK_MS = 1000
local HISTORY_LENGTH = 60
local SCAN_TIMEOUT_MS = 10000
local SCAN_WATCHDOG_MS = SCAN_TIMEOUT_MS + 2000
local scanScript = noctalia.readFile("scan_ports.py")
local published = nil
local scanPending = false
local scanStartedAt = 0
local scanGeneration = 0
local sampleCount = 0
local scanCount = 0
local nextScanAt = 0
local lastSampleAt = 0
local lastNowMs = 0
local pollSeconds = nil
local lastPollReadAt = 0
local rxHistory, txHistory = {}, {}

local function readPollSeconds()
  local value = noctalia.getSetting("system.monitor.network_poll_seconds")
  pollSeconds = if type(value) == "number" then value else nil
end

-- nowMs() is wall-clock based. If it steps backwards (NTP correction,
-- suspend/resume), every deadline computed from it can sit in the future and
-- freeze sampling, so reset the schedules when that happens.
local function nowMs()
  local now = noctalia.nowMs()
  if now < lastNowMs then
    lastSampleAt = 0
    nextScanAt = 0
  end
  lastNowMs = now
  return now
end

local function scan()
  if scanPending then
    return
  end
  local refresh = noctalia.getConfig("refresh_interval")
  if type(refresh) ~= "number" or refresh <= 0 then
    refresh = 5
  end
  nextScanAt = nowMs() + refresh * 1000
  scanGeneration += 1
  local generation = scanGeneration
  scanPending = true
  scanStartedAt = nowMs()
  local started = noctalia.runAsync({ "python3", "-c", scanScript or "",
    tostring(noctalia.getConfig("include_udp") == true),
    tostring(noctalia.getConfig("hide_system_ports") == true),
    tostring(noctalia.getConfig("only_own_processes") == true),
  }, function(result)
    if generation ~= scanGeneration then
      return -- a watchdog retry owns the current scan
    end
    scanPending = false
    if result.exitCode ~= 0 or result.timedOut then
      noctalia.log(`ss failed: {result.stderr}`)
      noctalia.state.set("scan_error", true)
      return
    end
    scanCount += 1
    local list = noctalia.json.decode(result.stdout)
    if type(list) ~= "table" then
      noctalia.state.set("scan_error", true)
      noctalia.log("port collector returned invalid JSON")
      return
    end
    if result.stdout ~= published then
      noctalia.state.set("listeners", list)
      published = result.stdout
    end
    noctalia.state.set("scan_error", false)
  end, SCAN_TIMEOUT_MS)
  if not started then
    scanPending = false
    noctalia.log("ss could not be started; retrying on the next scan interval")
    noctalia.state.set("scan_error", true)
  end
end

local function publishTraffic(rx: number, tx: number)
  sampleCount += 1
  table.insert(rxHistory, rx)
  table.insert(txHistory, tx)
  if #rxHistory > HISTORY_LENGTH then
    table.remove(rxHistory, 1)
    table.remove(txHistory, 1)
  end
  noctalia.state.set("traffic", { rx = rx, tx = tx, rxHistory = rxHistory, txHistory = txHistory })
end

local function sampleTraffic(now: number)
  if pollSeconds == nil or pollSeconds <= 0 then
    return
  end
  if now - lastSampleAt < pollSeconds * 1000 then
    return
  end
  lastSampleAt = now
  local text = noctalia.readFile("/proc/net/dev")
  if type(text) ~= "string" then return end
  local rx, tx, baseline = trafficSampler.sample(text, now, previousTraffic)
  previousTraffic = baseline
  publishTraffic(rx, tx)
end

function update()
  noctalia.setUpdateInterval(TICK_MS)
  local now = nowMs()
  if now < lastPollReadAt or now - lastPollReadAt >= TICK_MS then
    readPollSeconds()
    lastPollReadAt = now
  end
  if scanPending and (now < scanStartedAt or now - scanStartedAt >= SCAN_WATCHDOG_MS) then
    scanPending = false
    scanGeneration += 1
    nextScanAt = 0
    noctalia.state.set("scan_error", true)
    noctalia.log("ss callback overdue; retrying scan")
  end
  sampleTraffic(now)
  if now >= nextScanAt then
    scan()
  end
end

function onConfigChanged()
  readPollSeconds()
  nextScanAt = 0
end

noctalia.state.watch("scan", function(delayMs)
  if type(delayMs) ~= "number" or delayMs ~= delayMs then
    return
  end
  delayMs = math.max(0, delayMs)
  nextScanAt = nowMs() + delayMs
  if delayMs == 0 then
    scan()
  else
    noctalia.setUpdateInterval(math.min(delayMs, TICK_MS))
  end
end)

function onIpc(event)
  if event == "refresh" then
    scan()
  elseif event == "status" then
    local traffic = noctalia.state.get("traffic") or {}
    local ports = noctalia.state.get("listeners") or {}
    noctalia.log(`scanner samples={sampleCount} scans={scanCount} pending={scanPending} error={noctalia.state.get("scan_error")} rx={traffic.rx} tx={traffic.tx} ports={#ports}`)
  elseif event == "selftest" then
    local ok, err = pcall(function()
      require("./tests/listeners_test.luau")(noctalia.log)
      require("./tests/rates_test.luau")(noctalia.log)
    end)
    if not ok then
      noctalia.log(`not ok - {err}`)
    end
  end
end

noctalia.setUpdateInterval(TICK_MS)
readPollSeconds()
update()
