import Foundation
import Testing

@testable import dock_badge_counter

/// Smoke tests against the built executable: argument parsing, exit codes and error output.
/// Nothing here needs Accessibility.
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

  private func run(_ args: [String], env: [String: String] = [:]) throws -> Run {
    let p = Process()
    p.executableURL = CLITests.executable
    p.arguments = args
    var environment = ProcessInfo.processInfo.environment
    environment.merge(env) { $1 }
    p.environment = environment
    let out = Pipe()
    let err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
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

    let missing = try run(["watch", "--config", "/nonexistent/config.toml"])
    #expect(missing.status == 1)
    #expect(missing.stderr.contains("Config file not found: /nonexistent/config.toml"))

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

  @Test func readOutputsJSONOrPermissionError() throws {
    // Whether Accessibility is granted depends on the machine; both outcomes must be well-formed.
    let r = try run(["read"])
    if r.status == 0 {
      let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: String]
      #expect(obj != nil)
    } else {
      #expect(r.status == 1)
      let obj = try JSONSerialization.jsonObject(with: Data(r.stderr.utf8)) as? [String: String]
      #expect(obj?["error"]?.contains("Accessibility") == true)
    }
  }
}
