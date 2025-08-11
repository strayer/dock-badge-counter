# dock-badge-counter

`dock-badge-counter` is a macOS command-line tool that reads notification badge counts from Dock applications using the Accessibility API. It outputs the data as JSON for easy integration with other tools.

## Requirements

- macOS 13.0 or later

## Installation and Usage

### Permissions

This tool uses the macOS Accessibility API to read information from the Dock. You must grant accessibility permissions for your terminal application (e.g., Terminal.app, iTerm2.app) in **System Settings > Privacy & Security > Accessibility**.

The tool will prompt you for permissions the first time you run it.

### Building

You can build the tool from the source using the Swift Package Manager.

```bash
# Build debug version
swift build

# Build optimized release version
swift build -c release
```

The compiled binary will be located in `.build/arm64-apple-macosx/release/dock-badge-counter`.

### Running

To run the tool directly:

```bash
swift run dock-badge-counter
```

#### Options

- `--include-empty`: Include applications that do not have a notification badge in the output.
- `--help`: Show usage information.

## Output

The tool outputs a JSON object to standard output. The keys are the application names, and the values are the badge counts as strings.

### Example Output

```json
{
  "Slack": "12",
  "Discord": "3",
  "Things": "1"
}
```

### Example with `--include-empty`

```json
{
  "Slack": "12",
  "Discord": "3",
  "Things": "1",
  "Safari": "",
  "Notes": ""
}
```

## Development

The application is a single Swift file located in `Sources/main.swift`.

To format the code, use:

```bash
swift format
```
