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
      Without `on_change` (or with --stdout), each snapshot is written to stdout as one JSON line.
      """
  )

  @Option(name: .shortAndLong, help: "Path to the TOML config file.")
  var config: String?

  @Option(help: "Poll period in seconds (minimum \(WatchConfig.minimumInterval)).")
  var interval: Double?

  @Option(name: .customLong("on-change"), help: "Shell command to run when badges change.")
  var onChange: String?

  @Flag(help: "Ignore any configured on_change command and print JSON lines to stdout.")
  var stdout = false

  @Option(help: "Re-run the command every N seconds even without changes (0 = off).")
  var heartbeat: Double?

  @Option(
    name: .customLong("command-timeout"), help: "Kill the command after N seconds (0 = never).")
  var commandTimeout: Double?

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

  @Flag(name: .shortAndLong, inversion: .prefixedNo, help: "Log every poll to stderr.")
  var verbose: Bool?

  func validate() throws {
    if stdout && onChange != nil {
      throw ValidationError("--stdout and --on-change are mutually exclusive.")
    }
  }

  func run() throws {
    let (fileConfig, warnings) = try WatchConfig.load(path: config)
    let settings = Watch.merge(file: fileConfig, cli: self)
    try settings.validate()
    let log = Logger(verbose: settings.verbose)
    for warning in warnings { log.error("warning: \(warning)") }
    // ArgumentParser runs commands on the main thread; hop onto the main actor explicitly.
    MainActor.assumeIsolated { Watcher(config: settings).run() }
  }

  /// CLI options override file values; unspecified options keep the file/default value.
  static func merge(file: WatchConfig, cli: Watch) -> WatchConfig {
    var s = file
    if let v = cli.interval { s.interval = v }
    if let v = cli.onChange { s.onChange = v }
    if cli.stdout { s.onChange = nil }
    if let v = cli.heartbeat { s.heartbeat = v }
    if let v = cli.commandTimeout { s.commandTimeout = v }
    if let v = cli.includeEmpty { s.includeEmpty = v }
    if let v = cli.runOnStart { s.runOnStart = v }
    if let v = cli.pauseOnLock { s.pauseOnLock = v }
    if let v = cli.verbose { s.verbose = v }
    return s
  }
}
