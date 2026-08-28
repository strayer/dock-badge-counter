import AppKit
import Foundation

/// Why a snapshot is being delivered.
enum FireReason: String {
  case start, change, heartbeat
}

/// Polls the Dock on a timer, diffs snapshots and delivers changes either to a shell command
/// (with `DOCK_BADGES*` environment variables) or as NDJSON on stdout.
final class Watcher {
  private let config: WatchConfig
  private let reader: BadgeReader
  private let log: Logger
  private var timer: DispatchSourceTimer?
  private var previous: BadgeSnapshot?
  private var lastFire = Date.distantPast
  private var paused = false
  private var trusted = false
  private let commandQueue = DispatchQueue(label: "dock-badge-counter.command")

  init(config: WatchConfig) {
    self.config = config
    self.reader = BadgeReader(includeEmpty: config.includeEmpty)
    self.log = Logger(verbose: config.verbose)
  }

  /// Blocks forever; the process is expected to be terminated by launchd / a signal.
  func run() -> Never {
    log.info(
      "starting: interval=\(config.interval)s heartbeat=\(config.heartbeat)s pause_on_lock=\(config.pauseOnLock) mode=\(config.onChange == nil ? "stdout" : "command")"
    )
    installSignalHandlers()
    if config.pauseOnLock { installPauseObservers() }

    trusted = BadgeReader.isTrusted(prompt: true)
    if !trusted {
      log.error(
        "accessibility permission not granted; waiting (grant it in System Settings > Privacy & Security > Accessibility)"
      )
    }

    let source = DispatchSource.makeTimerSource(queue: .main)
    let interval = trusted ? config.interval : 5.0
    source.schedule(
      deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * 200)))
    source.setEventHandler { [weak self] in self?.tick() }
    source.resume()
    timer = source

    RunLoop.main.run()
    exit(0)
  }

  private func tick() {
    if !trusted {
      guard BadgeReader.isTrusted(prompt: false) else { return }
      trusted = true
      log.info("accessibility permission granted")
      timer?.schedule(
        deadline: .now(), repeating: config.interval,
        leeway: .milliseconds(Int(config.interval * 200)))
    }
    guard !paused else { return }
    poll()
  }

  private func poll() {
    let snapshot: BadgeSnapshot
    do {
      snapshot = try reader.read()
    } catch {
      log.error("poll failed: \(error.localizedDescription)")
      return
    }
    log.debug("poll: \(snapshot.count) badge(s)")

    guard let previous else {
      self.previous = snapshot
      if config.runOnStart { fire(snapshot, changed: snapshot, reason: .start) }
      return
    }

    let changed = Watcher.diff(old: previous, new: snapshot)
    if !changed.isEmpty {
      self.previous = snapshot
      fire(snapshot, changed: changed, reason: .change)
    } else if config.heartbeat > 0, Date().timeIntervalSince(lastFire) >= config.heartbeat {
      fire(snapshot, changed: [:], reason: .heartbeat)
    }
  }

  /// Keys whose value differs; keys that disappeared are reported with an empty value.
  static func diff(old: BadgeSnapshot, new: BadgeSnapshot) -> BadgeSnapshot {
    var changed: BadgeSnapshot = [:]
    for (app, badge) in new where old[app] != badge { changed[app] = badge }
    for app in old.keys where new[app] == nil { changed[app] = "" }
    return changed
  }

  private func fire(_ snapshot: BadgeSnapshot, changed: BadgeSnapshot, reason: FireReason) {
    lastFire = Date()
    let json: String
    let changedJSON: String
    do {
      json = try JSON.encode(snapshot)
      changedJSON = try JSON.encode(changed)
    } catch {
      log.error("\(error.localizedDescription)")
      return
    }
    log.info("\(reason.rawValue): \(changedJSON)")

    guard let command = config.onChange else {
      print(json)
      fflush(stdout)
      return
    }
    var env = ProcessInfo.processInfo.environment
    env["DOCK_BADGES"] = json
    env["DOCK_BADGES_CHANGED"] = changedJSON
    env["DOCK_BADGES_REASON"] = reason.rawValue
    // Serial queue: commands run in order and never overlap, but don't block polling.
    commandQueue.async { [log] in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", command]
      process.environment = env
      process.standardInput = FileHandle.nullDevice
      do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
          log.error("on_change command exited with status \(process.terminationStatus)")
        }
      } catch {
        log.error("failed to run on_change command: \(error.localizedDescription)")
      }
    }
  }

  private func installPauseObservers() {
    let ws = NSWorkspace.shared.notificationCenter
    let dnc = DistributedNotificationCenter.default()
    let pause: [(NotificationCenter, Notification.Name)] = [
      (ws, NSWorkspace.willSleepNotification),
      (dnc, Notification.Name("com.apple.screenIsLocked")),
    ]
    let resume: [(NotificationCenter, Notification.Name)] = [
      (ws, NSWorkspace.didWakeNotification),
      (dnc, Notification.Name("com.apple.screenIsUnlocked")),
    ]
    for (center, name) in pause {
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.log.debug("paused (\(name.rawValue))")
        self?.paused = true
      }
    }
    for (center, name) in resume {
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        guard let self else { return }
        self.log.debug("resumed (\(name.rawValue))")
        self.paused = false
        if self.trusted { self.poll() }
      }
    }
  }

  private func installSignalHandlers() {
    for sig in [SIGTERM, SIGINT] {
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      source.setEventHandler { [log] in
        log.info("exiting on signal \(sig)")
        exit(0)
      }
      source.resume()
      signalSources.append(source)
    }
  }
  private var signalSources: [DispatchSourceSignal] = []
}

struct Logger {
  let verbose: Bool
  private static let formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  func info(_ message: String) { write("info", message) }
  func error(_ message: String) { write("error", message) }
  func debug(_ message: String) { if verbose { write("debug", message) } }

  private func write(_ level: String, _ message: String) {
    let line = "\(Logger.formatter.string(from: Date())) [\(level)] \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
  }
}
