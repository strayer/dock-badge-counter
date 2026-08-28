import Foundation
import Testing

@testable import dock_badge_counter

/// Smoke tests against the built executable: argument parsing, exit codes and error output.
/// Nothing here needs Accessibility or the Dock; every run gets a clean XDG_CONFIG_HOME so the
/// developer's real config can't leak in.
@Suite struct CLITests {
  private static var executable: URL {
    // The test bundle sits next to the executable product in the build directory.
    Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("dock-badge-counter")
  }
  private final class BundleToken {}

  private struct Run {
    let status: Int32
    let stdout: String
    let stderr: String
  }

  /// Runs the binary with a bounded lifetime: a regression that starts the (infinite) watcher
  /// gets killed after `timeout` and reported, instead of hanging the suite.
  private func run(_ args: [String], env: [String: String] = [:], timeout: Double = 10) throws
    -> Run
  {
    let executable = CLITests.executable
    try #require(
      FileManager.default.isExecutableFile(atPath: executable.path),
      "built product missing at \(executable.path)")
    let emptyXDG = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: emptyXDG, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: emptyXDG) }

    let p = Process()
    p.executableURL = executable
    p.arguments = args
    var environment = ProcessInfo.processInfo.environment
    environment["XDG_CONFIG_HOME"] = emptyXDG.path
    environment.merge(env) { $1 }
    p.environment = environment
    let out = Pipe()
    let err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    defer { killer.cancel() }
    let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    if p.terminationReason == .uncaughtSignal {
      Issue.record("\(args) did not exit within \(timeout)s and was killed")
    }
    return Run(status: p.terminationStatus, stdout: stdout, stderr: stderr)
  }

  @Test func versionAndHelp() throws {
    let v = try run(["--version"])
    #expect(v.status == 0)
    #expect(v.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == version)

    let h = try run(["--help"])
    #expect(h.status == 0)
    #expect(h.stdout.contains("read") && h.stdout.contains("watch"))

    let w = try run(["watch", "--help"])
    #expect(w.status == 0)
    #expect(w.stdout.contains("DOCK_BADGES_CHANGED"))
  }

  @Test func usageErrorsExitWith64() throws {
    let r = try run(["watch", "--stdout", "--on-change", "x"])
    #expect(r.status == 64)
    #expect(r.stderr.contains("mutually exclusive"))

    let u = try run(["--bogus"])
    #expect(u.status == 64)
  }

  @Test func validationAndConfigErrorsExitWith1() throws {
    let inf = try run(["watch", "--interval", "inf", "--no-pause-on-lock"])
    #expect(inf.status == 1)
    #expect(inf.stderr.contains("interval must be between"))

    let missingPath = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathComponent("config.toml").path
    let missing = try run(["watch", "--config", missingPath])
    #expect(missing.status == 1)
    #expect(missing.stderr.contains("Config file not found: \(missingPath)"))

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("config.toml")
    try "intervall = 1".write(to: file, atomically: true, encoding: .utf8)
    let typo = try run(["watch", "--config", file.path])
    #expect(typo.status == 1)
    #expect(typo.stderr.contains("Invalid config file \(file.path)"))
  }

  @Test func defaultConfigIsPickedUpFromXDGConfigHome() throws {
    // A broken config in XDG_CONFIG_HOME must be loaded (and rejected) without --config.
    let xdg = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dir = xdg.appendingPathComponent("dock-badge-counter")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: xdg) }
    try "interval = 0".write(
      to: dir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    let r = try run(["watch"], env: ["XDG_CONFIG_HOME": xdg.path])
    #expect(r.status == 1)
    #expect(r.stderr.contains("interval must be between"))
  }
}
