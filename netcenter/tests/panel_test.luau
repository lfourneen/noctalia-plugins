--!nonstrict
return function(report, loadPanel)
  local tree, paints = nil, 0
  local function find(node, text)
    if type(node) ~= "table" then return nil end
    if node.props and node.props.text == text then return node end
    for _, child in ipairs(node.children or {}) do
      local found = find(child, text)
      if found then return found end
    end
    return nil
  end
  local api = {
    tr = function(key) return key end,
    getConfig = function() return nil end,
    state = {
      get = function(key)
        if key == "network.state" then
          return { available = true, permission_ok = true, connections = {}, radio = {} }
        end
        return nil
      end,
      set = function() end,
      watch = function() end,
    },
  }
  local ui = setmetatable({}, { __index = function(_, kind)
    return function(props, children) return { kind = kind, props = props, children = children } end
  end })
  loadPanel(api, ui, { render = function(value) tree = value; paints += 1 end })
  assert(not find(tree, "panel.unavailable"), "hot reload must seed the live connection state")
  assert(find(tree, "panel.connections"), "connection controls must render on first paint")
  local before = paints
  find(tree, "tab.monitor").props.onClick()
  assert(paints == before + 1 and find(tree, "tab.monitor").props.selected,
    "Traffic & Ports click must repaint immediately without a timer")
  find(tree, "tab.control").props.onClick()
  assert(find(tree, "panel.connections"), "Connection tab must remain accessible")
  report("ok - panel loads live state and tab clicks render immediately")
end
