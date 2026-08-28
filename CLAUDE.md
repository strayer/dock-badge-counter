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

# Run tests (wrapper around `swift test`, see note in Architecture about DEVELOPER_DIR)
./scripts/test.sh

# Format code
swift format --in-place --recursive Sources Tests
```

## Pre-commit hooks and CI

This project uses [prek](https://github.com/j178/prek) to run pre-commit hooks. Hooks are defined in `.pre-commit-config.yaml` as `repo: local` system hooks:

1. **swift format** — auto-formats staged `.swift` files in-place. May modify files during commit.
2. **swift format lint** — `swift format lint --strict`; fails the commit on any lint finding.
3. **swift test** — runs `./scripts/test.sh`. Fails the commit on test failures.

If a commit fails due to reformatting, re-stage the changes and commit again.

`.github/workflows/ci.yaml` runs format lint, `swift build -c release` and `swift test` on `macos-latest` for every PR and push to `main`. `renovate.json5` groups Swift package and GitHub Actions updates (action digests are pinned).

## Architecture

```
Sources/
├── Commands/
│   ├── DockBadgeCounter.swift  # @main, ArgumentParser root (default subcommand: read)
│   ├── Read.swift              # one-shot JSON output
│   └── Watch.swift             # CLI options → WatchConfig → Watcher
├── BadgeReader.swift           # AX walk of the Dock; BadgeSnapshot = [String: String]; JSON helper
├── ChildProcess.swift          # posix_spawn'd `/bin/sh -c` child in its own process group, reaped via DispatchSource
├── Config.swift                # WatchConfig (strict TOML via TOMLKit, Codable, all keys optional, validation)
├── Delivery.swift              # pure logic: FireReason, Delivery (diff/merge), PauseState, monotonic clock
└── Watcher.swift               # @MainActor timer loop, permission retry, pause handling, CommandRunner, Logger
Tests/                          # Swift Testing: Delivery/PauseState, WatchConfig/CLI merge, ChildProcess,
                                #   CommandRunner (real processes), Watcher state machine (injected seams)
examples/                       # config.toml with defaults; sketchybar/ (Lua + shell handlers)
Formula/                        # Homebrew formula incl. `service` block (brew services → `watch`)
```

Key facts:

- The Dock emits **no** accessibility notifications for badge changes; polling is the only option. A full poll is ~1 ms, so `watch` polls on a `DispatchSourceTimer` with 20% leeway and only forwards diffs.
- `watch` delivers `DOCK_BADGES` (full snapshot), `DOCK_BADGES_CHANGED` (diff since last delivery, removed = "") and `DOCK_BADGES_REASON` (start|change|heartbeat) to `/bin/sh -c <on_change>`. `CommandRunner` runs one command at a time and coalesces newer deliveries into a single pending one (`Delivery.merged`); `command_timeout` kills the whole process group (SIGTERM, then SIGKILL after 2 s). Without `on_change` it prints NDJSON to stdout.
- `BadgeReader.read()` either returns a snapshot built only from successful AX replies or throws; transient AX errors keep the previous snapshot so the Dock restarting never produces false removals. Only `AXApplicationDockItem` items count. `apiDisabled` maps to permission-denied, which drops the watcher back into its 5 s permission-retry loop.
- Pause handling is a set of reasons (`sleep`, `screenLocked`); polling resumes only when the set is empty. Initial lock state comes from `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`.
- Config precedence: defaults < TOML file (`$XDG_CONFIG_HOME/dock-badge-counter/config.toml`, relative XDG ignored) < CLI flags (`--no-*` inversions and `--stdout` can override file values). TOML decoding is strict (unknown keys are errors); integers and floats are both accepted for numeric keys. Validation: interval 0.1…86400, heartbeat/command_timeout 0…86400, all finite.
- Everything in `Watcher`/`CommandRunner`/`ChildProcess` is `@MainActor`; Dispatch and notification callbacks enter it with `MainActor.assumeIsolated`.
- `Watcher` has two initializers: `init(config:)` wires the real AX reader, monotonic clock, permission check and runner/stdout sink; the designated `init(config:readSnapshot:now:isTrusted:sink:)` is what tests use to drive `tick()`/`poll()`/`handlePause` directly with scripted reads and a manual clock. Keep OS glue (timer, run loop, signal sources, notification observers, `CGSession`) out of the tested path; it is verified manually.
- Tests use Swift Testing. The Command Line Tools toolchain lacks the `TestingMacros` plugin, so `swift test` fails when only CLT is selected; `./scripts/test.sh` sets `DEVELOPER_DIR` to an installed `Xcode.app`/`Xcode-beta.app` automatically.
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