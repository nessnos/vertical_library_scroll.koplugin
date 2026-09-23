# Vertical Library Scroll: a KOReader plugin

Turn KOReader's file browser ("the library") into a Kindle-style,
vertically-paged screen instead of the stock horizontal swipe/arrows one.

- **Swipe up** → next page, **swipe down** → previous page, instead of
  swipe left/right.
- A **vertical scrollbar** on the right edge of the screen shows your
  position in the library; tap or drag it to jump straight to a page.
- An **up-arrow** above the scrollbar and a **down-arrow** below it do
  the same thing as swiping up/down.
- The book grid/list is narrowed to make real room for the scrollbar.

Off by default. It's a toggle, not a takeover: turn it on from **File
browser → Settings → "Vertical scrolling library"**, and your file
browser looks and behaves exactly as before until you do.

![Vertical scrolling library screenshot](imgs/screenshot1.png)

Note: in the screenshot the up/down arrow buttons show up as little stars, that's just the icon pack I have installed, not how they normally look.

## Requirements

- [KOReader](https://github.com/koreader/koreader), reasonably recent
  (developed and tested against current `master`).
- A touch device. This plugin is gesture/touch-driven; it doesn't add
  key-based bindings for button-only devices.

## Installation

1. Download this repository.
2. Copy the whole `vertical_library_scroll.koplugin/` **folder** into KOReader's `plugins/` directory:

   ```
   koreader/plugins/vertical_library_scroll.koplugin/
   ├── _meta.lua
   └── main.lua
   ```

3. Restart KOReader (a full restart). It's enabled by
   default like any new plugin; you can confirm KOReader found it under
   **Tools → More tools → Plugin management** ("Vertical scrolling
   library").
4. Turn the feature on: open the file browser, open the top menu, go to
   the first tab (file-browser icon), then **Settings**. **"Vertical
   scrolling library"** is the last item in that list — tap it to
   enable and rebuild the screen immediately.

## Compatibility with SimpleUI

This plugin was built and is regularly checked against
[SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin), but
doesn't require it:

- It only patches KOReader's *core* file browser classes (`FileChooser`,
  `Menu`, `FileManager`), the same screen SimpleUI's own
  folder-browsing entry points lead to, since SimpleUI patches those
  same core classes rather than replacing them.
- Every hook is installed as a **wrap**: it saves whatever function was
  already there (stock KOReader's, SimpleUI's, or CoverBrowser's) and
  calls through to it. Load order between this plugin and SimpleUI
  doesn't matter.
- The settings entry is added through KOReader's official
  `FileManagerMenu:registerToMainMenu()` / `addToMainMenu()` extension
  point — the same one the stock CoverBrowser plugin uses — so it
  coexists with other plugins' menu entries by construction.
- **Not covered**: SimpleUI's own home-screen "Flat Library" grid (a
  separate, independent rendering engine with its own pagination). This
  plugin only affects the full-screen file/library browser itself.

## Uninstalling / disabling

- Turn the feature off without removing the plugin: **File browser →
  Settings → "Vertical scrolling library"** again, or disable it from
  **Tools → More tools → Plugin management**.
- Remove it entirely: delete the
  `koreader/plugins/vertical_library_scroll.koplugin/` folder and
  restart KOReader.

## How it works

A few notes for anyone reading the source or filing an issue:

- All patching happens once, at plugin-load time, by wrapping four
  things: `FileChooser:init()` (builds the overlay and reserves its
  layout width), `Menu:updatePageInfo()` (keeps the scrollbar/arrows in
  sync on every page change), `FileManager:onSwipeFM()` and
  `FileManager:initGesListener()` (make vertical swipes turn pages).
  Every wrap calls through to whatever was previously installed, so
  it layers on top of other plugins instead of fighting them for
  control.
- The scrollbar's reserved width is measured once from the actual
  overlay widgets (buttons + scrollbar), then subtracted from the item
  grid's available width via an instance-level override of
  `_recalculateDimen()` — so Mosaic, List, and classic display modes
  all get a real gutter, not just an overlay painted on top.
- Everything is `pcall`-guarded: if a future KOReader update
  renames/removes something this depends on, it logs a warning and
  leaves the feature off rather than breaking your file browser.

## Known limitations

- Only the file browser/library screen is affected — physical page-turn
  buttons and gestures elsewhere in KOReader are untouched.
- In a right-to-left UI language, the scrollbar automatically moves to
  the left edge, matching KOReader's own mirrored-layout conventions.
- The reserved gutter width and scrollbar thickness are currently fixed
  constants, not user-configurable settings. Open an issue if you'd
  like that exposed.

## Contributing

Issues and pull requests are welcome. If you're filing a bug, please
include your KOReader version, device, and whether SimpleUI (or any
other file-browser-patching plugin) is installed — most of this
plugin's tricky edge cases come from how it interacts with other
patches to the same core classes.

## License

[MIT](LICENSE)
