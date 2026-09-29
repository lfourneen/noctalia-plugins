--!nonstrict
-- Waywallen Bridge <-> Noctalia wallpaper arbitration.
--
-- Noctalia draws its own wallpaper as a wlr-layer-shell Background surface
-- (namespace "noctalia-wallpaper"); the switch under Settings -> Wallpaper only
-- creates/tears that surface down. waywallen draws its own Background surface
-- ("waywallen-wallpaper") and knows nothing about Noctalia, so when both are up
-- the two surfaces stack and the switch cannot turn waywallen off.
--
-- Noctalia exposes `noctalia.setWallpaperEnabled(connector, false)` to plugins,
-- which marks the output as externally managed and tears Noctalia's surface
-- down (the same thing the official mpvpaper plugin does). This service calls
-- it for every output while waywallen is running, and restores Noctalia's
-- surface when waywallen stops, the plugin is disabled, or the user suspends
-- the arbitration from the bar widget.
--
-- The flag is runtime-only and clears when Noctalia restarts, so the service
-- re-asserts it on every poll, on hotplug, and on enable.

local STATUS_KEY = "waywallen-bridge.status"
local SUSPEND_KEY = "waywallen-bridge.suspend"
local DEFAULT_UNIT = "waywallen.service"

local yielded = {} -- connector -> true, outputs we asked Noctalia to drop
local running = false -- result of the last waywallen process probe
local note = "" -- short human-readable reason for the last action

local function cfgBool(key, fallback)
	local value = noctalia.getConfig(key)
	if type(value) == "boolean" then
		return value
	end
	return fallback
end

local function cfgString(key, fallback)
	local value = noctalia.getConfig(key)
	if type(value) == "string" and value ~= "" then
		return value
	end
	return fallback
end

local function pollMilliseconds()
	local value = noctalia.getConfig("poll_seconds")
	if type(value) == "number" and value >= 1 then
		return math.floor(value) * 1000
	end
	return 3000
end

local function yieldEnabled()
	return cfgBool("yield_wallpaper", true)
end

local function requireRunning()
	return cfgBool("require_running", true)
end

local function manageDaemon()
	return cfgBool("manage_daemon", false)
end

local function unitName()
	return cfgString("unit", DEFAULT_UNIT)
end

local function suspended()
	return noctalia.state.get(SUSPEND_KEY) == true
end

local function count(t)
	local n = 0
	for _ in pairs(t) do
		n += 1
	end
	return n
end

-- Single-quote a value for /bin/sh so the user-set unit name cannot be read as
-- shell syntax.
local function shellQuote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function publish()
	local outputs = {}
	for _, output in ipairs(noctalia.outputs()) do
		outputs[output.name] = yielded[output.name] == true
	end
	noctalia.state.set(STATUS_KEY, {
		outputs = outputs,
		yielded = count(yielded),
		running = running,
		suspended = suspended(),
		yield_enabled = yieldEnabled(),
		require_running = requireRunning(),
		note = note,
	})
end

-- Ask Noctalia to stop drawing its own wallpaper on every connected output.
-- Idempotent: outputs already yielded are skipped.
local function yieldAll()
	for _, output in ipairs(noctalia.outputs()) do
		if not yielded[output.name] then
			noctalia.setWallpaperEnabled(output.name, false)
			yielded[output.name] = true
		end
	end
end

-- Hand every output we took back to Noctalia. Names that disappeared while
-- yielded are cleared too; re-enabling them is a no-op.
local function restoreAll()
	for name in pairs(yielded) do
		noctalia.setWallpaperEnabled(name, true)
		yielded[name] = nil
	end
end

-- Probe for a running waywallen process and reconcile Noctalia's surfaces.
local function reconcile()
	if not yieldEnabled() or suspended() then
		restoreAll()
		running = false
		note = suspended() and "suspended" or "yield disabled"
		publish()
		return
	end

	if not requireRunning() then
		yieldAll()
		running = true
		note = "yielded"
		publish()
		return
	end

	noctalia.processMatches(function(matched)
		running = matched
		if matched then
			yieldAll()
			note = "yielded"
		else
			restoreAll()
			note = "waywallen not running"
		end
		publish()
	end, "waywallen")
end

-- Defensive: on a Noctalia without the wallpaper hook the plugin is a no-op
-- instead of erroring on every call.
local enabled = type(noctalia.setWallpaperEnabled) == "function"

if enabled then
	noctalia.setUpdateInterval(pollMilliseconds())
end

-- Service tick: re-check and re-assert (the flag is runtime-only, so this also
-- recovers it after a Noctalia restart).
function update()
	if not enabled then
		return
	end
	noctalia.setUpdateInterval(pollMilliseconds())
	reconcile()
end

-- Hotplug: yield brand-new outputs immediately.
function onOutputsChanged()
	if enabled then
		reconcile()
	end
end

-- Settings changed (poll interval, unit, ...): pick them up without a restart.
function onConfigChanged()
	if enabled then
		noctalia.setUpdateInterval(pollMilliseconds())
		reconcile()
	end
end

-- Explicit enable via the plugin manager: optionally bring the daemon up too.
function onEnable()
	if not enabled then
		return
	end
	if manageDaemon() then
		noctalia.runAsync("systemctl --user start " .. shellQuote(unitName()) .. " >/dev/null 2>&1")
	end
	reconcile()
end

-- Manual override from the bar widget / IPC.
function onIpc(event, _payload)
	if event == "refresh" then
		reconcile()
	elseif event == "suspend" then
		noctalia.state.set(SUSPEND_KEY, true)
		reconcile()
	elseif event == "resume" then
		noctalia.state.set(SUSPEND_KEY, false)
		reconcile()
	elseif event == "toggle" then
		noctalia.state.set(SUSPEND_KEY, not suspended())
		reconcile()
	elseif event == "status" then
		publish()
	end
end

-- Restore Noctalia's wallpaper when the entry goes away. A plain reload is
-- skipped: the reloaded service re-yields a moment later, and restoring first
-- would only flash Noctalia's wallpaper.
function onExit(_signal, reason)
	if not enabled or reason == "reload" then
		return
	end
	restoreAll()
	if manageDaemon() and (reason == "disable" or reason == "uninstall") then
		noctalia.runAsync("systemctl --user stop " .. shellQuote(unitName()) .. " >/dev/null 2>&1")
	end
end

-- Initial pass at load. `update()` also runs on the first tick.
if enabled then
	reconcile()
end
