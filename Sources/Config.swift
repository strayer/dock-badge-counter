import Foundation
import TOMLKit

/// Settings for `watch`, loaded from a TOML file and overridable from the command line.
struct WatchConfig: Codable {
  /// Poll period in seconds.
  var interval: Double = 1.0
  /// Include apps without a badge (as empty strings) in snapshots.
  var includeEmpty: Bool = false
  /// Fire once with the initial snapshot right after startup.
  var runOnStart: Bool = true
  /// Re-fire every N seconds even when nothing changed (0 disables).
  var heartbeat: Double = 0
  /// Skip polling while the machine sleeps or the screen is locked.
  var pauseOnLock: Bool = true
  /// Command to run via `/bin/sh -c` on every change. When nil, snapshots are written to stdout as NDJSON.
  var onChange: String?
  /// Log every poll and command run to stderr.
  var verbose: Bool = false

  enum CodingKeys: String, CodingKey {
    case interval
    case includeEmpty = "include_empty"
    case runOnStart = "run_on_start"
    case heartbeat
    case pauseOnLock = "pause_on_lock"
    case onChange = "on_change"
    case verbose
  }

  init() {}

  // Every key is optional in the file; missing keys keep their defaults.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    interval = try c.decodeNumber(forKey: .interval) ?? interval
    includeEmpty = try c.decodeIfPresent(Bool.self, forKey: .includeEmpty) ?? includeEmpty
    runOnStart = try c.decodeIfPresent(Bool.self, forKey: .runOnStart) ?? runOnStart
    heartbeat = try c.decodeNumber(forKey: .heartbeat) ?? heartbeat
    pauseOnLock = try c.decodeIfPresent(Bool.self, forKey: .pauseOnLock) ?? pauseOnLock
    onChange = try c.decodeIfPresent(String.self, forKey: .onChange) ?? onChange
    verbose = try c.decodeIfPresent(Bool.self, forKey: .verbose) ?? verbose
  }

  /// `$XDG_CONFIG_HOME/dock-badge-counter/config.toml`, falling back to `~/.config`.
  static var defaultPath: String {
    let env = ProcessInfo.processInfo.environment
    let base =
      env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
      ?? (env["HOME"] ?? NSHomeDirectory()) + "/.config"
    return base + "/dock-badge-counter/config.toml"
  }

  /// Loads the file at `path`. A missing file at the *default* path is not an error; a missing
  /// explicitly requested file is.
  static func load(path: String?) throws -> WatchConfig {
    let resolved = path ?? defaultPath
    guard FileManager.default.fileExists(atPath: resolved) else {
      if path == nil { return WatchConfig() }
      throw ConfigError.notFound(resolved)
    }
    let text = try String(contentsOfFile: resolved, encoding: .utf8)
    do {
      return try TOMLDecoder().decode(WatchConfig.self, from: text)
    } catch {
      throw ConfigError.invalid(resolved, error)
    }
  }

  func validate() throws {
    guard interval > 0 else { throw ConfigError.invalidValue("interval must be > 0") }
    guard heartbeat >= 0 else { throw ConfigError.invalidValue("heartbeat must be >= 0") }
    if let cmd = onChange, cmd.trimmingCharacters(in: .whitespaces).isEmpty {
      throw ConfigError.invalidValue("on_change must not be empty")
    }
  }
}

extension KeyedDecodingContainer {
  /// TOML distinguishes integers from floats; accept both for numeric settings.
  fileprivate func decodeNumber(forKey key: Key) throws -> Double? {
    if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
    if let i = try? decodeIfPresent(Int.self, forKey: key) { return Double(i) }
    if contains(key) { throw ConfigError.invalidValue("\(key.stringValue) must be a number") }
    return nil
  }
}

enum ConfigError: Error, LocalizedError {
  case notFound(String)
  case invalid(String, Error)
  case invalidValue(String)

  var errorDescription: String? {
    switch self {
    case .notFound(let p): return "Config file not found: \(p)"
    case .invalid(let p, let e):
      return
        "Invalid config file \(p): \((e as? LocalizedError)?.errorDescription ?? String(describing: e))"
    case .invalidValue(let m): return "Invalid configuration: \(m)"
    }
  }
}
