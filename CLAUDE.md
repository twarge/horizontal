# Horizontal

A PCB design app for macOS and iPadOS that reads and writes Horizon EDA
projects. Swift 6, SwiftUI and Metal; C++ for STEP import (OpenCascade) and
plane clipping (Clipper, earcut); a Python package and MCP server in `python/`.

## Build and test

`make help` lists every target. The ones that matter:

- `make` builds the app through `xcodebuild`; `make test` runs the package's
  three XCTest bundles through `swift test`; `make lint` takes seconds.
- `make native python-test` builds the release dylib and CLI and runs the
  Python tests against them.
- Everything links OpenCascade, built once by `make deps` (tens of minutes;
  needs `cmake` and `ninja`). Without `Vendor/OpenCascadeStatic` nothing
  builds, `swift test` included.
- One test: `swift test --filter HorizontalNativeTests.SomeTests/testName`.

Tests that need something a machine may lack skip themselves: a Metal device,
or a path in `HORIZONTAL_REAL_BOARD_FOLDER`, `HORIZONTAL_GOLDEN_BOARD`,
`HORIZON_POOL`, `HORIZONTAL_POOLS`; `HORIZONTAL_NETWORK_TESTS` and
`HORIZONTAL_SPEECH_TESTS` turn on the ones that reach outside.

## Layout

- `Sources/HorizontalNative` is the app and the model, compiled twice: by
  `Horizontal.xcodeproj` (a synchronized folder, so a new or moved file needs
  no project edit) and as the package target the tests, CLI and dylib link.
  `HorizontalNativeApp.swift` is the Xcode target's alone.
  - `Model/` by subject: `Board`, `Schematic`, `Routing`, `Planes`,
    `Geometry`, `Blocks`, `Pool`, `Project`, `Export`, `Git`.
  - `Views/` is SwiftUI and Metal; `Dispatch/` is the JSON-RPC layer every
    headless front end and the live channel share (`docs/automation.md`).
- `Sources/HorizontalProjectIO` reads and writes project files and knows
  nothing of the model.
- `python/` is the bindings, the MCP server and the plugin both Codex and
  Claude Code install; `python/bin/horizontal-mcp` starts the server.

## Conventions

- No `try!` or `fatalError` in `Sources/` (`make lint`). A `try?` is for a
  probe or a cleanup, never for a save, a write or an export whose failure the
  user should hear of.
- A type marked `@unchecked Sendable`, or a `nonisolated(unsafe)` variable,
  says beside it what makes it safe: the lock, or the one thread.
- Platform differences go behind `#if os(...)`; `make ios` checks the other
  side compiles.
- Horizon's files round-trip: keys the app doesn't know are kept, and files
  are written as Horizon writes them.
- New code goes in a new file sooner than into `BoardCanvasView.swift` or
  `SchematicCanvasView.swift`, which are far too long already.
- Test files are named for the behaviour they cover, not for the session or
  board that found the bug.
- Commit messages: a subject line of about seventy characters, a blank line,
  then the body. The body says what changed for the user and why.
- A release bumps the Python version in four places together
  (`docs/claude-code.md`, "Updating"); the app's version is the git tag.
