# mac-use

Local computer use for agents on macOS: an MCP server and a CLI that let Claude, GPT/Codex, or any MCP client see and operate native apps. The rules agents follow are in [STANDARD.md](STANDARD.md).

It is a single Swift binary with no dependencies, built on Apple's frameworks: Accessibility for UI elements and presses, ScreenCaptureKit for screenshots, Vision for OCR, and CGEvent for mouse and keyboard input.

## Build and install

```sh
./build.sh                                   # → bin/mac-use
ln -sf "$PWD/bin/mac-use" ~/.local/bin/mac-use
```

`build.sh` calls `swiftc` directly because SwiftPM's manifest step fails to link with the installed Command Line Tools.

## Register with agents

Claude Code. T3 Code's Claude provider picks up user-scope servers automatically.

```sh
claude mcp add -s user mac-use -- ~/.local/bin/mac-use mcp
```

Codex. Edit `~/.codex/config.toml` by hand: `codex mcp add` rewrites the whole file.

```toml
[mcp_servers.mac-use]
command = "/Users/anurag/.local/bin/mac-use"
args = ["mcp"]
tool_timeout_sec = 120
```

## Permissions

The app that launches the agent (T3 Code, a terminal) needs **Accessibility** and **Screen Recording** in System Settings > Privacy & Security. `run_script` also triggers a one-time **Automation** prompt per target app. The user answers it; agents must not.

```sh
mac-use status
```

## CLI

```sh
mac-use call list_apps
mac-use call observe '{"app":"Finder"}' click '{"element":3}'   # chain steps in one process
mac-use pause | resume
mac-use standard
```

`observe` and `screenshot` save their latest image to `~/Library/Caches/mac-use/`.

## Files

| Path | What |
|---|---|
| `~/Library/Application Support/mac-use/config.json` | `deny_apps` and `allow_apps` |
| `~/Library/Application Support/mac-use/PAUSED` | Present while paused |
| `~/Library/Logs/mac-use/actions.jsonl` | Every action, with long text truncated |
| `~/Library/Caches/mac-use/` | Latest screenshots |

## Known limits

- `observe` brings the app to the front. Computer use and the user share one screen.
- `press_key` letter names assume a US keyboard layout. `type_text` is layout-independent.
- Electron apps build their accessibility tree on first `observe`, which adds about 1.5 s once.
- Pop-up and menu buttons get a real mouse click, because an accessibility press blocks until their menu closes.
- Apps that draw their own UI (games, canvases, remote desktops) list few elements. Use `find_text` and coordinates.
