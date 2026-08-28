import AppKit
import CoreGraphics
import Foundation

/// Polls the Dock on a timer, diffs snapshots and delivers changes either to a shell command
/// (with `DOCK_BADGES*` environment variables) or as NDJSON on stdout.
///
/// All mutable state lives on the main actor; Dispatch/notification callbacks hop onto it.
@MainActor
final class Watcher {
  private static let permissionRetryInterval = 5.0

  private let config: WatchConfig
  private let reader: BadgeReader
  private let log: Logger
  private let runner: CommandRunner?
  private var timer: DispatchSourceTimer?
  private var signalSources: [DispatchSourceSignal] = []
  private var previous: BadgeSnapshot?
  private var lastFire: Double?
  private var pause = PauseState()
  private var trusted = false

  init(config: WatchConfig) {
    self.config = config
    self.reader = BadgeReader(includeEmpty: config.includeEmpty)
    self.log = Logger(verbose: config.verbose)
    self.runner = config.onChange.map {
      CommandRunner(
        command: $0, timeout: config.commandTimeout, log: Logger(verbose: config.verbose))
    }
  }

  /// Blocks forever; the process is expected to be terminated by launchd / a signal.
  func run() -> Never {
    log.info(
      "starting: interval=\(config.interval)s heartbeat=\(config.heartbeat)s pause_on_lock=\(config.pauseOnLock) mode=\(runner == nil ? "stdout" : "command")"
    )
    installSignalHandlers()
    if config.pauseOnLock {
      installPauseObservers()
      if Watcher.screenIsLocked() {
        pause.add(.screenLocked)
        log.debug("starting paused: screen is locked")
      }
    }

    trusted = BadgeReader.isTrusted(prompt: true)
    if !trusted {
      log.error(
        "accessibility permission not granted; waiting (grant it in System Settings > Privacy & Security > Accessibility)"
      )
    }

    let source = DispatchSource.makeTimerSource(queue: .main)
    source.setEventHandler { MainActor.assumeIsolated { self.tick() } }
    timer = source
    schedule(interval: trusted ? config.interval : Watcher.permissionRetryInterval)
    source.resume()

    RunLoop.main.run()
    exit(0)
  }

  private func schedule(interval: Double) {
    let leeway = DispatchTimeInterval.milliseconds(max(1, Int((interval * 200).rounded())))
    timer?.schedule(deadline: .now(), repeating: interval, leeway: leeway)
  }

  private func tick() {
    if !trusted {
      guard BadgeReader.isTrusted(prompt: false) else { return }
      trusted = true
      log.info("accessibility permission granted")
      schedule(interval: config.interval)
    }
    guard !pause.isPaused else { return }
    poll()
  }

  private func poll() {
    let snapshot: BadgeSnapshot
    do {
      snapshot = try reader.read()
    } catch DockBadgeError.accessibilityPermissionDenied {
      // Revoked after start: fall back to the slow retry loop, keep the last snapshot.
      trusted = false
      log.error("accessibility permission lost; waiting for it to be granted again")
      schedule(interval: Watcher.permissionRetryInterval)
      return
    } catch {
      // Transient (Dock restarting/busy): keep the previous snapshot, try again next tick.
      log.error("poll failed: \(error.localizedDescription)")
      return
    }
    log.debug("poll: \(snapshot.count) badge(s)")

    let now = monotonicNow()
    guard let previous else {
      self.previous = snapshot
      lastFire = now
      if config.runOnStart {
        deliver(Delivery(snapshot: snapshot, changed: snapshot, reason: .start))
      }
      return
    }

    let changed = Delivery.diff(old: previous, new: snapshot)
    if !changed.isEmpty {
      self.previous = snapshot
      lastFire = now
      deliver(Delivery(snapshot: snapshot, changed: changed, reason: .change))
    } else if config.heartbeat > 0, now - (lastFire ?? now) >= config.heartbeat {
      lastFire = now
      deliver(Delivery(snapshot: snapshot, changed: [:], reason: .heartbeat))
    }
  }

  private func deliver(_ delivery: Delivery) {
    let changedJSON = (try? JSON.encode(delivery.changed)) ?? "{}"
    log.info("\(delivery.reason.rawValue): \(changedJSON)")
    if let runner {
      runner.submit(delivery)
      return
    }
    do {
      print(try JSON.encode(delivery.snapshot))
      fflush(stdout)
    } catch {
      log.error(error.localizedDescription)
    }
  }

  // MARK: - Pause on sleep / lock

  private static func screenIsLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return session["CGSSessionScreenIsLocked"] as? Bool ?? false
  }

  private func installPauseObservers() {
    let ws = NSWorkspace.shared.notificationCenter
    let dnc = DistributedNotificationCenter.default()
    let transitions: [(NotificationCenter, Notification.Name, PauseReason, Bool)] = [
      (ws, NSWorkspace.willSleepNotification, .sleep, true),
      (ws, NSWorkspace.didWakeNotification, .sleep, false),
      (dnc, Notification.Name("com.apple.screenIsLocked"), .screenLocked, true),
      (dnc, Notification.Name("com.apple.screenIsUnlocked"), .screenLocked, false),
    ]
    for (center, name, reason, pausing) in transitions {
      center.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated {
          self.handlePause(reason: reason, pausing: pausing, source: name.rawValue)
        }
      }
    }
  }

  private func handlePause(reason: PauseReason, pausing: Bool, source: String) {
    if pausing {
      if pause.add(reason) { log.debug("paused (\(source))") }
    } else if pause.remove(reason) {
      log.debug("resumed (\(source))")
      if trusted { poll() }
    }
  }

  // MARK: - Shutdown

  private func installSignalHandlers() {
    for sig in [SIGTERM, SIGINT] {
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      source.setEventHandler {
        MainActor.assumeIsolated {
          self.log.info("exiting on signal \(sig)")
          self.runner?.shutdown()
          exit(0)
        }
      }
      source.resume()
      signalSources.append(source)
    }
  }
}

/// Runs the `on_change` command for deliveries, one at a time. While a command is running, newer
/// deliveries are coalesced into a single pending one, so a slow command can never build up a queue.
@MainActor
final class CommandRunner {
  private let command: String
  private let timeout: Double
  private let log: Logger
  private var running: ChildProcess?
  private var timeoutWork: DispatchWorkItem?
  private var pending: Delivery?

  init(command: String, timeout: Double, log: Logger) {
    self.command = command
    self.timeout = timeout
    self.log = log
  }

  func submit(_ delivery: Delivery) {
    if running != nil {
      pending = pending.map { $0.merged(with: delivery) } ?? delivery
      log.debug("command still running; coalesced pending delivery")
      return
    }
    start(delivery)
  }

  /// Terminates a running command and everything it spawned; used on shutdown.
  func shutdown() {
    running?.terminateGroup(SIGTERM)
  }

  private func start(_ delivery: Delivery) {
    let json: String
    let changedJSON: String
    do {
      json = try JSON.encode(delivery.snapshot)
      changedJSON = try JSON.encode(delivery.changed)
    } catch {
      log.error(error.localizedDescription)
      return
    }
    var env = ProcessInfo.processInfo.environment
    env["DOCK_BADGES"] = json
    env["DOCK_BADGES_CHANGED"] = changedJSON
    env["DOCK_BADGES_REASON"] = delivery.reason.rawValue

    let child: ChildProcess
    do {
      child = try ChildProcess(shellCommand: command, environment: env) { [weak self] exit in
        self?.finished(exit)
      }
    } catch {
      log.error("failed to run on_change command: \(error.localizedDescription)")
      return
    }
    running = child
    if timeout > 0 {
      let work = DispatchWorkItem { [log, timeout] in
        MainActor.assumeIsolated {
          guard child.isRunning else { return }
          log.error("on_change command exceeded \(timeout)s; killing it")
          child.terminateGroup(SIGTERM)
          DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { child.terminateGroup(SIGKILL) }
          }
        }
      }
      timeoutWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }
  }

  private func finished(_ exit: ChildProcess.Exit) {
    timeoutWork?.cancel()
    timeoutWork = nil
    running = nil
    switch exit {
    case .signal(let sig): log.error("on_change command was killed by signal \(sig)")
    case .status(let code) where code != 0:
      log.error("on_change command exited with status \(code)")
    case .status: break
    }
    if let next = pending {
      pending = nil
      start(next)
    }
  }
}

struct Logger: Sendable {
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
    // A single write(2) per line keeps lines intact even if called from several threads.
    FileHandle.standardError.write(Data(line.utf8))
  }
}
