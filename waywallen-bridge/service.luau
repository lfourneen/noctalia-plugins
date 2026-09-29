--!nonstrict
-- Waywallen Bridge <-> Noctalia wallpaper arbitration and color sync.
--
-- Noctalia draws its own wallpaper as a wlr-layer-shell Background surface
-- (namespace "noctalia-wallpaper"); the switch under Settings -> Wallpaper only
-- creates/tears that surface down. waywallen draws its own Background surface
-- ("waywallen-wallpaper") and knows nothing about Noctalia, so when both are up
-- the two surfaces stack and the switch cannot turn waywallen off.
--
-- Two things happen here:
--
-- 1. Yield. Noctalia exposes `noctalia.setWallpaperEnabled(connector, false)`
--    to plugins, which marks an output as externally managed and tears
--    Noctalia's surface down (the same hook the official mpvpaper plugin uses).
--    The service calls it for every output while waywallen is running, and
--    restores Noctalia's surface when waywallen stops, the plugin is disabled,
--    or the user suspends it from the bar widget. The flag is runtime-only and
--    clears when Noctalia restarts, so it is re-asserted on every poll, on
--    hotplug, and on enable.
--
-- 2. Color sync. waywallen's current wallpaper is read from its renderer
--    processes (`waywallen-video-renderer` / `waywallen-image-renderer ...
--    --path <file>`), turned into a still (a frame via ffmpeg for videos) and
--    handed to Noctalia with `noctalia.setWallpaper()`. Noctalia then runs its
--    palette generator, templates and lock screen against the live wallpaper -
--    what the W Engine plugin calls "sync colors" - while waywallen still draws
--    the background.
--
-- Performance: one `ps` scan per poll feeds both the running probe and color
-- sync (no second /proc walk). A video is decoded once: the frame is cached as
-- frame-<hash>-<mtime>.jpg and reused until the wallpaper path or its mtime
-- changes, so ffmpeg never runs on the steady state.

local STATUS_KEY = "waywallen-bridge.status"
local SUSPEND_KEY = "waywallen-bridge.suspend"
local DEFAULT_UNIT = "waywallen.service"

local VIDEO_EXTENSIONS = {
	mp4 = true,
	webm = true,
	mkv = true,
	mov = true,
	avi = true,
	m4v = true,
	wmv = true,
	flv = true,
	ts = true,
	m2ts = true,
}

local IMAGE_EXTENSIONS = {
	png = true,
	jpg = true,
	jpeg = true,
	webp = true,
	bmp = true,
	gif = true,
	avif = true,
	jxl = true,
	tiff = true,
	tif = true,
}

local yielded = {} -- connector -> true, outputs we asked Noctalia to drop
local running = false -- result of the last waywallen process scan
local note = "" -- short human-readable reason for the last action
local savedWallpaper = {} -- connector -> Noctalia wallpaper before we overrode it
local pendingCaptures = 0
local captureDone = false
local lastStill = nil -- last still path we handed to Noctalia

local function cfgBool(key, fallback)
	local value = noctalia.getConfig(key)
	if type(value) == "boolean" then
		return value
	end
	return fallback
end

local function cfgNumber(key, fallback)
	local value = noctalia.getConfig(key)
	if type(value) == "number" then
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

local function syncEnabled()
	return cfgBool("sync_colors", true)
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

local function trim(value)
	local text = tostring(value or "")
	text = text:gsub("^%s+", "")
	text = text:gsub("%s+$", "")
	return text
end

local function shellQuote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function extensionOf(path)
	return (tostring(path):match("%.([%w]+)$") or ""):lower()
end

local function hashString(value)
	local hash = 5381
	for i = 1, #value do
		hash = (hash * 33 + value:byte(i)) % 4294967296
	end
	return string.format("%08x", hash)
end

local lastSignature = nil

local function publish()
	local yieldedCount = count(yielded)
	local outputs = {}
	for _, output in ipairs(noctalia.outputs()) do
		outputs[output.name] = yielded[output.name] == true
	end
	local signature = table.concat({
		tostring(yieldedCount),
		tostring(running),
		tostring(suspended()),
		tostring(yieldEnabled()),
		tostring(syncEnabled()),
		tostring(requireRunning()),
		tostring(lastStill),
		note,
	}, "|")
	if signature == lastSignature then
		return
	end
	lastSignature = signature
	noctalia.state.set(STATUS_KEY, {
		outputs = outputs,
		yielded = yieldedCount,
		running = running,
		suspended = suspended(),
		yield_enabled = yieldEnabled(),
		sync_colors = syncEnabled(),
		require_running = requireRunning(),
		still = lastStill,
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

-- Remember the wallpaper Noctalia had before we started overriding it, per
-- output, so disabling or suspending the plugin can put it back.
local function captureSavedWallpaper()
	if captureDone then
		return
	end
	local outputs = noctalia.outputs()
	pendingCaptures = #outputs
	if pendingCaptures == 0 then
		captureDone = true
		return
	end
	for _, output in ipairs(outputs) do
		local connector = output.name
		noctalia.runAsync("noctalia msg wallpaper-get " .. shellQuote(connector), function(result)
			if result and result.exitCode == 0 and result.stdout then
				local previous = trim(result.stdout)
				if previous ~= "" then
					savedWallpaper[connector] = previous
				end
			end
			pendingCaptures = pendingCaptures - 1
			if pendingCaptures <= 0 then
				captureDone = true
			end
		end, 3000)
	end
end

local function restoreWallpaper()
	lastStill = nil
	for connector, path in pairs(savedWallpaper) do
		if type(path) == "string" and path ~= "" then
			noctalia.setWallpaper(connector, path)
		end
	end
end

-- One process scan per poll. The shell filters to waywallen renderer lines
-- first, so the Luau side parses a handful of lines instead of the whole
-- process list (parsing every line blows the 25 ms script budget). The `[w]`
-- bracket keeps grep from matching its own command line.
local function scanWaywallen(callback)
	noctalia.runAsync("ps -eo args 2>/dev/null | grep -E '[w]aywallen.*--path' || true", function(result)
		local paths = {}
		local seen = {}
		if result and result.stdout then
			for line in result.stdout:gmatch("[^\n]+") do
				local path = line:match("%-%-path[= ]([^%s]+)")
				if path and path ~= "" and not seen[path] then
					seen[path] = true
					table.insert(paths, path)
				end
			end
		end
		callback(#paths > 0, paths)
	end, 5000)
end

-- Delete frames from previous wallpapers, keeping the one in use.
local function cleanupFrames(keep)
	local directory = noctalia.pluginDataDir()
	if not directory then
		return
	end
	local entries = noctalia.listDir(directory)
	if type(entries) ~= "table" then
		return
	end
	for _, name in ipairs(entries) do
		if name:sub(1, 6) == "frame-" and name:sub(-4) == ".jpg" then
			local full = directory .. "/" .. name
			if full ~= keep then
				noctalia.removeFile(full)
			end
		end
	end
end

-- Turn a wallpaper file into an image Noctalia can derive a palette from:
-- images are used as-is, videos are decoded to a single frame with ffmpeg and
-- cached, so the decode happens once per source path + mtime.
local function resolveStill(source, callback)
	local extension = extensionOf(source)
	if IMAGE_EXTENSIONS[extension] then
		callback(noctalia.fileExists(source) and source or nil)
		return
	end
	if not VIDEO_EXTENSIONS[extension] then
		callback(nil)
		return
	end
	if not noctalia.commandExists("ffmpeg") then
		callback(nil)
		return
	end
	local directory = noctalia.pluginDataDir()
	if not directory then
		callback(nil)
		return
	end
	local info = noctalia.fileInfo(source)
	local mtime = (type(info) == "table" and info.mtime) or 0
	local still = directory .. "/frame-" .. hashString(source) .. "-" .. tostring(mtime) .. ".jpg"
	local cached = noctalia.fileInfo(still)
	if type(cached) == "table" and (cached.size or 0) > 0 then
		callback(still)
		return
	end
	local seek = cfgNumber("video_seek_seconds", 1.0)
	if seek < 0 then
		seek = 0
	end
	local command = "ffmpeg -y -loglevel error -ss " .. tostring(seek)
		.. " -i " .. shellQuote(source)
		.. " -frames:v 1 -vf scale=960:-2 " .. shellQuote(still)
	noctalia.runAsync(command, function()
		local produced = noctalia.fileInfo(still)
		callback((type(produced) == "table" and (produced.size or 0) > 0) and still or nil)
	end, 20000)
end

local function syncColors(paths)
	if not syncEnabled() then
		return
	end
	if #paths == 0 then
		return
	end
	resolveStill(paths[1], function(still)
		if not still or still == "" or still == lastStill then
			return
		end
		lastStill = still
		noctalia.setWallpaper(still)
		cleanupFrames(still)
		note = "colors synced"
		publish()
	end)
end

local WAYWALLEN_CONFIG = "~/.config/waywallen/config.toml"
local lastStamp = nil
local lastPaths = {}

-- waywallen rewrites its config when the wallpaper changes, so a cheap stat
-- gates the process scan: while it is unchanged no process is spawned at all.
local function configStamp()
	local info = noctalia.fileInfo(noctalia.expandPath(WAYWALLEN_CONFIG))
	if type(info) == "table" then
		return tostring(info.mtime or 0) .. ":" .. tostring(info.size or 0)
	end
	return "none"
end

local function resolvePaths(callback)
	local stamp = configStamp()
	if lastStamp ~= nil and stamp == lastStamp and #lastPaths > 0 then
		callback(lastPaths)
		return
	end
	lastStamp = stamp
	scanWaywallen(function(_, paths)
		lastPaths = paths
		callback(paths)
	end)
end

-- Liveness: a waywallen renderer exists, i.e. it is actually drawing. This uses
-- Noctalia's process matcher (a cached /proc read on a worker thread), not a
-- spawned `ps`, so the steady-state poll costs no subprocess.
local function rendererRunning(callback)
	noctalia.processMatches(callback, "waywallen-", "renderer")
end

-- Probe for waywallen and reconcile Noctalia's surfaces and colors.
local function reconcile()
	if suspended() then
		restoreAll()
		restoreWallpaper()
		running = false
		note = "suspended"
		publish()
		return
	end

	if not requireRunning() and not syncEnabled() then
		running = true
		if yieldEnabled() then
			yieldAll()
			note = "yielded"
		else
			restoreAll()
			note = "yield disabled"
		end
		publish()
		return
	end

	if not requireRunning() then
		running = true
		if yieldEnabled() then
			yieldAll()
			note = "yielded"
		else
			restoreAll()
			note = "yield disabled"
		end
		if syncEnabled() then
			resolvePaths(syncColors)
		else
			publish()
		end
		return
	end

	rendererRunning(function(found)
		running = found
		if not found then
			restoreAll()
			restoreWallpaper()
			note = "waywallen not running"
			publish()
			return
		end
		if yieldEnabled() then
			yieldAll()
			note = "yielded"
		else
			restoreAll()
			note = "yield disabled"
		end
		if syncEnabled() then
			resolvePaths(syncColors)
		else
			publish()
		end
	end)
end

-- Defensive: on a Noctalia without the wallpaper hook the plugin is a no-op
-- instead of erroring on every call.
local enabled = type(noctalia.setWallpaperEnabled) == "function"

if enabled then
	noctalia.setUpdateInterval(pollMilliseconds())
	captureSavedWallpaper()
end

-- Service tick: re-check and re-assert (the yield flag is runtime-only, so this
-- also recovers it after a Noctalia restart). The update interval is set once at
-- load and on a settings change, never here: re-arming the timer from inside the
-- callback can spin it.
function update()
	if not enabled then
		return
	end
	reconcile()
end

-- Hotplug: yield brand-new outputs and capture their wallpaper immediately.
function onOutputsChanged()
	if not enabled then
		return
	end
	captureDone = false
	captureSavedWallpaper()
	reconcile()
end

-- Settings changed (poll interval, unit, ...): pick them up without a restart.
function onConfigChanged()
	if not enabled then
		return
	end
	noctalia.setUpdateInterval(pollMilliseconds())
	reconcile()
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
	elseif event == "sync" then
		scanWaywallen(function(_, paths) syncColors(paths) end)
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

-- Restore Noctalia's surface and wallpaper when the entry goes away. A plain
-- reload is skipped: the reloaded service re-asserts a moment later, and
-- restoring first would only flash.
function onExit(_signal, reason)
	if not enabled or reason == "reload" then
		return
	end
	restoreAll()
	restoreWallpaper()
	if manageDaemon() and (reason == "disable" or reason == "uninstall") then
		noctalia.runAsync("systemctl --user stop " .. shellQuote(unitName()) .. " >/dev/null 2>&1")
	end
end

-- Initial pass at load. `update()` also runs on the first tick.
if enabled then
	reconcile()
end
