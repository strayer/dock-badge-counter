import ArgumentParser
import Foundation

struct Watch: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Poll the Dock and report badge changes.",
    discussion: """
      Settings are read from a TOML config file (default: \
      $XDG_CONFIG_HOME/dock-badge-counter/config.toml); command-line options override it.

      With `on_change` set, the command runs via `/bin/sh -c` with these environment variables:
        DOCK_BADGES          full snapshot as JSON ({"App": "3", ...})
        DOCK_BADGES_CHANGED  only apps whose badge changed; removed badges have value ""
        DOCK_BADGES_REASON   start | change | heartbeat
      Without `on_change`, each snapshot is written to stdout as one JSON line.
      """
  )

  @Option(name: .shortAndLong, help: "Path to the TOML config file.")
  var config: String?

  @Option(help: "Poll period in seconds.")
  var interval: Double?

  @Option(name: .customLong("on-change"), help: "Shell command to run when badges change.")
  var onChange: String?

  @Option(help: "Re-run the command every N seconds even without changes (0 = off).")
  var heartbeat: Double?

  @Flag(
    name: .customLong("include-empty"), inversion: .prefixedNo,
    help: "Include applications without a badge.")
  var includeEmpty: Bool?

  @Flag(
    name: .customLong("run-on-start"), inversion: .prefixedNo,
    help: "Fire once with the initial snapshot.")
  var runOnStart: Bool?

  @Flag(
    name: .customLong("pause-on-lock"), inversion: .prefixedNo,
    help: "Skip polling while asleep or locked.")
  var pauseOnLock: Bool?

  @Flag(name: .shortAndLong, help: "Log every poll to stderr.")
  var verbose = false

  func run() throws {
    var settings = try WatchConfig.load(path: config)
    if let interval { settings.interval = interval }
    if let onChange { settings.onChange = onChange }
    if let heartbeat { settings.heartbeat = heartbeat }
    if let includeEmpty { settings.includeEmpty = includeEmpty }
    if let runOnStart { settings.runOnStart = runOnStart }
    if let pauseOnLock { settings.pauseOnLock = pauseOnLock }
    if verbose { settings.verbose = true }
    try settings.validate()
    Watcher(config: settings).run()
  }
}
