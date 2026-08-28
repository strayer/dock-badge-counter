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
brew install strayer/dock-badge-counter/dock-badge-counter
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
dock-badge-counter watch [--config PATH] [--interval SECONDS] [--on-change CMD] [--heartbeat SECONDS] [--verbose]
```

`watch` polls the Dock (default: once per second, ~1 ms per poll) and reports only **changes**:

- With `on_change` set, the command runs via `/bin/sh -c` with these environment variables:

  | Variable              | Content                                                                 |
  | --------------------- | ----------------------------------------------------------------------- |
  | `DOCK_BADGES`         | full snapshot, e.g. `{"Mail":"3","Slack":"12"}`                        |
  | `DOCK_BADGES_CHANGED` | only apps whose badge changed; a removed badge is reported as `""`      |
  | `DOCK_BADGES_REASON`  | `start`, `change` or `heartbeat`                                        |

- Without `on_change`, every snapshot is printed to stdout as one JSON line, so you can pipe it into anything:

  ```bash
  dock-badge-counter watch | jq -c 'to_entries | map("\(.key): \(.value)")'
  ```

Polling pauses while the Mac sleeps or the screen is locked, and resumes with an immediate poll.

#### Configuration

Settings are read from `$XDG_CONFIG_HOME/dock-badge-counter/config.toml` (default `~/.config/dock-badge-counter/config.toml`); command-line options override the file. All keys are optional — see [`examples/config.toml`](examples/config.toml) for the full list with defaults:

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

### SketchyBar example

[`examples/sketchybar/`](examples/sketchybar/) contains a config and handlers for both the Lua (SbarLua) and shell flavours of SketchyBar. The flow is:

```
dock-badge-counter watch ──(on change: sketchybar --trigger dock_badges BADGES=…)──▶ SketchyBar ──▶ your handler
```

SketchyBar never polls or spawns anything itself; it only receives an event when a badge actually changes. With SbarLua the `BADGES` JSON arrives as a ready-to-use Lua table.

## Accessibility permission

The Accessibility API requires the *calling process* to be trusted in **System Settings > Privacy & Security > Accessibility**. A prompt is shown on first use.

- **One-shot use from a terminal:** the permission is attributed to your terminal app (Terminal, iTerm2, Ghostty, …).
- **Watch mode as a service:** the permission is attributed to the `dock-badge-counter` binary itself. If no prompt appears, add it manually with the **+** button (⌘⇧G to enter the path, e.g. `/opt/homebrew/opt/dock-badge-counter/bin/dock-badge-counter`). Until granted, the watcher waits and retries every 5 seconds.

Note that macOS ties the grant to the binary's code signature. Homebrew builds are ad-hoc signed, so **after a `brew upgrade` the permission has to be granted again**. If you build from source and want a grant that survives rebuilds, sign the binary with a stable identity (e.g. a self-signed code-signing certificate): `codesign --force --sign "<cert>" --identifier com.example.dock-badge-counter .build/release/dock-badge-counter`.

## How it works

The Dock exposes its icons through the Accessibility API; each icon's `AXStatusLabel` attribute is the badge text. The Dock does not send accessibility notifications when a badge changes, so watch mode polls — a full walk of ~20 icons takes about a millisecond and costs the Dock ~0.02 ms of CPU, which is negligible even at 1 Hz. Only diffs cross the process boundary.

## License

MIT
