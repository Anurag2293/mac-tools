# mac-tools

Small macOS tools I use every day: `ferry` (phone clipboard, files and screenshots), `lens`
(on-screen translation), `mac-use` (computer use for agents). Each folder has its own `README.md`;
read it before changing a tool.

## Conventions

- One folder per tool, named after the tool, with its own `README.md` and a row in the root
  README table. Nothing tool-specific at the root.
- Installed copies are symlinks back into this checkout (`~/.local/bin`, `~/Library/LaunchAgents`,
  ...), so editing a file here edits the live tool. Keep `main` working.
- Commit messages start with the tool name: `ferry: show copied text in a corner card`.
- `fileview/`, `kao-redirect/` and `.archive/` are local-only and gitignored. Build outputs
  (`.build/`, `mac-use/bin/`) are gitignored too.
- `~/Code/tools` is a symlink to this repo. Keep it: Helium loads kao-redirect as an unpacked
  extension from `~/Code/tools/kao-redirect`, and a new path would make it a new extension.
- `launchctl bootstrap` right after `bootout` fails with error 5, so install commands must retry it.

## Build and apply changes

- Swift: SwiftPM (`swift build`) fails at the manifest link step with this Mac's Command Line
  Tools. Every tool builds with `swiftc` directly:
  - mac-use: `mac-use/build.sh` (writes `mac-use/bin/mac-use`); a new tool copies it:
    `swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 Sources/<name>/*.swift -o bin/<name>`
  - ferry's corner previews (`ferry/peek/peek.swift`): built by `ferry setup`
  - lens: `lens build` (or `lens setup`); a rebuild invalidates its Screen Recording and Input
    Monitoring grants, and `lens setup` resets them so macOS asks again
- ferry: after editing the hub or peek, run `ferry setup`. After editing the Android app
  (`ferry/android/`, plain Java, no Gradle), run `ferry app install`. `ferry status` checks
  everything. Never delete `~/.config/ferry/release.keystore`: a new key forces an uninstall on the
  phone. Before changing the clipboard trigger, the app build or Syncthing, read "Gotchas" in
  `ferry/README.md`.
- mac-use: `Sources/mac-use/Standard.swift` is the MCP server's instructions and must say the same
  as `STANDARD.md`. Change both, then run `mac-use/build.sh`.
