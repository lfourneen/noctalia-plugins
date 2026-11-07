#!/usr/bin/env python3
"""Run the real scanner against a fake Noctalia host, plus parser/format tests."""
import argparse
from pathlib import Path
import shutil
import re
import runpy
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--luau', default='luau')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
parse_ports = runpy.run_path(str(root / 'scan_ports.py'))['parse']
sample = re.search(r'local sample = \[\[(.*?)\]\]', (root / 'tests/listeners_test.luau').read_text(), re.S)[1]
assert [p['port'] for p in parse_ports(sample, False, True, False)] == [3000, 3773, 6463, 5355]
assert len(parse_ports(sample, True, False, False)) == 6
assert len(parse_ports(sample, True, False, True)) == 3
assert parse_ports('', True, False, False) == []
shared = 'tcp LISTEN 0 128 127.0.0.1:8766 0.0.0.0:* users:(("worker",pid=301,fd=3),("worker",pid=302,fd=3))'
assert [p['pid'] for p in parse_ports(shared, False, True, False)] == [301, 302]
print('ok - external port collector filters, merges IPv4/IPv6 and preserves shared owners', flush=True)

with tempfile.TemporaryDirectory(prefix='netcenter-tests-') as directory:
    target = Path(directory)
    shutil.copytree(root, target / 'netcenter')
    source = (root / 'scanner.luau').read_text()
    runner = '''local listeners = require("./netcenter/listeners")
local traffic = require("./netcenter/traffic")
local function loadScanner(api)
  local chunk = assert(loadstring([====[SOURCE]====]))
  local env = setmetatable({noctalia = api, require = function(path)
    if path == "./listeners.luau" then return listeners end
    assert(path == "./traffic.luau")
    return traffic
  end}, {__index = getfenv()})
  setfenv(chunk, env)
  chunk()
  return env
end
local rx, tx, first = traffic.sample("eth0: 100 0 0 0 0 0 0 0 200", 1000)
assert(rx == 0 and tx == 0)
rx, tx, first = traffic.sample("eth0: 300 0 0 0 0 0 0 0 800\\nlo: 99999 0 0 0 0 0 0 0 99999", 3000, first)
assert(rx == 100 and tx == 300)
rx, tx = traffic.sample("eth0: 0 0 0 0 0 0 0 0 0", 4000, first)
assert(rx == 0 and tx == 0)
print("ok - traffic elapsed time, loopback exclusion and counter reset")
require("./netcenter/tests/scanner_test")(print, loadScanner)
require("./netcenter/tests/listeners_test")(print)
require("./netcenter/tests/rates_test")(print)
'''.replace('SOURCE', source)
    panel_source = (root / 'panel.luau').read_text()
    runner += '''
local net = require("./netcenter/net")
local rates = require("./netcenter/rates")
local function loadPanel(api, ui, panel)
  local chunk = assert(loadstring([====[PANEL_SOURCE]====]))
  local modules = {["./net.luau"] = net, ["./rates.luau"] = rates, ["./listeners.luau"] = listeners}
  setfenv(chunk, setmetatable({noctalia = api, ui = ui, panel = panel,
    require = function(path) return assert(modules[path]) end}, {__index = getfenv()}))
  chunk()
end
require("./netcenter/tests/panel_test")(print, loadPanel)
'''.replace('PANEL_SOURCE', panel_source)
    (target / 'run.luau').write_text(runner)
    # The CLI resolves modules without file extensions; the host also accepts .luau.
    for path in (target / 'netcenter/tests').glob('*_test.luau'):
        path.write_text(path.read_text().replace('../listeners.luau', '../listeners').replace('../rates.luau', '../rates'))
    subprocess.run([args.luau, str(target / 'run.luau')], check=True)
