import Foundation
import TOMLKit

/// Settings for `watch`, loaded from a TOML file and overridable from the command line.
struct WatchConfig: Codable, Equatable {
  /// Smallest accepted poll period; anything faster is a hot loop against the Dock.
  static let minimumInterval = 0.1

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
  /// Kill the `on_change` command if it runs longer than this many seconds (0 disables).
  var commandTimeout: Double = 30
  /// Log every poll and command run to stderr.
  var verbose: Bool = false

  enum CodingKeys: String, CodingKey {
    case interval
    case includeEmpty = "include_empty"
    case runOnStart = "run_on_start"
    case heartbeat
    case pauseOnLock = "pause_on_lock"
    case onChange = "on_change"
    case commandTimeout = "command_timeout"
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
    commandTimeout = try c.decodeNumber(forKey: .commandTimeout) ?? commandTimeout
    verbose = try c.decodeIfPresent(Bool.self, forKey: .verbose) ?? verbose
  }

  /// `$XDG_CONFIG_HOME/dock-badge-counter/config.toml`, falling back to `~/.config`.
  /// Per the XDG spec a relative `XDG_CONFIG_HOME` is invalid and ignored.
  static func defaultPath(environment env: [String: String] = ProcessInfo.processInfo.environment)
    -> String
  {
    let xdg = env["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
    let home = env["HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? NSHomeDirectory()
    return (xdg ?? home + "/.config") + "/dock-badge-counter/config.toml"
  }

  /// Loads the file at `path`. A missing file at the *default* path is not an error; a missing
  /// explicitly requested file is. Returns the config and a list of non-fatal warnings.
  static func load(path: String?) throws -> (WatchConfig, warnings: [String]) {
    let resolved = path ?? defaultPath()
    guard FileManager.default.fileExists(atPath: resolved) else {
      if path == nil { return (WatchConfig(), []) }
      throw ConfigError.notFound(resolved)
    }
    let text: String
    do {
      text = try String(contentsOfFile: resolved, encoding: .utf8)
    } catch {
      throw ConfigError.unreadable(resolved, error.localizedDescription)
    }
    do {
      return (try parse(text), permissionWarnings(path: resolved))
    } catch let error as ConfigError {
      throw error
    } catch {
      throw ConfigError.invalid(resolved, describe(error))
    }
  }

  /// Parses TOML text. Unknown keys are rejected so typos don't silently fall back to defaults.
  static func parse(_ text: String) throws -> WatchConfig {
    var decoder = TOMLDecoder()
    decoder.strictDecoding = true
    return try decoder.decode(WatchConfig.self, from: text)
  }

  /// The config file is effectively executable code (`on_change` runs in a shell); warn if others can edit it.
  static func permissionWarnings(path: String) -> [String] {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
      let mode = attrs[.posixPermissions] as? Int
    else { return [] }
    if mode & 0o022 != 0 {
      return [
        "config file \(path) is group- or world-writable; its on_change command runs in a shell"
      ]
    }
    return []
  }

  func validate() throws {
    guard interval.isFinite, interval >= WatchConfig.minimumInterval, interval <= 86_400 else {
      throw ConfigError.invalidValue(
        "interval must be between \(WatchConfig.minimumInterval) and 86400 seconds")
    }
    guard heartbeat.isFinite, heartbeat >= 0, heartbeat <= 86_400 else {
      throw ConfigError.invalidValue("heartbeat must be between 0 and 86400 seconds")
    }
    guard commandTimeout.isFinite, commandTimeout >= 0, commandTimeout <= 86_400 else {
      throw ConfigError.invalidValue("command_timeout must be between 0 and 86400 seconds")
    }
    if let cmd = onChange, cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw ConfigError.invalidValue("on_change must not be empty")
    }
  }

  private static func describe(_ error: Error) -> String {
    if let decoding = error as? DecodingError {
      switch decoding {
      case .keyNotFound(let key, _): return "unexpected type for key '\(key.stringValue)'"
      case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
        let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? ctx.debugDescription : "\(path): \(ctx.debugDescription)"
      @unknown default: break
      }
    }
    return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
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

enum ConfigError: Error, LocalizedError, Equatable {
  case notFound(String)
  case unreadable(String, String)
  case invalid(String, String)
  case invalidValue(String)

  var errorDescription: String? {
    switch self {
    case .notFound(let p): return "Config file not found: \(p)"
    case .unreadable(let p, let m): return "Cannot read config file \(p): \(m)"
    case .invalid(let p, let m): return "Invalid config file \(p): \(m)"
    case .invalidValue(let m): return "Invalid configuration: \(m)"
    }
  }
}
