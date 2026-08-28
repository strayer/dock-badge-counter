import Darwin
import Foundation
import Testing

@testable import dock_badge_counter

// MARK: - Helpers

/// Collects a child's exit result and lets a test await it (bounded, so a regression fails fast
/// instead of waiting for a stray `sleep 100`).
@MainActor
private final class ExitBox {
  private(set) var exit: ChildProcess.Exit?

  func resolve(_ exit: ChildProcess.Exit) { self.exit = exit }

  func wait(timeout: Double = 5) async -> ChildProcess.Exit? {
    _ = await waitUntil(timeout: timeout) { exit != nil }
    return exit
  }
}

/// PIDs currently in process group `pgid` (the child itself plus anything it spawned).
private func pids(inGroup pgid: pid_t) -> [pid_t] {
  var buffer = [pid_t](repeating: 0, count: 256)
  let bytes = buffer.withUnsafeMutableBytes { raw in
    proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), raw.baseAddress, Int32(raw.count))
  }
  guard bytes > 0 else { return [] }
  return Array(buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 != 0 }
}

/// Polls `condition` on the main actor (letting Dispatch events run) until it holds or `timeout` passes.
@MainActor
private func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
  let deadline = monotonicNow() + timeout
  while monotonicNow() < deadline {
    if condition() { return true }
    try? await Task.sleep(nanoseconds: 20_000_000)
  }
  return condition()
}

@MainActor
private func spawn(_ command: String, env: [String: String] = [:]) throws -> (ChildProcess, ExitBox)
{
  let box = ExitBox()
  let child = try ChildProcess(shellCommand: command, environment: env) { box.resolve($0) }
  return (child, box)
}

private func tempFile() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("dbc-test-\(UUID().uuidString)")
}

private func lines(of file: URL) -> [String] {
  ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

// MARK: - ChildProcess

@MainActor
@Suite(.serialized) struct ChildProcessTests {
  @Test func reportsExitStatus() async throws {
    let (child, box) = try spawn("exit 3")
    #expect(await box.wait() == .status(3))
    #expect(!child.isRunning)
  }

  @Test func passesEnvironmentAndNullStdin() async throws {
    // `cat` must not block on stdin, and the variable must arrive verbatim (including quotes/JSON).
    let (_, box) = try spawn(
      #"cat >/dev/null && test "$DOCK_BADGES" = '{"A":"1","B":"99+"}'"#,
      env: ["DOCK_BADGES": #"{"A":"1","B":"99+"}"#, "PATH": "/usr/bin:/bin"])
    #expect(await box.wait() == .status(0))
  }

  @Test func exitBeforeSourceRegistrationIsStillReaped() async throws {
    // Spawn many instant exits; every one must be reported exactly once (no zombies, no hangs).
    var boxes: [ExitBox] = []
    for i in 0..<20 {
      boxes.append(try spawn("exit \(i % 4)").1)
    }
    for (i, box) in boxes.enumerated() {
      #expect(await box.wait() == .status(Int32(i % 4)))
    }
  }

  @Test func terminateGroupKillsGrandchildrenEvenWhenParentIgnoresSigterm() async throws {
    // The watcher ignores SIGTERM in-process (Dispatch signal sources). Reproduce that here to
    // prove the spawn attributes reset the disposition for the child tree.
    let previous = signal(SIGTERM, SIG_IGN)
    defer { signal(SIGTERM, previous) }

    let (child, box) = try spawn("echo started; sleep 100")
    // Wait until the shell has forked `sleep` (2 members in the group).
    #expect(await waitUntil { pids(inGroup: child.pid).count >= 2 })

    child.terminateGroup(SIGTERM)
    #expect(await box.wait() == .signal(SIGTERM))
    #expect(await waitUntil { pids(inGroup: child.pid).isEmpty }, "grandchild sleep must be gone")
  }

  @Test func exitCallbackNeverFiresDuringInit() async throws {
    // Regression: a synchronous onExit from init let CommandRunner overwrite `running` with an
    // already-reaped child and coalesce every later delivery forever.
    for _ in 0..<30 {
      var initReturned = false
      var firedDuringInit = false
      let box = ExitBox()
      _ = try ChildProcess(shellCommand: "exit 0", environment: [:]) { exit in
        if !initReturned { firedDuringInit = true }
        box.resolve(exit)
      }
      initReturned = true
      #expect(await box.wait() == .status(0))
      #expect(!firedDuringInit)
    }
  }

  @Test func terminateAfterExitIsHarmless() async throws {
    let (child, box) = try spawn("exit 0")
    #expect(await box.wait() == .status(0))
    child.terminateGroup(SIGTERM)  // must not signal a reused pid / crash
    child.terminateGroup(SIGKILL)
  }
}

// MARK: - CommandRunner

@MainActor
@Suite(.serialized) struct CommandRunnerTests {
  private func runner(_ command: String, timeout: Double = 30) -> CommandRunner {
    CommandRunner(command: command, timeout: timeout, log: Logger(verbose: false))
  }

  @Test func passesSnapshotDiffAndReason() async throws {
    let out = tempFile()
    defer { try? FileManager.default.removeItem(at: out) }
    let r = runner(
      #"echo "$DOCK_BADGES_REASON|$DOCK_BADGES|$DOCK_BADGES_CHANGED" >> "\#(out.path)""#)
    r.submit(Delivery(snapshot: ["A": "1", "B": "2"], changed: ["B": "2"], reason: .change))
    #expect(await waitUntil { lines(of: out).count == 1 })
    #expect(lines(of: out) == [#"change|{"A":"1","B":"2"}|{"B":"2"}"#])
  }

  @Test func coalescesDeliveriesWhileCommandRuns() async throws {
    let out = tempFile()
    defer { try? FileManager.default.removeItem(at: out) }
    let r = runner(
      #"echo "$DOCK_BADGES_REASON|$DOCK_BADGES|$DOCK_BADGES_CHANGED" >> "\#(out.path)"; sleep 0.4"#)

    r.submit(Delivery(snapshot: ["A": "1"], changed: ["A": "1"], reason: .start))
    // These three arrive while the first command sleeps and must collapse into ONE follow-up.
    r.submit(Delivery(snapshot: ["A": "2"], changed: ["A": "2"], reason: .change))
    r.submit(Delivery(snapshot: ["A": "2"], changed: [:], reason: .heartbeat))
    r.submit(
      Delivery(snapshot: ["A": "3", "B": "9"], changed: ["A": "3", "B": "9"], reason: .change))

    #expect(await waitUntil(timeout: 3) { lines(of: out).count == 2 })
    // Give a wrongly queued third invocation a chance to show up.
    try await Task.sleep(nanoseconds: 600_000_000)
    #expect(
      lines(of: out) == [
        #"start|{"A":"1"}|{"A":"1"}"#,
        #"change|{"A":"3","B":"9"}|{"A":"3","B":"9"}"#,
      ])
  }

  @Test func timeoutKillsCommandTreeAndContinuesWithPending() async throws {
    let out = tempFile()
    defer { try? FileManager.default.removeItem(at: out) }
    // First invocation hangs (and its `sleep` grandchild too); the timeout must kill both and the
    // pending delivery must still run afterwards.
    let r = runner(
      #"echo "$DOCK_BADGES_REASON" >> "\#(out.path)"; if [ "$DOCK_BADGES_REASON" = start ]; then sleep 100; fi"#,
      timeout: 0.3)
    r.submit(Delivery(snapshot: [:], changed: [:], reason: .start))
    r.submit(Delivery(snapshot: ["A": "1"], changed: ["A": "1"], reason: .change))

    #expect(await waitUntil(timeout: 3) { lines(of: out) == ["start", "change"] })
    #expect(await waitUntil { !ProcessListing.contains(commandPrefix: "sleep 100") })
  }

  @Test func timeoutEscalatesToSigkillForTrappingCommand() async throws {
    let out = tempFile()
    defer { try? FileManager.default.removeItem(at: out) }
    let r = runner(#"trap "" TERM; echo hung >> "\#(out.path)"; sleep 100"#, timeout: 0.2)
    r.submit(Delivery(snapshot: [:], changed: [:], reason: .start))
    #expect(await waitUntil { lines(of: out) == ["hung"] })
    // SIGTERM is ignored by the shell; SIGKILL follows after 2 s.
    #expect(await waitUntil(timeout: 4) { !ProcessListing.contains(commandPrefix: "sleep 100") })
    // Runner is free again afterwards.
    r.submit(Delivery(snapshot: ["A": "1"], changed: ["A": "1"], reason: .change))
    #expect(await waitUntil { lines(of: out).count == 2 })
  }

  @Test func shutdownTerminatesRunningCommand() async throws {
    let r = runner("sleep 100")
    r.submit(Delivery(snapshot: [:], changed: [:], reason: .start))
    #expect(await waitUntil { ProcessListing.contains(commandPrefix: "sleep 100") })
    r.shutdown()
    #expect(await waitUntil { !ProcessListing.contains(commandPrefix: "sleep 100") })
  }

  @Test func shutdownForceKillsTrappingCommandAndDropsPending() async throws {
    let out = tempFile()
    defer { try? FileManager.default.removeItem(at: out) }
    let r = runner(#"trap "" TERM; echo "$DOCK_BADGES_REASON" >> "\#(out.path)"; sleep 100"#)
    r.submit(Delivery(snapshot: [:], changed: [:], reason: .start))
    r.submit(Delivery(snapshot: ["A": "1"], changed: ["A": "1"], reason: .change))  // pending
    #expect(await waitUntil { lines(of: out) == ["start"] })
    #expect(await waitUntil { ProcessListing.contains(commandPrefix: "sleep 100") })

    r.shutdown(graceSeconds: 0.3)  // blocks ≤ 0.3 s, then SIGKILL
    #expect(await waitUntil { !ProcessListing.contains(commandPrefix: "sleep 100") })
    // The pending delivery must not start after shutdown.
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(lines(of: out) == ["start"])
  }

  @Test func secondDeliveryRunsAfterInstantCommand() async throws {
    // Companion to exitCallbackNeverFiresDuringInit at the CommandRunner level.
    let out = tempFile()
    defer { try? FileManager.default.removeItem(at: out) }
    let r = runner(#"echo "$DOCK_BADGES_REASON" >> "\#(out.path)""#)
    for i in 0..<10 {
      r.submit(Delivery(snapshot: ["A": "\(i)"], changed: ["A": "\(i)"], reason: .change))
      #expect(await waitUntil { lines(of: out).count == i + 1 })
    }
  }
}

/// Minimal `ps`-style lookup for the tests' own descendants (by command line prefix).
private enum ProcessListing {
  static func contains(commandPrefix: String) -> Bool {
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-axo", "command="]
    let pipe = Pipe()
    ps.standardOutput = pipe
    try? ps.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    ps.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").contains {
      $0.hasPrefix(commandPrefix)
    }
  }
}
