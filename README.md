# dock-badge-counter

`dock-badge-counter` is a macOS command-line tool that reads notification badge counts from Dock applications using the Accessibility API. It outputs the data as JSON for easy integration with other tools.

## Requirements

- macOS 13.0 or later

## Installation

### Using Homebrew (Recommended)

You can install `dock-badge-counter` using Homebrew from this repository's tap:

```bash
brew install strayer/dock-badge-counter/dock-badge-counter
```

To update to the latest version:

```bash
brew upgrade strayer/dock-badge-counter/dock-badge-counter
```

### Building from Source

You can also build the tool from the source using the Swift Package Manager.

```bash
# Build debug version
swift build

# Build optimized release version
swift build -c release
```

The compiled binary will be located in `.build/arm64-apple-macosx/release/dock-badge-counter`.

## Usage

### Permissions

This tool uses the macOS Accessibility API to read information from the Dock. You must grant accessibility permissions for your terminal application (e.g., Terminal.app, iTerm2.app) in **System Settings > Privacy & Security > Accessibility**.

The tool will prompt you for permissions the first time you run it.

### Running

If installed via Homebrew:

```bash
dock-badge-counter
```

If building from source:

```bash
swift run dock-badge-counter
# or run the compiled binary directly
.build/arm64-apple-macosx/release/dock-badge-counter
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

### Homebrew Tap

This repository also serves as a Homebrew tap. The formula is automatically updated when you create a new release:

1. Create a release on GitHub with a semantic version tag (e.g., `v1.0.0`)
2. GitHub Actions will automatically update `Formula/dock-badge-counter.rb` with the correct URL and SHA256
3. Users can then install with: `brew install strayer/dock-badge-counter/dock-badge-counter`

#### Manual Formula Update (if needed)

If you need to update the formula manually:

```bash
# Calculate SHA256 of the release
curl -L https://github.com/strayer/dock-badge-counter/archive/v1.0.0.tar.gz -o v1.0.0.tar.gz
shasum -a 256 v1.0.0.tar.gz

# Update Formula/dock-badge-counter.rb with the URL and SHA256
```
