--!nonstrict
-- Read only network counters; systemStats() also opts into CPU/GPU probes.
local M = {}

function M.sample(text, now, previous)
  local current = { at = now, interfaces = {} }
  for line in text:gmatch("[^\n]+") do
    local name, fields = line:match("^%s*([^:]+):%s*(.*)$")
    if name ~= nil and name ~= "lo" then
      local values = {}
      for value in fields:gmatch("%d+") do table.insert(values, tonumber(value)) end
      if #values >= 9 then
        current.interfaces[name] = { rx = values[1], tx = values[9] }
      end
    end
  end
  local rx, tx = 0, 0
  if previous ~= nil and now > previous.at then
    local seconds = (now - previous.at) / 1000
    for name, counters in pairs(current.interfaces) do
      local before = previous.interfaces[name]
      if before ~= nil then
        rx += math.max(0, counters.rx - before.rx) / seconds
        tx += math.max(0, counters.tx - before.tx) / seconds
      end
    end
  end
  return rx, tx, current
end

return M
