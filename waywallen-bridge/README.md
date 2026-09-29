# Waywallen Bridge

A [Noctalia](https://github.com/noctalia-dev/noctalia) plugin that lets
[waywallen](https://github.com/waywallen/waywallen) and Noctalia's built-in
wallpaper coexist instead of fighting over the background.

## The problem

Noctalia draws its wallpaper as its own `wlr-layer-shell` **Background** surface
(namespace `noctalia-wallpaper`). The switch under **Settings → Wallpaper** only
creates or tears down that surface. waywallen draws its own **Background**
surface (`waywallen-wallpaper`) and knows nothing about Noctalia, so when both
are up the two surfaces stack and Noctalia's wallpaper switch cannot turn
waywallen off - it just covers it (or gets covered).

## The fix

Noctalia exposes `noctalia.setWallpaperEnabled(connector, false)` to plugins,
which marks an output as externally managed and tears Noctalia's own surface
down - the same hook the official `mpvpaper` plugin uses. This plugin's
**service** calls it on every output while waywallen is running, and restores
Noctalia's surface when waywallen stops, the plugin is disabled, or you suspend
the arbitration from the bar widget.

## Requirements

- Noctalia v5 (plugin API 17+, i.e. `v5.0.0-beta.7` or newer).
- [waywallen](https://github.com/waywallen/waywallen) installed and running (a
  `waywallen.service` systemd user unit, its tray, or however you launch it).
- A `wlr-layer-shell` compositor (niri, Hyprland, Sway, ...).

## Install

### From a plugin source (recommended)

**Settings → Plugins → Add source → Git**, paste this repository's URL, then
enable **Waywallen Bridge** from the same page. Or from the command line:

```sh
noctalia msg plugins source add lfourneen git https://github.com/lfourneen/noctalia-plugins
noctalia msg plugins enable lfourneen/waywallen-bridge
```

Enable it once and `.luau` edits hot-reload; updates follow the source's
**Auto-update plugins** setting.

### As a local development copy

A `path` source is the directory whose **subdirectories** are plugins, so point
it at the folder that contains `waywallen-bridge/`:

```sh
noctalia msg plugins source add lfourneen-dev path /path/to/noctalia-plugins
noctalia msg plugins enable lfourneen/waywallen-bridge
```

Validate a checkout before enabling:

```sh
noctalia plugins lint /path/to/noctalia-plugins
```

## Use

The service activates as soon as the plugin is enabled - no widget required.

To add the optional bar widget, configure it like any plugin widget:

```toml
[widget.waywallen-bridge]
type = "lfourneen/waywallen-bridge:widget"
```

Left click suspends or resumes the arbitration; a suspended state lets
Noctalia's own wallpaper switch work again. IPC is also available:

```sh
noctalia msg plugin lfourneen/waywallen-bridge:service all refresh
noctalia msg plugin lfourneen/waywallen-bridge:service all suspend
noctalia msg plugin lfourneen/waywallen-bridge:service all resume
noctalia msg plugin lfourneen/waywallen-bridge:service all toggle
noctalia msg plugin lfourneen/waywallen-bridge:service all status
```

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| Hide Noctalia's wallpaper while waywallen runs | on | Master switch (`yield_wallpaper`). |
| Only while waywallen is running | on | Probe for a waywallen process; restore Noctalia's wallpaper otherwise. |
| Manage the waywallen service | off | Start/stop the systemd user unit with the plugin. Leave off when your init system starts it. |
| Service unit | `waywallen.service` | Unit used only by the option above. |
| Poll interval (seconds) | `3` | How often to re-check and re-assert. |

## How it works

- The service polls for a process whose command line contains `waywallen`
  (`noctalia.processMatches`) and, while found, calls
  `noctalia.setWallpaperEnabled(connector, false)` for every connected output.
- `setWallpaperEnabled` is runtime-only and clears when Noctalia restarts, so
  the service re-asserts it on every poll, on `onOutputsChanged` (hotplug), and
  on `onEnable`.
- `onExit` restores Noctalia's wallpaper (and stops the unit, if managed) when
  the plugin is disabled or removed; a plain reload is skipped to avoid a flash.

## Layout

```
waywallen-bridge/
  plugin.toml            # manifest: service + widget + settings
  service.luau           # the arbitration (runs headless)
  widget.luau            # optional bar widget: status + suspend toggle
  translations/en.json
  translations/zh-Hans.json
```

## 中文说明

Noctalia 的壁纸开关只控制它自己绘制的 `noctalia-wallpaper` 背景层，而 waywallen
绘制独立的 `waywallen-wallpaper` 背景层，两者互不知情会互相覆盖。本插件在检测到
waywallen 进程运行时，对每个输出调用 `noctalia.setWallpaperEnabled(conn, false)`，
让 Noctalia 主动让出背景层；waywallen 停止、插件被禁用、或在状态栏挂件里暂停时再
恢复。安装：**设置 → 插件 → 添加源 → Git** 填入本仓库链接，然后启用 **Waywallen Bridge**。

## License

MIT - see [LICENSE](../LICENSE).
