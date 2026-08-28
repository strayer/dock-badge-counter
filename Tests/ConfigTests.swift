import ArgumentParser
import Foundation
import Testing

@testable import dock_badge_counter

@Suite struct ConfigTests {
  @Test func defaults() throws {
    let c = WatchConfig()
    #expect(c.interval == 1.0)
    #expect(!c.includeEmpty)
    #expect(c.runOnStart)
    #expect(c.heartbeat == 0)
    #expect(c.pauseOnLock)
    #expect(c.onChange == nil)
    #expect(c.commandTimeout == 30)
    #expect(!c.verbose)
    try c.validate()
  }

  @Test func emptyFileKeepsDefaults() throws {
    #expect(try WatchConfig.parse("") == WatchConfig())
  }

  @Test func parsesAllKeysWithIntegersAndFloats() throws {
    let c = try WatchConfig.parse(
      """
      interval = 2
      include_empty = true
      run_on_start = false
      heartbeat = 60.5
      pause_on_lock = false
      on_change = 'echo "$DOCK_BADGES"'
      command_timeout = 0
      verbose = true
      """)
    #expect(c.interval == 2)
    #expect(c.includeEmpty)
    #expect(!c.runOnStart)
    #expect(c.heartbeat == 60.5)
    #expect(!c.pauseOnLock)
    #expect(c.onChange == "echo \"$DOCK_BADGES\"")
    #expect(c.commandTimeout == 0)
    #expect(c.verbose)
  }

  @Test func rejectsUnknownKeys() {
    #expect(throws: (any Error).self) { try WatchConfig.parse("intervall = 1") }
  }

  @Test func rejectsWrongTypes() {
    #expect(throws: ConfigError.invalidValue("interval must be a number")) {
      try WatchConfig.parse("interval = \"fast\"")
    }
    #expect(throws: (any Error).self) { try WatchConfig.parse("verbose = 1") }
  }

  @Test(arguments: [0.0, 0.05, .infinity, .nan, -1, 100_000])
  func rejectsBadIntervals(interval: Double) {
    var c = WatchConfig()
    c.interval = interval
    #expect(throws: ConfigError.self) { try c.validate() }
  }

  @Test(arguments: [
    ("heartbeat", -1.0), ("heartbeat", 86_401), ("heartbeat", .infinity), ("heartbeat", .nan),
    ("command_timeout", -0.5), ("command_timeout", 86_401), ("command_timeout", -.infinity),
    ("command_timeout", .nan),
  ])
  func rejectsOutOfRangeNumbers(field: String, value: Double) {
    var c = WatchConfig()
    if field == "heartbeat" { c.heartbeat = value } else { c.commandTimeout = value }
    #expect(throws: ConfigError.self) { try c.validate() }
  }

  @Test func acceptsBoundaryValues() throws {
    var c = WatchConfig()
    c.interval = 86_400
    c.heartbeat = 86_400
    c.commandTimeout = 86_400
    try c.validate()
    c.heartbeat = 0
    c.commandTimeout = 0
    try c.validate()
  }

  @Test func validationBounds() throws {
    var c = WatchConfig()
    c.interval = WatchConfig.minimumInterval
    try c.validate()

    c.heartbeat = -1
    #expect(throws: ConfigError.self) { try c.validate() }
    c.heartbeat = .infinity
    #expect(throws: ConfigError.self) { try c.validate() }
    c.heartbeat = 0
    try c.validate()

    c.commandTimeout = -1
    #expect(throws: ConfigError.self) { try c.validate() }
    c.commandTimeout = 30
    c.onChange = "  \n"
    #expect(throws: ConfigError.invalidValue("on_change must not be empty")) { try c.validate() }
  }

  @Test func defaultPathHonoursAbsoluteXDGOnly() {
    #expect(
      WatchConfig.defaultPath(environment: ["HOME": "/Users/x", "XDG_CONFIG_HOME": "/xdg"])
        == "/xdg/dock-badge-counter/config.toml")
    #expect(
      WatchConfig.defaultPath(environment: ["HOME": "/Users/x", "XDG_CONFIG_HOME": "relative"])
        == "/Users/x/.config/dock-badge-counter/config.toml")
    #expect(
      WatchConfig.defaultPath(environment: ["HOME": "/Users/x"])
        == "/Users/x/.config/dock-badge-counter/config.toml")
  }

  @Test func loadMissingExplicitFileFails() {
    #expect(throws: ConfigError.notFound("/nonexistent/config.toml")) {
      try WatchConfig.load(path: "/nonexistent/config.toml")
    }
  }

  @Test func loadWarnsOnWorldWritableFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("config.toml")
    try "interval = 2".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
    let (config, warnings) = try WatchConfig.load(path: file.path)
    #expect(config.interval == 2)
    #expect(warnings.count == 1)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    #expect(try WatchConfig.load(path: file.path).warnings == [])
  }

  @Test func loadReportsParseErrorsWithPath() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("config.toml")
    try "interval = = 1".write(to: file, atomically: true, encoding: .utf8)
    #expect(throws: ConfigError.self) { try WatchConfig.load(path: file.path) }
    do {
      _ = try WatchConfig.load(path: file.path)
      Issue.record("expected a parse error")
    } catch let error as ConfigError {
      guard case .invalid(let path, _) = error else {
        Issue.record("expected .invalid, got \(error)")
        return
      }
      #expect(path == file.path)
      #expect(error.errorDescription?.contains(file.path) == true)
    }

    // A wrong numeric type is reported the same way, with the path attached.
    try "interval = \"fast\"".write(to: file, atomically: true, encoding: .utf8)
    #expect(throws: ConfigError.invalid(file.path, "interval must be a number")) {
      try WatchConfig.load(path: file.path)
    }
  }

  /// Every CLI option must override a deliberately non-default file value; every omitted option
  /// must leave it alone.
  @Test func eachCLIOptionOverridesOnlyItsField() throws {
    // File config with every value non-default; each case flips exactly one field from it.
    var file = WatchConfig()
    file.interval = 5
    file.heartbeat = 120
    file.commandTimeout = 7
    file.onChange = "file-command"
    file.includeEmpty = true
    file.runOnStart = false
    file.pauseOnLock = false
    file.verbose = true

    let cases: [(args: [String], apply: (inout WatchConfig) -> Void)] = [
      (["--interval", "0.5"], { $0.interval = 0.5 }),
      (["--heartbeat", "9"], { $0.heartbeat = 9 }),
      (["--command-timeout", "3"], { $0.commandTimeout = 3 }),
      (["--on-change", "echo hi"], { $0.onChange = "echo hi" }),
      (["--stdout"], { $0.onChange = nil }),
      (["--no-include-empty"], { $0.includeEmpty = false }),
      (["--run-on-start"], { $0.runOnStart = true }),
      (["--pause-on-lock"], { $0.pauseOnLock = true }),
      (["--no-verbose"], { $0.verbose = false }),
      // Same-as-file values are still fine to pass explicitly.
      (["--include-empty"], { $0.includeEmpty = true }),
      (["--no-run-on-start"], { $0.runOnStart = false }),
      (["--no-pause-on-lock"], { $0.pauseOnLock = false }),
      (["--verbose"], { $0.verbose = true }),
      ([], { _ in }),
    ]
    for c in cases {
      var expected = file
      c.apply(&expected)
      let merged = Watch.merge(file: file, cli: try Watch.parse(c.args))
      #expect(merged == expected, "args: \(c.args)")
    }
  }

  @Test func cliOverridesFile() throws {
    var file = WatchConfig()
    file.interval = 5
    file.onChange = "true"
    file.verbose = true

    let cli = try Watch.parse(["--interval", "0.5", "--no-verbose", "--heartbeat", "9"])
    let merged = Watch.merge(file: file, cli: cli)
    #expect(merged.interval == 0.5)
    #expect(!merged.verbose)
    #expect(merged.heartbeat == 9)
    #expect(merged.onChange == "true")  // untouched

    let stdout = try Watch.parse(["--stdout"])
    #expect(Watch.merge(file: file, cli: stdout).onChange == nil)

    #expect(throws: (any Error).self) { try Watch.parse(["--stdout", "--on-change", "x"]) }
  }
}
