# Local Computer Use Standard v1

How any agent (Claude, GPT/Codex, or anything else that speaks MCP) operates this Mac's real screen, mouse, and keyboard. The `mac-use` MCP server sends a condensed copy of these rules as its server instructions (`Sources/mac-use/Standard.swift`). Keep the two in sync.

## 1. Pick the least-invasive route

Use the first option that can do the job:

1. An existing CLI, API, or app-specific MCP server (for example `gh`, TickTick MCP, Microsoft 365 MCP).
2. `run_script`: AppleScript or JavaScript for Automation, for scriptable apps such as Finder, Mail, Safari, Notes, Music, and System Events.
3. `menu`: the app's menu bar, by path (`File > Export…`).
4. Element actions by `[index]` from `observe`: `click`, `type_text`, `set_value`, `scroll`, `drag`.
5. `find_text` (OCR), or `click` with `text`, for apps that draw their own UI.
6. Raw `x,y` screenshot coordinates, as a last resort.

Web pages belong to browser tools: Playwright MCP for real sites, and T3 Code's preview for local dev servers. Use `mac-use` for native apps and anything outside a browser.

## 2. The loop

```
observe → act (one action, or a short run on the same view) → observe again → ...
```

- Call `observe` before acting on an app.
- After acting, verify with `observe`. Set `screenshot: false` when the element list is enough.
- A tool result only means the event was sent. It does not mean the app did what you wanted.
- Use `wait_for` for loading or animations instead of sleeping.

## 3. Addressing

- `[index]` values come from the latest `observe` only.
- `x,y` are pixels of the latest image from `observe`, `screenshot`, or `find_text`.
- Re-observe whenever the UI may have changed (navigation, dialogs, scrolling).
- Through the CLI, chain steps in one `mac-use call` invocation. Indices do not survive between processes.

## 4. Ask first

Get the user's confirmation before anything irreversible or outward-facing:

- sending messages or email, posting, or commenting
- purchases and payments
- deleting files or data, emptying the Trash
- submitting forms
- changing System Settings, or granting permission or Automation prompts

## 5. Never

- Type passwords, 2FA codes, recovery keys, or payment details. Hand those steps to the user.
- Touch apps in `deny_apps` (password managers and Keychain by default). The server enforces this.
- Work around a pause, a deny rule, or a permission prompt.

## 6. Pause and stop

- The user pauses all agents by moving the mouse into the **top-left corner** of the main display, or by running `mac-use pause`.
- When a tool reports that mac-use is paused, stop and tell the user. Only the user runs `mac-use resume`.

## 7. Leave things as you found them

- Stay inside the apps the task needs.
- Do not rearrange, close, or quit the user's other windows.
- Close documents you created for the task, and do not save scratch work unless asked.
- Finish by telling the user what you changed. Every action is logged to `~/Library/Logs/mac-use/actions.jsonl`.

## Tools

| Tool | Use |
|---|---|
| `list_apps` | Running apps, bundle ids, pids, window counts |
| `open_app` | Launch or focus an app |
| `observe` | Screenshot of an app's window and its numbered UI elements |
| `screenshot` | Whole display (desktop, menu bar, several windows) |
| `click` | By `[index]` (accessibility press when possible), OCR `text`, or `x,y` |
| `type_text` | Keyboard text into the focused field or an `[index]`; `clear`, `submit` |
| `set_value` | Set a field or slider value directly through accessibility |
| `press_key` | Keys and shortcuts: `return`, `cmd+s`, `cmd+a backspace` |
| `scroll` | Wheel scroll over an element, a point, or the window |
| `drag` | Drag between elements or points |
| `hover` | Move the mouse without clicking |
| `find_text` | OCR: find text or read all visible text |
| `wait_for` | Wait for text to appear or disappear |
| `menu` | List or select menu bar items, with their shortcuts |
| `run_script` | AppleScript or JXA through `osascript` |

## Versioning

Change the version in this file and in `Standard.swift` whenever a rule changes. Agents report the version they followed when it matters.
