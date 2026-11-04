--!nonstrict

local listeners = require("./listeners.luau")

local TICK_MS = 1000
local HISTORY_LENGTH = 60
local ssOutput = ""
local published = nil
local scanPending = false
local nextScanAt = 0
local lastSampleAt = 0
local lastNowMs = 0
local pollSeconds = nil
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

local function publishListeners()
  local list = listeners.parse(ssOutput, {
    includeUdp = noctalia.getConfig("include_udp"),
    hideSystemPorts = noctalia.getConfig("hide_system_ports"),
    onlyOwnProcesses = noctalia.getConfig("only_own_processes"),
  })
  -- Stable lists preserve the panel's row identity and hover state across scans.
  local encoded = noctalia.json.encode(list)
  if encoded ~= published then
    published = encoded
    noctalia.state.set("listeners", list)
  end
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
  scanPending = noctalia.runAsync({ "ss", "-tulnpH" }, function(result)
    scanPending = false
    if result.exitCode ~= 0 then
      noctalia.log(`ss failed: {result.stderr}`)
      noctalia.state.set("scan_error", true)
      return
    end
    noctalia.state.set("scan_error", false)
    ssOutput = result.stdout
    publishListeners()
  end)
end

local function publishTraffic(rx: number, tx: number)
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
  local stats = noctalia.systemStats()
  if type(stats) ~= "table" or type(stats.net) ~= "table" then
    return
  end
  local rx, tx = stats.net.rxBytesPerSec, stats.net.txBytesPerSec
  if type(rx) ~= "number" or type(tx) ~= "number" then
    return
  end
  publishTraffic(rx, tx)
end

function update()
  noctalia.setUpdateInterval(TICK_MS)
  if pollSeconds == nil then
    readPollSeconds()
  end
  local now = nowMs()
  sampleTraffic(now)
  if now >= nextScanAt then
    scan()
  end
end

function onConfigChanged()
  readPollSeconds()
  nextScanAt = 0
  publishListeners()
end

noctalia.state.watch("scan", function(delayMs)
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

readPollSeconds()
update()
