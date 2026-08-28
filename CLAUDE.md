# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

dock-badge-counter is a macOS command-line tool that reads notification badge counts from Dock applications using the Accessibility API. It runs once (JSON to stdout) or as a watcher (`watch` subcommand, launchd service via `brew services`) that runs a user command whenever badges change.

## Development Commands

```bash
# Build debug version
swift build

# Build optimized release version
swift build -c release

# Run the tool
swift run dock-badge-counter [--include-empty]          # one-shot
swift run dock-badge-counter watch --verbose            # watcher, NDJSON to stdout
swift run dock-badge-counter watch --config examples/sketchybar/config.toml

# Format code
swift format
```

## Architecture

```
Sources/
├── Commands/
│   ├── DockBadgeCounter.swift  # @main, ArgumentParser root (default subcommand: read)
│   ├── Read.swift              # one-shot JSON output
│   └── Watch.swift             # CLI options → WatchConfig → Watcher
├── BadgeReader.swift           # AX walk of the Dock; BadgeSnapshot = [String: String]; JSON helper
├── Config.swift                # WatchConfig (TOML via TOMLKit, Codable, all keys optional)
└── Watcher.swift               # timer loop, diff, on_change command / NDJSON, sleep-lock pause, Logger
examples/                       # config.toml with defaults; sketchybar/ (Lua + shell handlers)
Formula/                        # Homebrew formula incl. `service` block (brew services → `watch`)
```

Key facts:

- The Dock emits **no** accessibility notifications for badge changes; polling is the only option. A full poll is ~1 ms, so `watch` polls on a `DispatchSourceTimer` with 20% leeway and only forwards diffs.
- `watch` delivers `DOCK_BADGES` (full snapshot), `DOCK_BADGES_CHANGED` (diff, removed = "") and `DOCK_BADGES_REASON` (start|change|heartbeat) to `/bin/sh -c <on_change>`, run on a serial queue so commands never overlap. Without `on_change` it prints NDJSON to stdout.
- Config precedence: defaults < TOML file (`$XDG_CONFIG_HOME/dock-badge-counter/config.toml`) < CLI flags. TOML integers and floats are both accepted for numeric keys.
- Accessibility (TCC) is attributed to the *responsible process*: the terminal for one-shot use, the binary itself under launchd. Grants are tied to the code signature; ad-hoc builds lose the grant on every rebuild.
- Dependencies: swift-argument-parser, TOMLKit. Everything else is system frameworks (AppKit, ApplicationServices).
- Exit codes: 0 success, 1 error (incl. config errors), 64 usage errors (ArgumentParser).

## Homebrew Tap

This repository also functions as a Homebrew tap. Key files:

- **Formula/dock-badge-counter.rb**: Homebrew formula for installation
- **.github/workflows/update-formula.yml**: Automated formula updates on releases

### Release Process

1. Create a GitHub release with semantic version tag (e.g., `v1.0.0`)
2. GitHub Actions automatically updates the formula with correct SHA256
3. Users can install with: `brew install strayer/dock-badge-counter/dock-badge-counter`

### Formula Maintenance

- The formula builds using `swift build --configuration release --disable-sandbox`
- Requires Xcode 15.0+ and macOS
- Updates are automated but can be done manually if needed

## Common Tasks

When making changes:
1. The code follows Swift conventions with proper error handling and separation of concerns
2. All magic strings are defined as constants at the top of the file
3. Errors are output to stderr with descriptive messages
4. Keep the file split above; new subcommands go into `Sources/Commands/`
5. When creating releases, use semantic versioning and let GitHub Actions handle formula updates