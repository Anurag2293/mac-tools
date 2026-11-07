# mac-tools

Small macOS tools I use every day: `ferry` (phone clipboard, files and screenshots), `lens`
(on-screen translation), `mac-use` (computer use for agents). Each folder has its own `README.md`;
read it before changing a tool.

## Conventions

- One folder per tool, named after the tool. Nothing tool-specific at the root.
- Installed copies are symlinks back into this checkout (`~/.local/bin`, `~/Library/LaunchAgents`,
  ...), so editing a file here edits the live tool. Keep `main` working.
- Commit messages start with the tool name: `ferry: show copied text in a corner card`.
- `fileview/`, `kao-redirect/` and `.archive/` are local-only and gitignored. Build outputs
  (`.build/`, `mac-use/bin/`) are gitignored too.

## Build and apply changes

- Swift: SwiftPM (`swift build`) fails at the manifest link step with this Mac's Command Line
  Tools. Every tool builds with `swiftc` directly:
  - mac-use: `mac-use/build.sh` (writes `mac-use/bin/mac-use`)
  - ferry's corner previews (`ferry/peek/peek.swift`): built by `ferry setup`
  - lens: `lens build` (or `lens setup`); a rebuild invalidates its Screen Recording and Input
    Monitoring grants, and `lens setup` resets them so macOS asks again
- ferry: after editing the hub or peek, run `ferry setup`. After editing the Android app
  (`ferry/android/`, plain Java, no Gradle), run `ferry app install`. `ferry status` checks
  everything.
- mac-use: `Sources/mac-use/Standard.swift` is the MCP server's instructions and must say the same
  as `STANDARD.md`. Change both, then run `mac-use/build.sh`.
