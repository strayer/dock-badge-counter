# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

dock-badge-counter is a macOS command-line tool that reads notification badge counts from Dock applications using the Accessibility API. It outputs the data as JSON for easy integration with other tools.

## Development Commands

```bash
# Build debug version
swift build

# Build optimized release version
swift build -c release

# Run the tool
swift run dock-badge-counter [--include-empty]

# Format code
swift format
```

## Architecture

The entire application is contained in `Sources/main.swift` with the following structure:

1. **DockBadgeCounter struct**: Core logic encapsulated in a single struct
   - `run()`: Main entry point that orchestrates the workflow
   - Private methods handle each step (permissions, finding Dock, parsing badges)
   - Custom `DockBadgeError` enum for comprehensive error handling

2. **Key Implementation Details**:
   - Uses AXUIElement API to traverse Dock UI hierarchy
   - Requires Accessibility permissions (prompts user if not granted)
   - Outputs JSON to stdout, errors to stderr
   - Exit codes: 0 (success), 1 (errors), 2 (invalid arguments)

3. **Command-line Arguments**:
   - `--help`: Display usage information
   - `--include-empty`: Include apps without badges in output

## Important Considerations

- **Platform**: macOS 13+ only (uses macOS-specific Accessibility APIs)
- **Permissions**: Requires Accessibility permissions in System Settings
- **No External Dependencies**: Uses only system frameworks (AppKit, Foundation)
- **Build Artifacts**: Located in `.build/arm64-apple-macosx/[debug|release]/`

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
4. The tool should maintain its single-file simplicity unless there's a compelling reason to split it
5. When creating releases, use semantic versioning and let GitHub Actions handle formula updates