# Network Center

One Noctalia plugin for the network: the default route's IP, live upload and
download rates, and the listening-port count in a single bar tile, plus one
panel that combines Wi-Fi/connection management with the traffic graph and port
list. No capsule group, no second menu, no second settings page.

## Built from

This plugin is a merged derivative of two Noctalia community plugins. The
original code, behaviour and translations come from them; credit belongs to
their authors.

- **Network Control** — `muhammadessam/network-control`
  ([Noctalia community plugins](https://github.com/noctalia-dev/community-plugins)):
  NetworkManager profiles, Wi-Fi joining, DHCP/static addressing with the
  confirm-and-rollback window.
- **Network Monitor** — `mahmoudomiesh/network-monitor`
  ([Noctalia community plugins](https://github.com/noctalia-dev/community-plugins)):
  traffic sampling, the traffic graph and the `ss` listening-port table with
  open/stop actions.

Both are MIT-licensed; this combined plugin keeps the same license. The wrapper
code, bar layout and panel composition are the changes made here.

## Bar tile

One widget shows, left to right:

```
[wifi] 192.168.1.42   ↑ 1.2KB/s   [plug] 7
                      ↓ 3.4MB/s
```

- Network glyph + the default route's address (or the SSID when there is no
  address); a pending NetworkManager change turns it into a countdown.
- Upload on top, download below, always with units (`B/s`, `KB/s`, `MB/s`).
- Listening-port count.
- Click opens the combined panel; the tooltip has full connection information
  (device, connection name, IPv4/IPv6, gateway, DNS), traffic and port count.

The speed block uses a fixed width and the address a fixed 15-character field so
the bar does not jump as values change. The font is kept small enough (9px) to
fit a standard 34px bar; the speed block occupies one column instead of two.

## Panel

One panel with two tabs, opened on the **Connection** tab:

- **Connection** — the original Network Control view: primary connection
  summary, NetworkManager permission/error state, Wi-Fi radio and network list
  (scan, join, hidden network), connection profiles and the addressing editor
  (DHCP/static, IPv4/IPv6, gateway, DNS, search domains) with the
  apply/keep/revert flow.
- **Traffic & Ports** — the original Network Monitor view: live RX/TX graph
  (separately colored, with a Download/Upload legend below it) and the `ss`
  listening-port table with open-in-browser and stop actions.

The tab bar stays fixed at the top; each tab scrolls on its own, so the two
views do not turn into one long page.

The header has refresh, plugin settings and close. Refresh re-reads
NetworkManager and re-scans the ports; the ports table is also scanned when the
panel opens.

## Settings

| Key | Default | What it does |
| --- | --- | --- |
| `confirm_seconds` | `45` | Rollback window after a profile write; `0` applies immediately. |
| `refresh_seconds` | `15` | How often the profile and live addresses are re-read. |
| `show_speed` | `true` | Upload/download rates in the bar. |
| `show_ports` | `true` | Listening-port count in the bar. |
| `speed_activity_mbps` | `1.0` | Rate (MB/s) where the activity color starts. |
| `speed_critical_mbps` | `10.0` | Rate (MB/s) where the critical color starts. |
| `speed_normal_color` | `on_surface` | Color below the activity threshold. |
| `speed_activity_color` | `primary` | Color between activity and critical. |
| `speed_critical_color` | `error` | Color at or above critical. |
| `traffic_download_color` | `primary` | Download waveform and legend color. |
| `traffic_upload_color` | `secondary` | Upload waveform and legend color. |
| `refresh_interval` | `5` | Port scan interval in seconds. |
| `hide_system_ports` | `true` | Skip well-known ports below 1024. |
| `only_own_processes` | `false` | Only list listeners with a visible process ID. |
| `include_udp` | `false` | Also list UDP sockets. |
| `show_text` | `true` | Show the address next to the network glyph. |
| `glyph` | `network` | Fallback glyph when no interface kind is known. |

## Dependencies

`nmcli`, `ip`, `install`, `chmod` (NetworkManager addressing), `ss`, `kill`,
`fuser`, `pkexec` (port scan and stop actions), `xdg-open` (open a TCP port in
the browser).

## Changes carried over from the local versions

- Network Monitor speeds always show a unit; the old compact formatter printed
  a bare number below 1000 B/s.
- The traffic sampler guards against a backwards wall-clock step (NTP,
  suspend/resume) instead of freezing its deadlines in the future.
- Upload/download are stacked in one column and the port count is padded, so the
  bar width stays stable.
- The Wi-Fi-off case no longer raises a "scan failed" error toast when the panel
  is opened; it stays an inline hint.
- The panel's settings button opens the single plugin settings page, which now
  contains both the addressing and the traffic/port options.
