--!nonstrict
-- Exercise scheduling and recovery without launching or killing real processes.
return function(report, loadScanner)
  local function fixture(started)
    local now, poll = 100000, 3
    local state, watchers, callbacks = {}, {}, {}
    local api = {
      getSetting = function() return poll end,
      getConfig = function(key)
        return ({ refresh_interval = 5, include_udp = true, hide_system_ports = false, only_own_processes = false })[key]
      end,
      nowMs = function() return now end,
      setUpdateInterval = function() end,
      readFile = function() return `eth0: {now} 0 0 0 0 0 0 0 {now * 2} 0 0 0 0 0 0 0` end,
      json = { decode = function() return { { port = 8766 } } end },
      log = function() end,
      state = {
        set = function(key, value) state[key] = value end,
        get = function(key) return state[key] end,
        watch = function(key, cb) watchers[key] = cb end,
      },
      runAsync = function(_, cb, timeout)
        assert(timeout == 10000, "scan must have a bounded timeout")
        table.insert(callbacks, cb)
        return started
      end,
    }
    local env = loadScanner(api)
    return { env = env, state = state, watchers = watchers, callbacks = callbacks,
      tick = function(value) now = value; env.update() end,
      poll = function(value) poll = value end }
  end
  local success = { exitCode = 0, stdout = 'tcp LISTEN 0 128 127.0.0.1:8766 0.0.0.0:* users:(("server",pid=123,fd=3))', stderr = "" }
  local f = fixture(false)
  assert(f.state.scan_error == true)
  f.tick(105000)
  assert(#f.callbacks == 2, "launch failure must retry")
  assert(#f.state.traffic.rxHistory == 2, "traffic continues after launch failure")
  report("ok - scan launch failure retries without blocking traffic")

  f = fixture(true)
  f.tick(113000)
  assert(#f.callbacks == 2, "missing callback must trigger watchdog retry")
  f.callbacks[1](success)
  assert(f.state.scan_error == true, "stale completion must not clear current error")
  f.callbacks[2](success)
  f.env.update()
  assert(f.state.scan_error == false and #f.state.listeners == 1)
  report("ok - watchdog retries and ignores late results")

  f.tick(118000)
  f.callbacks[3]({ exitCode = 0, timedOut = true, stdout = "", stderr = "timeout" })
  assert(f.state.scan_error == true)
  f.tick(123000)
  f.callbacks[4](success)
  f.env.update()
  assert(f.state.scan_error == false)
  report("ok - timed out scan recovers on next interval")

  f = fixture(true)
  f.tick(90000)
  assert(#f.callbacks == 2, "backwards clock must release pending scan")
  f.watchers.scan(nil)
  f.watchers.scan("bad")
  f.watchers.scan(0/0)
  report("ok - backwards clock and invalid scan requests")

  f.callbacks[2](success)
  f.env.update()
  f.poll(0)
  f.tick(100000)
  local count = #f.state.traffic.rxHistory
  f.poll(1)
  f.tick(101000)
  assert(#f.state.traffic.rxHistory == count + 1, "poll setting must take effect without reload")
  for i = 1, 65 do f.tick(101000 + i * 1000) end
  assert(#f.state.traffic.rxHistory == 60 and #f.state.traffic.txHistory == 60)
  report("ok - live polling settings and bounded traffic history")
end
