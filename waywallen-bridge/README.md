# Waywallen Bridge

A [Noctalia](https://github.com/noctalia-dev/noctalia) plugin that lets
[waywallen](https://github.com/waywallen/waywallen) draw the background while
Noctalia's own wallpaper keeps working in the background: its palette generator,
templates and lock screen follow waywallen's current wallpaper, instead of the
two fighting over the background layer.

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

## Colors and previews

Tearing the surface down would also cost Noctalia its palette generator and
wallpaper previews. So the service runs the W Engine plugin's "sync colors"
trick: it reads waywallen's current wallpaper from the renderer processes it
spawns (`waywallen-video-renderer` / `waywallen-image-renderer ... --path
<file>`), turns it into a still - the image itself, or a video frame decoded
with `ffmpeg` - and hands it to Noctalia with `noctalia.setWallpaper()`. The
palette generator (`[theme] source = "wallpaper"`), templates and lock screen
then follow the live wallpaper, while waywallen still draws the background. The
wallpaper Noctalia had before is saved and restored when you disable or suspend
the plugin.

Sync runs whether or not Noctalia's surface is hidden, so the palette and
previews keep following waywallen in both modes. Note that Noctalia's
control-center **Home tab preview** is drawn from its live wallpaper
*instance*: hiding the surface (yield on) removes that instance, so the preview
only appears with yield off.

Set `[theme] source = "wallpaper"` in Noctalia for the palette to follow it.

## Requirements

- Noctalia v5 (plugin API 17+, i.e. `v5.0.0-beta.7` or newer).
- [waywallen](https://github.com/waywallen/waywallen) installed and running (a
  `waywallen.service` systemd user unit, its tray, or however you launch it).
- `ffmpeg` for color sync when the wallpaper is a video (images need nothing).
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
noctalia msg plugin lfourneen/waywallen-bridge:service all sync
noctalia msg plugin lfourneen/waywallen-bridge:service all suspend
noctalia msg plugin lfourneen/waywallen-bridge:service all resume
noctalia msg plugin lfourneen/waywallen-bridge:service all toggle
noctalia msg plugin lfourneen/waywallen-bridge:service all status
```

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| Hide Noctalia's wallpaper while waywallen runs | on | Hide Noctalia's layer so waywallen is always visible; turn off to keep Noctalia's instance (Home-tab preview) and rely on layer order (`yield_wallpaper`). |
| Only while waywallen is running | on | Probe for a waywallen process; restore Noctalia's wallpaper otherwise. |
| Manage the waywallen service | off | Start/stop the systemd user unit with the plugin. Leave off when your init system starts it. |
| Service unit | `waywallen.service` | Unit used only by the option above. |
| Poll interval (seconds) | `3` | How often to re-check and re-assert. |
| Sync Noctalia's colors from the wallpaper | on | Feed Noctalia a still of waywallen's wallpaper (`sync_colors`). |
| Video frame at (seconds) | `1` | Timestamp of the frame captured from a video wallpaper. |

## How it works

- The service polls for a process whose command line contains `waywallen`
  (`noctalia.processMatches`) and, while found, calls
  `noctalia.setWallpaperEnabled(connector, false)` for every connected output.
- `setWallpaperEnabled` is runtime-only and clears when Noctalia restarts, so
  the service re-asserts it on every poll, on `onOutputsChanged` (hotplug), and
  on `onEnable`.
- For color sync it runs one `ps` scan per poll (shared with the running
  probe), pulls `--path` from `waywallen-*-renderer`, decodes a video frame with
  `ffmpeg` **once** and caches it as `frame-<hash>-<mtime>.jpg`, then calls
  `noctalia.setWallpaper()` only when the still changes. Old frames are cleaned
  up. The previous wallpaper is saved per output and put back on suspend or exit.
- `onExit` restores Noctalia's surface and wallpaper (and stops the unit, if
  managed) when the plugin is disabled or removed; a plain reload is skipped to
  avoid a flash.

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
恢复。配色同步：从 waywallen 的渲染进程读取当前壁纸文件，图片直接用、视频用 ffmpeg
抽一帧，再 `noctalia.setWallpaper()` 交给 Noctalia，于是调色板、模板和锁屏跟随动态
壁纸（把 `[theme] source` 设为 `"wallpaper"`）。安装：**设置 → 插件 → 添加源 → Git**
填入本仓库链接，然后启用 **Waywallen Bridge**。

## License

MIT - see [LICENSE](../LICENSE).
