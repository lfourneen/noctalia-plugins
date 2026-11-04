--!nonstrict
-- Network Center bar widget: the default route's address, live upload/download
-- rates and the listening-port count in one tile.
--
-- Address state comes from the network service (Network Control), traffic and
-- listeners from the scanner service (Network Monitor). Click opens the single
-- combined panel.

local rates = require("./rates.luau")

local NETWORK_MEGABYTE = 1000000

local KIND_GLYPHS = {
  wifi = "wifi",
  ethernet = "plug-connected",
  dummy = "binary-tree",
  bridge = "network",
  loopback = "refresh",
  vpn = "shield-lock",
}

local snapshot = { available = false }
local traffic = { rx = 0, tx = 0 }
local listeners = {}
local dirty = true

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function num(value)
  return tonumber(value) or 0
end

local function orEmpty(value)
  if value == nil or value == "" then
    return tr("panel.empty")
  end
  return value
end

local function primaryGlyph(primary)
  local fallback = noctalia.getConfig("glyph") or "network"
  local live = type(primary) == "table" and primary.live or nil
  if type(live) == "table" then
    return KIND_GLYPHS[live.kind] or fallback
  end
  return fallback
end

local function addressText(primary)
  if type(primary) ~= "table" then
    return nil
  end
  if (primary.address or "") ~= "" then
    return primary.address
  end
  local live = primary.live
  if type(live) == "table" then
    if live.kind == "wifi" and (live.connection or "") ~= "" then
      return live.connection
    end
    local v4 = live.ipv4_addresses or {}
    if #v4 > 0 then
      return v4[1]
    end
    local v6 = live.ipv6_addresses or {}
    if #v6 > 0 then
      return v6[1]
    end
    if (live.connection or "") ~= "" then
      return live.connection
    end
  end
  return nil
end

local function addressBlock(showText)
  local pending = snapshot.pending
  local primary = snapshot.primary
  local glyph, text, color
  if pending ~= nil then
    local remaining = math.max(0, math.ceil((pending.deadline_ms - (snapshot.now_ms or 0)) / 1000))
    glyph, text, color = "hourglass", tostring(remaining) .. "s", "error"
  elseif primary == nil then
    glyph, text, color = "network-off", tr("bar.offline"), "on_surface_variant"
  else
    glyph = primaryGlyph(primary)
    text = addressText(primary) or tr("bar.offline")
    color = "on_surface"
  end

  if not showText then
    return ui.glyph({ name = glyph, color = color })
  end
  return ui.row({ gap = 4, align = "center" }, {
    ui.glyph({ name = glyph, color = color }),
    ui.label({ text = text, color = color, maxLines = 1 }),
  })
end

local function speedSettings()
  local activity = tonumber(noctalia.getConfig("speed_activity_mbps")) or 1.0
  local critical = tonumber(noctalia.getConfig("speed_critical_mbps")) or 50.0
  if activity < 0 then
    activity = 0
  end
  if critical < 0 then
    critical = 0
  end
  return activity, critical,
      noctalia.getConfig("speed_normal_color") or "on_surface",
      noctalia.getConfig("speed_activity_color") or "primary",
      noctalia.getConfig("speed_critical_color") or "error"
end

-- Thresholds are in MB/s; the rates here are bytes/s.
local function speedColor(value)
  local activity, critical, normal, active, hot = speedSettings()
  local mb = value / NETWORK_MEGABYTE
  if critical > 0 and mb >= critical then
    return hot
  end
  if mb >= activity then
    return active
  end
  return normal
end

local function rateRow(glyph: string, bytesPerSecond)
  local value = num(bytesPerSecond)
  local color = speedColor(value)
  return ui.row({ gap = 2, align = "center" }, {
    ui.glyph({ name = glyph, size = 9, color = color }),
    ui.label({
      text = rates.compact(value),
      fontSize = 9,
      fontFamily = "monospace",
      color = color,
      flexGrow = 1,
      textAlign = "end",
    }),
  })
end

local function speedBlock()
  -- Fixed width, but the values are right-aligned so the gap to the port block
  -- is the same as the gap to the address block.
  return ui.column({ gap = 0, align = "stretch", minWidth = 52 }, {
    rateRow("arrow-up", traffic.tx),
    rateRow("arrow-down", traffic.rx),
  })
end

local function portBlock()
  return ui.row({ gap = 4, align = "center", minWidth = 34 }, {
    ui.glyph({ name = "plug-connected", color = "on_surface_variant" }),
    ui.label({ text = tostring(#listeners), flexGrow = 1, textAlign = "end" }),
  })
end

local function tooltipRows()
  local rows = {}
  local primary = snapshot.primary
  if snapshot.pending ~= nil then
    local remaining = math.max(0, math.ceil((snapshot.pending.deadline_ms - (snapshot.now_ms or 0)) / 1000))
    table.insert(rows, { key = tr("bar.confirm_title"), value = snapshot.pending.name })
    table.insert(rows, { key = tr("bar.confirm_body"), value = tostring(remaining) })
  end
  if type(primary) == "table" then
    table.insert(rows, { key = tr("tooltip.device"), value = primary.device })
    local live = primary.live
    if type(live) == "table" then
      table.insert(rows, { key = tr("tooltip.connection"), value = orEmpty(live.connection) })
      table.insert(rows, {
        key = tr("tooltip.ipv4"),
        value = #(live.ipv4_addresses or {}) > 0 and table.concat(live.ipv4_addresses, ", ") or tr("panel.empty"),
      })
      if (live.ipv4_gateway or "") ~= "" then
        table.insert(rows, { key = tr("tooltip.gateway"), value = live.ipv4_gateway })
      end
      if #(live.ipv4_dns or {}) > 0 then
        table.insert(rows, { key = tr("tooltip.dns"), value = table.concat(live.ipv4_dns, ", ") })
      end
      if #(live.ipv6_addresses or {}) > 0 then
        table.insert(rows, { key = tr("tooltip.ipv6"), value = live.ipv6_addresses[1] })
      end
    end
  else
    table.insert(rows, { key = tr("tooltip.device"), value = tr("bar.offline") })
  end
  table.insert(rows, {
    key = tr("panel.traffic"),
    value = tr("tooltip.speed", { rx = rates.full(num(traffic.rx)), tx = rates.full(num(traffic.tx)) }),
  })
  table.insert(rows, { key = tr("panel.listening_ports"), value = tostring(#listeners) })
  table.insert(rows, { key = tr("tooltip.open"), value = "" })
  return rows
end

local function render()
  local showText = noctalia.getConfig("show_text") == true
  local showSpeed = noctalia.getConfig("show_speed") == true
  local showPorts = noctalia.getConfig("show_ports") == true

  local parts = { addressBlock(showText) }
  if showSpeed then
    table.insert(parts, speedBlock())
  end
  if showPorts then
    table.insert(parts, portBlock())
  end

  barWidget.render(ui.row({ gap = 12, align = "center" }, parts))
  barWidget.setTooltip(tooltipRows())
end

function update()
  -- Coalesce the three state channels into one paint per bar tick, and keep
  -- repainting while the confirm countdown is live.
  if dirty or snapshot.pending ~= nil then
    dirty = false
    render()
  end
end

function onClick()
  noctalia.togglePanel("lfourneen/netcenter:panel")
end

noctalia.state.watch("network.state", function(value)
  if type(value) == "table" then
    snapshot = value
    dirty = true
  end
end)

noctalia.state.watch("traffic", function(value)
  if type(value) == "table" then
    traffic = value
    dirty = true
  end
end)

noctalia.state.watch("listeners", function(value)
  listeners = value or {}
  dirty = true
end)

local initialState = noctalia.state.get("network.state")
if type(initialState) == "table" then
  snapshot = initialState
end
local initialTraffic = noctalia.state.get("traffic")
if type(initialTraffic) == "table" then
  traffic = initialTraffic
end
listeners = noctalia.state.get("listeners") or {}

render()

-- state.watch does not replay an old value to a late-attaching entry, so ask for
-- a snapshot on load instead of rendering the default forever.
noctalia.state.set("network.request", { action = "refresh" })
