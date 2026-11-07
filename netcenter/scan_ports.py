"""Collect listening sockets outside Noctalia's per-callback CPU budget."""
import json
import re
import subprocess
import sys


def parse(text, include_udp, hide_system, only_own):
    listeners = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 6 or parts[0] not in ('tcp', 'udp'):
            continue
        proto = parts[0]
        address, _, port = parts[4].rpartition(':')
        if not port.isdecimal():
            continue
        port = int(port)
        if (proto == 'udp' and not include_udp) or (hide_system and port < 1024):
            continue
        address = address.split('%', 1)[0].strip('[]')
        owners = re.findall(r'\("(.*?)",pid=(\d+)', line) or [('', '0')]
        for process, pid in owners:
            pid = int(pid)
            if only_own and not pid:
                continue
            key = f'{proto}:{port}:{pid}'
            item = listeners.setdefault(key, dict(key=key, port=port, proto=proto,
                pid=pid, process=process, addresses=[], localOnly=True))
            if address not in item['addresses']:
                item['addresses'].append(address)
                item['localOnly'] &= address.startswith('127.') or address == '::1'
    return sorted(listeners.values(), key=lambda item: (not bool(item['pid']), item['port']))


if __name__ == '__main__':
    result = subprocess.run(['ss', '-tulnpH'], capture_output=True, text=True, timeout=8)
    if result.returncode:
        sys.stderr.write(result.stderr)
        sys.exit(result.returncode)
    print(json.dumps(parse(result.stdout, *(arg == 'true' for arg in sys.argv[1:4])), separators=(',', ':')))
