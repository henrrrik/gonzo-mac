# Gonzo

A native macOS Markdown writing app, inspired by [Omawrite](https://github.com/omacom/omawrite) and named for Hunter S. Thompson's gonzo journalism: get out of the way and let the story happen.

Swift and AppKit, no dependencies, no network access. Requires macOS 27; building needs Swift 6.4 (Xcode 27).

## Install

Download the `.dmg` from [Releases](https://github.com/henrrrik/gonzo-mac/releases) and drag Gonzo to Applications. Releases are not notarized, so macOS blocks the first launch. If you trust the download (compare its SHA-256 with the release notes), run:

```sh
xattr -dr com.apple.quarantine /Applications/Gonzo.app
```

## Build

```sh
make build      # build/Gonzo.app
make install    # copy to /Applications
make dmg        # build/Gonzo-<version>.dmg
make test       # run the tests
```

The app is signed locally (set `GONZO_SIGNING_IDENTITY` to choose an identity) and runs with App Sandbox and Hardened Runtime. Installs keep the previous bundle until no running copy needs it; restart Gonzo to use an update.

## Features

- Opens and saves UTF-8 `.md`, `.markdown`, `.mdown` and plain text files, up to 16 MB.
- Styles headings, emphasis, quotes, links and inline code while keeping Markdown syntax visible.
- Centered writing column, light and dark appearance, live word count.
- Find and replace, undo, printing, recent documents and multiple windows.
- Autosave and draft recovery. Saving never overwrites changes made by another app; use Save As or Revert to Saved.

Return continues lists and quotes, and exits an empty list item. Shift-Return inserts a single line break. Pasting a URL over selected text makes a link.

| Shortcut | Action |
| --- | --- |
| ⌘N / ⌘O | New / Open |
| ⌘S / ⇧⌘S | Save / Save As |
| ⌘F / ⌥⌘F | Find / Find and Replace |
| ⌘B / ⌘I / ⌘K | Bold / Italic / Link |
| ⌘+ / ⌘− / ⌘0 | Text size |
| ⌃⌘F | Full screen |

## Performance

Gonzo stays responsive on large documents: edits update word counts and styling locally, only visible paragraphs are styled, and font fallback for scripts and emoji happens as text comes into view. Very long single paragraphs remain slow to lay out. Benchmarks:

```sh
GONZO_PERFORMANCE_TESTS=1 swift test -c release --filter PerformanceTests
```

## Scope

Syntax styling is deliberately lightweight, not a full CommonMark parser; fenced code blocks are not styled. Printing outputs the Markdown source.

Omawrite was reviewed at commit `8f98892b26768236b2c20f4e637cf4b102d898bf`; its MIT notice is kept in [LICENSE](LICENSE).
