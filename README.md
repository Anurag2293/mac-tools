# mac-tools

Small tools I use every day on macOS (Apple silicon). Each folder is a self-contained tool with
its own README and install steps.

| Tool | What it does |
| --- | --- |
| [ferry](ferry/) | Clipboard, files and screenshots between the Mac and an Android phone over Tailscale |
| [lens](lens/) | Translate everything on screen in place (Japanese to English), Google Translate over on-device OCR |
| [mac-use](mac-use/) | Local computer use for agents: MCP server and CLI for native Mac apps |

## Conventions

- One folder per tool, named after the tool. Nothing tool-specific at the root.
- Each tool has a `README.md` covering what it does, dependencies, and how to install it.
- Installed copies point back here with symlinks (`~/.local/bin`, `~/Library/LaunchAgents`, and
  so on), so editing the repo is editing the live tool.
- Commit messages start with the tool name: `ferry: show copied text in a corner card`.
- Build outputs (`.build/`, `bin/`) and private or local-only folders are gitignored.

## License

[MIT](LICENSE)
