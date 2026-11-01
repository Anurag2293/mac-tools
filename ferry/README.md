# ferry

Clipboard, files and screenshots between a Mac and an Android phone, over Tailscale, on Wi-Fi or
mobile data. A small Continuity for Android: copy on one side, paste on the other; share a photo
from the phone and it lands in `~/Downloads`; ask the Mac for a live screenshot of the phone.

Day to day nothing needs adb. adb is needed once to install the app (Android only grants
READ_LOGS and accessibility over adb), and is kept as a text-only fallback.

## What it does

| Direction | How |
| --- | --- |
| Mac → phone | Text and images copied on the Mac are put on the phone clipboard. |
| Phone → Mac, automatic | Text and images copied on the phone appear on the Mac clipboard. Text shows a notification-style card in the top-right corner (links are clickable; clips marked sensitive by password managers stay hidden). |
| Phone → Mac, manual | "Send to Mac" Quick Settings tile, a button on the app's notification, and Share › Send to Mac (files go to `~/Downloads` with a corner thumbnail). |
| Live screenshot | `ferry shot` captures the phone screen in about a second, even while it is locked. |
| Phone screenshots | `ferry last [N]` reads screenshots that Syncthing mirrors to `~/Pictures/PhoneScreenshots`; each new one slides in as a bottom-right thumbnail, like macOS screenshots. |

## Parts

```
ferry            CLI: shot, last, status, setup, app install, logs, peek, adb …
hub/ferryd       Mac hub (Python, stdlib only), launchd agent com.anurag.ferry
peek/peek.swift  corner thumbnails and text cards, launchd agent com.anurag.ferry-peek
android/         the Ferry app (com.anurag.ferry), plain Java, built without Gradle
```

- **Hub.** Listens on the Mac's Tailscale IP, port 47821. The app authenticates with a random
  token (`~/.config/ferry/token`, sent once over adb at install), and only the phone's tailnet IP
  is accepted. Frames are a u32 header length, a JSON header, then raw bytes. It also serves a
  control socket (`~/.config/ferry/ctl.sock`) that `ferry shot` uses.
- **App.** A foreground service keeps the connection up. Android 10+ blocks background clipboard
  reads, so the app watches logcat for the system's "Denying clipboard access" line, then a 1×1
  activity takes focus for a moment and reads the clipboard. Live screenshots use an
  accessibility service (`takeScreenshot`); secure screens come out black.
- **Peek.** A nonactivating AppKit panel: drag the thumbnail into any app, swipe or press x to
  dismiss, right-click for Copy / Show in Finder.

## Install

Requirements: Apple silicon Mac, Xcode Command Line Tools (`swiftc`), Python 3, Tailscale on both
devices, and for building the app:

```sh
brew install --cask android-commandlinetools android-platform-tools
brew install openjdk@21 scrcpy
sdkmanager 'platforms;android-36.1' 'build-tools;36.1.0'
brew install syncthing && brew services start syncthing   # optional, for `ferry last`
```

Then:

```sh
ln -s "$PWD/ferry" ~/.local/bin/ferry
ferry setup                 # Mac services (hub + previews)
ferry adb pair HOST:PORT CODE   # once: Developer options > Wireless debugging > Pair with code
ferry app install           # build, install, grant permissions, point the app at this Mac
```

Open Ferry on the phone and tap **Allow** when Android asks about device logs. Android 13+ asks
again after every reboot or app update; the app's notification says so when it is needed.

Syncthing (optional): share the phone's `Pictures/Screenshots` as a send-only folder with id
`pixel-screenshots` into `~/Pictures/PhoneScreenshots` (receive-only on the Mac).

## Use

```sh
ferry shot          # live screenshot; prints the PNG path and copies the image
ferry last 3        # the 3 newest phone screenshots
ferry status        # services, phone connection, Syncthing, adb
ferry logs app      # follow the app's logcat (needs adb)
```

After editing the hub or peek, run `ferry setup`. After editing the app, run `ferry app install`.

Tested on a Pixel 7 Pro with Android 17 and macOS 26.
