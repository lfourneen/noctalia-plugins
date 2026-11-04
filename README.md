# noctalia-plugins

Personal [Noctalia](https://github.com/noctalia-dev/noctalia) plugin source.
Each plugin lives in its own directory (matching the part of its id after `/`),
and `catalog.toml` indexes them so Noctalia can list the plugins without a full
checkout.

## Plugins

| Plugin | Description |
| --- | --- |
| [waywallen-bridge](waywallen-bridge/) | Make [waywallen](https://github.com/waywallen/waywallen) and Noctalia's built-in wallpaper coexist instead of stacking. |
| [netcenter](netcenter/) | One network tile and panel: IP address, upload/download speed and listening ports. |

## Add this source

**Settings → Plugins → Add source → Git**, paste the URL, then enable the
plugin from the same page. Or from the command line:

```sh
noctalia msg plugins source add lfourneen git https://github.com/lfourneen/noctalia-plugins
noctalia msg plugins list
noctalia msg plugins enable lfourneen/<plugin>
```

Replace `<plugin>` with the directory name of the plugin you want from the
list above.

Noctalia updates git sources automatically (startup and every 6 hours) according
to **Settings → Plugins → Auto-update plugins**.

## Layout

```
.
├── catalog.toml          # index read from the git source
├── LICENSE
├── waywallen-bridge/
│   ├── plugin.toml       # manifest: entries + settings
│   ├── service.luau      # headless wallpaper arbitration
│   ├── widget.luau       # optional bar widget
│   ├── translations/
│   └── README.md
└── netcenter/
    ├── plugin.toml       # merged manifest: two services, one widget, one panel
    ├── service.luau      # NetworkManager state and profile writes
    ├── scanner.luau      # traffic sampling and port scan
    ├── widget.luau       # IP + speeds + port count
    ├── panel.luau        # one panel: connection, traffic, ports, Wi-Fi/editor
    ├── net.luau
    ├── listeners.luau
    ├── rates.luau
    ├── translations/
    └── README.md
```

## Adding a plugin

Create `<repo>/<name>/plugin.toml` (the directory name is the id segment after
`/`), add a matching `[[plugin]]` row to `catalog.toml`, and validate it:

```sh
noctalia plugins lint path/to/repo
```

## License

MIT - see [LICENSE](LICENSE).
