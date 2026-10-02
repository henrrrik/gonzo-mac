# Gonzo

A native macOS Markdown writing app, inspired by [Omawrite](https://github.com/omacom/omawrite). Named in homage to Hunter S. Thompson and gonzo journalism: get out of the way and let the story happen.

Gonzo uses Swift, AppKit and the system text engine. It has no package dependencies, embedded browser, background service or network access. Requires macOS 14 or later and a Swift 6 toolchain to build.

## Build and run

```sh
make build
open build/Gonzo.app
# Optional: install in /Applications
make install
```

The release app is built for the host architecture, signed locally, and uses App Sandbox and Hardened Runtime. It can read and write files you select; it has no network entitlement. Copy it to Applications if desired. Distribution to other Macs requires Developer ID signing and notarization; set `GONZO_SIGNING_IDENTITY` to choose a signing identity. `make debug` builds a development app; `make test` runs the tests.

Builds and installations stage and verify a new bundle before replacing the old one. Previous bundles remain in hidden staging folders so running instances keep their original executable. Restart Gonzo to use an update; remove these folders only after those instances have exited.

## Writing

- Open and save UTF-8 `.md`, `.markdown`, `.mdown` and plain text files.
- Documents are limited to 16 MB of UTF-8 text, including pasted edits. Oversized files are rejected before loading into the editor.
- Markdown headings use graduated sizes and spacing across all six levels; emphasis, quotes, links and inline code are styled in the editor. Syntax stays visible and editable.
- The writing column is centered and follows system light/dark appearance.
- A live word count ignores tokens made entirely of punctuation or Markdown markers.
- Native find and replace, undo/redo, printing, recent documents and multiple windows.
- macOS autosave, draft recovery and coordinated document handling. Named files autosave in place; use Revert to Saved and macOS document versions to recover earlier content. Autosave runs after a delay, so the last few seconds of edits may be lost in a crash.
- Saving refuses to overwrite external changes. Use Save As to keep your edits separately, or Revert to Saved to load the other version.

| Shortcut | Action |
| --- | --- |
| ⌘N / ⌘O | New / Open |
| ⌘S / ⇧⌘S | Save / Save As |
| ⌘Z / ⇧⌘Z | Undo / Redo |
| ⌘F / ⌥⌘F | Find / Find and Replace |
| ⌘G / ⇧⌘G | Next / Previous match |
| ⌘B / ⌘I / ⌘K | Bold / Italic / Link |
| ⌘P | Print |
| ⌘+ / ⌘− / ⌘0 | Increase / Decrease / Reset text size |
| ⌃⌘F | Full screen |

Return inserts a paragraph break and continues lists or blockquotes. Return on an empty list item exits the list. Shift-Return inserts a single newline. Pasting a URL over selected text creates a Markdown link. Smart quotes, autocorrection and rich text paste are disabled to keep Markdown predictable; system spelling commands remain available.

## Performance design

The editor keeps one authoritative text storage. Word counts rescan only paragraphs intersecting an edit, including joined paragraphs after newline deletion. Syntax styling is paragraph-local and applied to visible text and edited paragraphs. TextKit uses noncontiguous layout to avoid eagerly laying out the entire document. Patterns are compiled once; no whole-document Markdown render runs while typing.

Opening, saving, printing, changing font size and a full native find operation can still do work proportional to file size. Paragraphs longer than 4,096 UTF-16 characters remain plain text to bound syntax styling work. Memory includes the source text, native text layout, style runs and the native undo history. The document size limit bounds source size, but there is no hard process-memory ceiling.

Run the repeatable storage benchmark with:

```sh
swift test -c release --filter largeDocumentEditingBenchmark
```

This measures 1,000 insert/delete operations in a 5.16 MB fixture; it does not measure end-to-end keyboard latency, rendering, disk I/O or autosave. Measure process memory on a release app with Activity Monitor or `footprint`; debug builds and RSS are not a reliable substitute for physical footprint.

## Scope

This is a native reinterpretation of Omawrite, retaining its small writing-focused feature set. Gonzo uses macOS fonts, scrolling, file dialogs and document lifecycle. It keeps Markdown markers visible instead of collapsing them. Syntax styling is intentionally lightweight rather than a full CommonMark parser; multiline fenced-code styling and fence-aware Return are not implemented. Printing outputs Markdown source rather than rendered HTML.

Omawrite was reviewed at commit `8f98892b26768236b2c20f4e637cf4b102d898bf`. Its MIT copyright notice is retained in [LICENSE](LICENSE). No iA Writer font files are bundled.
