import ArgumentParser
import Foundation

// Bumped by scripts/release.sh; must match the release tag (release.yml verifies it).
let version = "2.0.0"

@main
struct DockBadgeCounter: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "dock-badge-counter",
    abstract: "Read notification badge counts from macOS Dock applications.",
    discussion: """
      Requires Accessibility permission (System Settings > Privacy & Security > Accessibility) \
      for the process that runs it: your terminal for one-shot use, the binary itself when run as \
      a launchd agent.
      """,
    version: version,
    subcommands: [Read.self, Watch.self],
    defaultSubcommand: Read.self
  )
}
