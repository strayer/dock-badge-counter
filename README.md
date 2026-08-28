# dock-badge-counter

`dock-badge-counter` reads the notification badges of the apps in your macOS Dock (the red counters like `12` or `99+`) using the Accessibility API.

It can run **once** and print the badges as JSON, or **watch** the Dock as a background service and run a command of your choice whenever a badge changes — for example to show unread counts in a status bar like [SketchyBar](https://github.com/FelixKratz/SketchyBar).

```
$ dock-badge-counter
{"Mail":"3","Slack":"12"}
```

## Requirements

- macOS 13.0 or later
- Accessibility permission (see below)

## Installation

```bash
brew install strayer/tap/dock-badge-counter
```

Or build from source (requires Xcode 15+):

```bash
swift build -c release
# binary: .build/release/dock-badge-counter
```

## Usage

### One-shot

```bash
dock-badge-counter                  # apps with a badge
dock-badge-counter --include-empty  # all Dock apps, "" for no badge
```

Output is a JSON object of app name → badge text on stdout. Badge values are strings, since apps also use non-numeric badges like `•` or `99+`. Errors are written to stderr as `{"error": "..."}` with exit code 1.

### Watch mode

```bash
dock-badge-counter watch [--config PATH] [--interval SECONDS] [--on-change CMD | --stdout]
                         [--heartbeat SECONDS] [--command-timeout SECONDS] [--verbose]
```

`watch` polls the Dock (default: once per second) and delivers a snapshot on **start**, on every **change**, and optionally as a periodic **heartbeat**. Every delivery carries the full snapshot plus the diff, so consumers can be stateless.

- With `on_change` set, the command runs via `/bin/sh -c` with these environment variables:

  | Variable              | Content                                                                          |
  | --------------------- | -------------------------------------------------------------------------------- |
  | `DOCK_BADGES`         | full snapshot, e.g. `{"Mail":"3","Slack":"12"}`                                 |
  | `DOCK_BADGES_CHANGED` | apps whose badge changed since the last delivery; a removed badge is reported as `""` |
  | `DOCK_BADGES_REASON`  | `start`, `change` or `heartbeat`                                                 |

  Commands never overlap: while one is running, further changes are coalesced into a single follow-up delivery. A command that runs longer than `command_timeout` (default 30 s) is killed together with everything it spawned.

- Without `on_change` (or with `--stdout`), every snapshot is printed to stdout as one JSON line, so you can pipe it into anything:

  ```bash
  dock-badge-counter watch | jq -c 'to_entries | map("\(.key): \(.value)")'
  ```

Polling pauses while the Mac sleeps or the screen is locked (including when the watcher starts on a locked screen), and resumes with an immediate poll. Transient Accessibility errors — e.g. while the Dock restarts — never produce a snapshot; the last good state is kept until the next successful poll.

#### Configuration

Settings are read from `$XDG_CONFIG_HOME/dock-badge-counter/config.toml` (default `~/.config/dock-badge-counter/config.toml`); command-line options override the file. All keys are optional and unknown keys are rejected — see [`examples/config.toml`](examples/config.toml) for the full list with defaults:

```toml
interval = 1.0
heartbeat = 60
on_change = 'sketchybar --trigger dock_badges BADGES="$DOCK_BADGES"'
```

#### Running as a service

```bash
brew services start dock-badge-counter
```

This registers a launchd user agent running `dock-badge-counter watch`. Logs go to `$(brew --prefix)/var/log/dock-badge-counter.log`. Restart the service after editing the config.

Because `on_change` is executed by a shell, the config file is effectively a script: keep it writable only by your user (the watcher logs a warning otherwise).

### SketchyBar example

[`examples/sketchybar/`](examples/sketchybar/) contains a config and handlers for both the Lua (SbarLua) and shell flavours of SketchyBar. The flow is:

```
dock-badge-counter watch ──(on change: sketchybar --trigger dock_badges BADGES=…)──▶ SketchyBar ──▶ your handler
```

SketchyBar never polls or spawns anything itself; it receives an event on start, on every change, and — with the example config's `heartbeat = 60` — once a minute so a reloaded bar recovers its state. With SbarLua the `BADGES` JSON arrives as a ready-to-use Lua table.

## Accessibility permission

The Accessibility API requires the *calling process* to be trusted in **System Settings > Privacy & Security > Accessibility**. A prompt is shown on first use.

- **One-shot use from a terminal:** the permission is attributed to your terminal app (Terminal, iTerm2, Ghostty, …).
- **Watch mode as a service:** the permission is attributed to the `dock-badge-counter` binary itself. If no prompt appears, add it manually with the **+** button (⌘⇧G to enter the path, e.g. `/opt/homebrew/opt/dock-badge-counter/bin/dock-badge-counter`). Until granted, the watcher waits and retries every 5 seconds.

Note that macOS ties the grant to the binary's code signature. Homebrew builds are ad-hoc signed, so **after a `brew upgrade` the permission has to be granted again**. If you build from source and want a grant that survives rebuilds, sign the binary with a stable identity (e.g. a self-signed code-signing certificate): `codesign --force --sign "<cert>" --identifier com.example.dock-badge-counter .build/release/dock-badge-counter`.

## How it works

The Dock exposes its icons through the Accessibility API; each icon's `AXStatusLabel` attribute is the badge text. Only items with the `AXApplicationDockItem` subrole are considered, so folders, the Trash and minimized windows are ignored. Keys are the Dock's display titles; if two items share a title, the first one wins.

The Dock does not send accessibility notifications when a badge changes, so watch mode polls. On the author's M-series Mac with ~20 Dock icons, a full walk measured about 1 ms wall time and ~0.02 ms of Dock CPU per poll (200 iterations in-process), i.e. a few CPU-seconds per day at 1 Hz. The watcher only *acts* on diffs; nothing is spawned while badges are unchanged (unless a heartbeat is configured).

## Development

This project uses [prek](https://github.com/j178/prek) for pre-commit hooks.

```bash
prek install        # installs pre-commit hooks
swift build
./scripts/test.sh   # `swift test`; picks an installed Xcode.app automatically when only the
                    # Command Line Tools are selected (Swift Testing needs its macro plugin)
swift format --in-place --recursive Sources Tests
```

Pre-commit hooks run automatically on `git commit`:
- **swift format** — auto-formats staged Swift files
- **swift format lint** — fails on remaining lint findings (no auto-fix)
- **swift test** — runs the test suite

CI (`.github/workflows/ci.yaml`) runs the same format lint, a release build and the tests on macOS. Renovate keeps Swift packages and GitHub Actions up to date.

## License

MIT
