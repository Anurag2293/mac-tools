# lens

Translate everything on screen in place, like Google Translate's screen translation on Android.
**Double-tap right ⌘**: the display under the pointer is captured, read with on-device Vision OCR,
translated with Google Translate, and the English is painted over the Japanese in a full-screen
overlay, matching each block's background and text color. A full screen takes about 2 s: 1.5 s
of OCR (the floor for Vision's Japanese model; downscaling or tiling does not help) and 0.3 s of
translation.

- Google is reached through the endpoint Chrome's built-in page translation uses
  (`translate-pa.googleapis.com/v1/translateHtml` with Chrome's public key), which takes the
  whole screen in one request. The plain `translate_a/single?client=gtx` endpoint answers this
  network with "unusual traffic" pages.
- Only the recognized text is sent, never the screenshot.
- If Google fails (offline, blocked), lens falls back to Apple's on-device Translation framework,
  which streams results nearest the pointer first at about 0.7 s per sentence.
  `LENS_ENGINE=apple` uses only that.
- Translations are cached, so after scrolling, text you already saw comes back instantly.
- Lines that are already English are left alone.

Overlay keys: **Esc**, a click, a scroll or the hotkey again dismisses it. Hold **Option** to see
the original. **Cmd-C** copies the whole translation.

## Install

```sh
./lens setup        # builds .build/Lens.app, loads launchd agent com.anurag.lens,
                    # links ~/.local/bin/lens
```

Then allow **Lens** in System Settings > Privacy & Security under **Screen & System Audio
Recording** (to read the screen) and **Input Monitoring** (to see the double-tap; the event tap is
listen-only and looks only at modifier presses). The app is ad-hoc signed, so a rebuild
invalidates both grants; `lens setup` then resets them with `tccutil` so macOS asks again.

For the on-device fallback, the language pair must be downloaded in System Settings > General >
Language & Region > Translation Languages (Japanese and English already are).

## Usage

```sh
lens                       # show or dismiss the overlay (same as the hotkey)
lens file shot.png --out translated.png   # test on an image without the screen
lens status | logs | uninstall
```

Settings are environment variables read at setup time:

```sh
LENS_HOTKEY=double:rshift LENS_FROM=zh LENS_TO=en LENS_ENGINE=apple lens setup
```

`LENS_HOTKEY` is either a double-tapped modifier, `double:` plus `rcmd` (default), `lcmd`,
`rshift`, `lshift`, `ropt`, `lopt`, `rctrl` or `lctrl`, or a chord such as `ctrl+opt+t`
(`ctrl`, `opt`, `cmd`, `shift` plus a letter, digit, `space` or `f1` to `f12`), which needs no
Input Monitoring. A tap counts only if the key is released within 0.35 s with no other key
pressed in between, and the second tap must follow within 0.35 s, so right-⌘ shortcuts never
trigger it.

## How it works

`lens.swift` is a single AppKit file, built with `swiftc` into an `LSUIElement` app bundle.

1. ScreenCaptureKit captures the display under the pointer at full resolution.
2. `VNRecognizeTextRequest` (accurate, ja + en) returns text lines with bounding boxes.
3. Lines are grouped into paragraphs: stacked, left-aligned lines of similar height form a
   block, which splits where a line does not reach the block's right edge (it did not wrap),
   ends a sentence, or the next line starts with a bullet. Wrapped Japanese lines are joined
   without spaces so sentences translate whole.
4. Paragraphs without kana or kanji are skipped. A single CJK glyph next to Latin text is
   treated as an OCR misread of an icon or emoji.
5. Google translates all paragraphs in one request (HTML-escaped, since the endpoint takes
   HTML); on failure `TranslationSession(installedSource:target:)` translates on-device.
6. Each block is painted with the median color of a ring around it, and the text color is
   the mean of the pixels inside that differ most from the background. The font starts at 85%
   of the original line height and shrinks to fit; single-line labels may widen up to the next
   text on the same row.

Log: `~/Library/Logs/lens.log`.
