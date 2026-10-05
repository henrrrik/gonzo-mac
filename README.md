# Gonzo

A native macOS Markdown writing app, inspired by [Omawrite](https://github.com/omacom/omawrite). Named in homage to Hunter S. Thompson and gonzo journalism: get out of the way and let the story happen.

Gonzo uses Swift, AppKit and the system text engine. It has no package dependencies, embedded browser, background service or network access. Requires macOS 27 or later and Swift 6.4 (Xcode 27) to build. CI uses GitHub’s `xcode-27` runner with Xcode 27.0 explicitly selected.

## Build and run

```sh
make build
open build/Gonzo.app
# Optional: install in /Applications
make install
# Optional: package build/Gonzo-<version>.dmg for distribution
make dmg
```

The release app is built for the host architecture, signed locally, and uses App Sandbox and Hardened Runtime. It can read and write files you select; it has no network entitlement. Copy it to Applications if desired. Distribution to other Macs requires Developer ID signing and notarization; set `GONZO_SIGNING_IDENTITY` to choose a signing identity. `make debug` builds a development app; `make test` runs the tests.

Builds and installations stage and verify a new bundle before replacing the old one. Previous bundles remain in hidden staging folders so running instances keep their original executable; later runs remove them once nothing can still be running them. Restart Gonzo to use an update.

`make dmg` packages the verified app with an Applications shortcut, mounts the image to check the packaged app's signature, Hardened Runtime and entitlements, and prints its SHA-256. The image is unsigned and the app is not notarized, so when a browser or AirDrop marks the download as quarantined, Gatekeeper blocks the app on other Macs; recipients should compare the image's SHA-256 with one received over a trusted channel before running `xattr -dr com.apple.quarantine /Applications/Gonzo.app` after copying the app.

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

The editor keeps one authoritative text storage. A block index maintains word counts and paragraph boundaries; small edits rebuild at most the neighboring 1,024-unit blocks, even inside a long paragraph or unbroken word. Syntax styling is paragraph-local, caches up to 256 paragraphs, and changes attributes only when needed. Edits, pastes and text size changes style only paragraphs in view; the rest are styled as they scroll into view. Attribute fixing, such as font fallback for scripts and emoji the editor font lacks, is deferred to the paragraphs that are read rather than run across the whole document; forward traversals fix growing windows. AppKit inserts attribute runs ahead of all later runs, so in large documents with much fallback text, scrolling upward through unread text or traversing it after viewing scattered parts can cost more than fixing everything up front. Oversized paragraphs stay plain across edits without repeated scans. TextKit uses noncontiguous layout to avoid eagerly laying out the entire document. Patterns are compiled once; no whole-document Markdown render runs while typing.

Opening prepares UTF-8 text and its index on AppKit’s opening queue before installing them on the main thread. Saving captures an immutable text value, then serializes, checks conflicts and writes on AppKit’s save worker. The saved bytes also supply the conflict digest. Closing clears undo and detaches text layout from the storage so native view caches do not retain the document. Installing the opened text, snapshot capture, saving, printing and a full native find operation can still do work proportional to file size. Native layout and font fallback of unusually long paragraphs can also remain expensive, including after text size changes and Revert. Paragraphs longer than 4,096 UTF-16 characters remain plain text to bound syntax styling work. TextKit reads use a cached string snapshot that is invalidated by text edits, avoiding repeated full-text bridging during layout. Memory includes the source, cached snapshot, block index, native text layout, style runs and undo history. The document size limit bounds source size, but there is no hard process-memory ceiling.

Run the repeatable storage benchmark with:

```sh
swift test -c release --filter largeDocumentEditingBenchmark
```

For opt-in release benchmarks covering different file sizes, huge paragraphs, native edits, resizing, safe saves and repeated window lifetimes, run:

```sh
GONZO_PERFORMANCE_TESTS=1 swift test -c release --filter PerformanceTests
```

The storage benchmark measures 1,000 insert/delete operations in a 5.16 MB fixture; it does not measure end-to-end keyboard latency, rendering, disk I/O or autosave. Measure process memory on a release app with Activity Monitor or `footprint`; debug builds and RSS are not a reliable substitute for physical footprint.

## Scope

This is a native reinterpretation of Omawrite, retaining its small writing-focused feature set. Gonzo uses macOS fonts, scrolling, file dialogs and document lifecycle. It keeps Markdown markers visible instead of collapsing them. Syntax styling is intentionally lightweight rather than a full CommonMark parser; multiline fenced-code styling and fence-aware Return are not implemented. Printing outputs Markdown source rather than rendered HTML.

Omawrite was reviewed at commit `8f98892b26768236b2c20f4e637cf4b102d898bf`. Its MIT copyright notice is retained in [LICENSE](LICENSE). No iA Writer font files are bundled.
