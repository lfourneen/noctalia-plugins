--!nonstrict
-- Waywallen Bridge bar widget: shows whether waywallen owns the background, and
-- suspends/resumes the service's arbitration so Noctalia's own wallpaper
-- switch can be used while waywallen runs.

local STATUS_KEY = "waywallen-bridge.status"
local SUSPEND_KEY = "waywallen-bridge.suspend"

local function glyphName()
	local configured = noctalia.getConfig("glyph")
	if type(configured) == "string" and configured ~= "" then
		return configured
	end
	return "wallpaper"
end

local function refresh(status)
	barWidget.setGlyph(glyphName())

	if type(status) ~= "table" then
		barWidget.setTooltip("Waywallen Bridge: waiting for the service")
		return
	end

	local yielded = status.yielded or 0
	if status.suspended then
		barWidget.setTooltip("Waywallen Bridge suspended - Noctalia wallpaper is active (click to resume)")
		barWidget.setColor("error")
	elseif yielded > 0 then
		barWidget.setTooltip("Waywallen Bridge owns the background on " .. tostring(yielded) .. " output(s) (click to suspend)")
		barWidget.setColor("primary")
	else
		barWidget.setTooltip(status.running and "Waywallen running" or "Waywallen not running (click to toggle)")
		barWidget.setColor("on_surface")
	end
end

local function toggleSuspend()
	local nowSuspended = noctalia.state.get(SUSPEND_KEY) == true
	noctalia.state.set(SUSPEND_KEY, not nowSuspended)
	if nowSuspended then
		noctalia.notify("Waywallen Bridge", "Resumed - Noctalia's wallpaper surface is hidden again")
	else
		noctalia.notify("Waywallen Bridge", "Suspended - the Noctalia wallpaper switch works again")
	end
end

function onClick()
	toggleSuspend()
end

noctalia.state.watch(STATUS_KEY, refresh)
refresh(noctalia.state.get(STATUS_KEY))
