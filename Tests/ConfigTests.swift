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
    #expect(throws: ConfigError.self) { try WatchConfig.parse("interval = \"fast\"") }
    do {
      _ = try WatchConfig.parse("interval = \"fast\"")
    } catch let ConfigError.invalidValue(message) {
      #expect(message.contains("interval"))
    } catch {
      Issue.record("expected .invalidValue, got \(error)")
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

  @Test func minimumIntervalIsAcceptedAndBlankCommandRejected() throws {
    var c = WatchConfig()
    c.interval = WatchConfig.minimumInterval
    try c.validate()
    c.onChange = "  \n"
    #expect(throws: ConfigError.self) { try c.validate() }
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
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathComponent("config.toml").path
    #expect(throws: ConfigError.notFound(path)) { try WatchConfig.load(path: path) }
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
    #expect(warnings.contains { $0.contains("writable") && $0.contains(file.path) })
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    #expect(!(try WatchConfig.load(path: file.path).warnings.contains { $0.contains("writable") }))
  }

  @Test func loadReportsParseErrorsWithPath() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("config.toml")
    try "interval = = 1".write(to: file, atomically: true, encoding: .utf8)
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
    do {
      _ = try WatchConfig.load(path: file.path)
      Issue.record("expected a type error")
    } catch let ConfigError.invalid(path, message) {
      #expect(path == file.path)
      #expect(message.contains("interval"))
    } catch {
      Issue.record("expected .invalid, got \(error)")
    }
  }

  /// Every CLI option must override the file value — in both polarities for flags — and every
  /// omitted option must leave the file value alone. Run against two opposite file baselines so a
  /// silently ignored flag can never coincide with the file's value.
  @Test func eachCLIOptionOverridesOnlyItsField() throws {
    var baseA = WatchConfig()
    baseA.interval = 5
    baseA.heartbeat = 120
    baseA.commandTimeout = 7
    baseA.onChange = "file-command"
    baseA.includeEmpty = true
    baseA.runOnStart = false
    baseA.pauseOnLock = false
    baseA.verbose = true
    var baseB = WatchConfig()
    baseB.interval = 2
    baseB.heartbeat = 0
    baseB.commandTimeout = 0
    baseB.onChange = nil
    baseB.includeEmpty = false
    baseB.runOnStart = true
    baseB.pauseOnLock = true
    baseB.verbose = false

    let cases: [(args: [String], apply: (inout WatchConfig) -> Void)] = [
      (["--interval", "0.5"], { $0.interval = 0.5 }),
      (["--heartbeat", "9"], { $0.heartbeat = 9 }),
      (["--command-timeout", "3"], { $0.commandTimeout = 3 }),
      (["--on-change", "echo hi"], { $0.onChange = "echo hi" }),
      (["--stdout"], { $0.onChange = nil }),
      (["--include-empty"], { $0.includeEmpty = true }),
      (["--no-include-empty"], { $0.includeEmpty = false }),
      (["--run-on-start"], { $0.runOnStart = true }),
      (["--no-run-on-start"], { $0.runOnStart = false }),
      (["--pause-on-lock"], { $0.pauseOnLock = true }),
      (["--no-pause-on-lock"], { $0.pauseOnLock = false }),
      (["--verbose"], { $0.verbose = true }),
      (["--no-verbose"], { $0.verbose = false }),
      ([], { _ in }),
    ]
    for file in [baseA, baseB] {
      for c in cases {
        var expected = file
        c.apply(&expected)
        let merged = Watch.merge(file: file, cli: try Watch.parse(c.args))
        #expect(merged == expected, "args: \(c.args)")
      }
    }
  }

  @Test func stdoutAndOnChangeAreMutuallyExclusive() {
    #expect(throws: (any Error).self) { try Watch.parse(["--stdout", "--on-change", "x"]) }
  }

}
