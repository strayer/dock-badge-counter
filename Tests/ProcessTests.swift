import Darwin
import Foundation
import Testing

@testable import dock_badge_counter

// MARK: - Helpers

/// Collects every exit callback for a child so tests can assert exactly-once delivery.
@MainActor
private final class ExitBox {
  private(set) var exits: [ChildProcess.Exit] = []

  func resolve(_ exit: ChildProcess.Exit) { exits.append(exit) }

  /// Waits (bounded) for the first exit; a regression fails fast instead of hanging on a stray child.
  func wait(timeout: Double = 5) async -> ChildProcess.Exit? {
    _ = await waitUntil(timeout: timeout) { !exits.isEmpty }
    return exits.first
  }
}

/// PIDs currently in process group `pgid` (the shell plus anything it spawned). Scoped to our own
/// children, so unrelated `sleep`s on the machine can't influence the tests.
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

/// Unconditional cleanup of every process group a test started, so a regression that leaves a
/// `sleep 100` behind cannot contaminate later tests.
@MainActor
private final class Groups {
  private var pgids: Set<pid_t> = []
  func track(_ pgid: pid_t) { pgids.insert(pgid) }
  func killAll() {
    for pgid in pgids { kill(-pgid, SIGKILL) }
    // Bounded wait so a leaked child from a failed test is really gone before the next test.
    let deadline = monotonicNow() + 2
    while monotonicNow() < deadline, pgids.contains(where: { !pids(inGroup: $0).isEmpty }) {
      usleep(10_000)
    }
  }
}

/// A temp file plus the shell prelude that records the command's own PID (== its process group,
/// since ChildProcess spawns into a fresh group) so tests can watch exactly their own children.
@MainActor
private struct Probe {
  let pidFile: URL
  let outFile: URL
  let groups: Groups

  init(_ groups: Groups) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dbc-\(UUID().uuidString)")
    pidFile = base.appendingPathExtension("pid")
    outFile = base.appendingPathExtension("out")
    self.groups = groups
  }

  /// Shell snippet to prepend to a command.
  var prelude: String { #"echo $$ >> "\#(pidFile.path)"; "# }

  /// Process groups of every invocation seen so far (one per line in the pid file).
  var pgids: [pid_t] {
    let ids = lines(of: pidFile).compactMap { pid_t($0) }
    ids.forEach(groups.track)
    return ids
  }

  var output: [String] { lines(of: outFile) }

  /// Registers every group seen so far (so the caller's cleanup catches late starters) and
  /// deletes the probe files.
  func remove() {
    _ = pgids
    try? FileManager.default.removeItem(at: pidFile)
    try? FileManager.default.removeItem(at: outFile)
    try? FileManager.default.removeItem(atPath: gate)
  }

  /// A file the shell command waits for; `open()` lets the test release the command.
  var gate: String { pidFile.path + ".gate" }
  func openGate() { FileManager.default.createFile(atPath: gate, contents: nil) }
  /// Shell snippet: block until the gate exists (checked every 20 ms).
  var waitForGate: String { #"while [ ! -e "\#(gate)" ]; do sleep 0.02; done"# }

  /// Waits until invocation `index` has spawned at least `members` processes in its group.
  func waitForGroup(_ index: Int, members: Int = 1, timeout: Double = 5) async -> pid_t? {
    guard
      await waitUntil(
        timeout: timeout, { pgids.count > index && pids(inGroup: pgids[index]).count >= members })
    else {
      return nil
    }
    return pgids[index]
  }

  func waitForGroupGone(_ pgid: pid_t, timeout: Double = 5) async -> Bool {
    await waitUntil(timeout: timeout) { pids(inGroup: pgid).isEmpty }
  }
}

private func lines(of file: URL) -> [String] {
  guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
  return text.split(separator: "\n").map(String.init)
}

@MainActor
private func spawn(_ command: String, env: [String: String] = [:], groups: Groups) throws -> (
  ChildProcess, ExitBox
) {
  let box = ExitBox()
  let child = try ChildProcess(shellCommand: command, environment: env) { box.resolve($0) }
  groups.track(child.pid)
  return (child, box)
}

// MARK: - Suites
//
// One serialized parent: the tests spawn real processes, and one of them changes the process-wide
// SIGTERM disposition, so nothing here may overlap.

@Suite(.serialized) struct ProcessSuites {

  @MainActor
  @Suite struct ChildProcessTests {
    @Test func reportsExitStatus() async throws {
      let groups = Groups()
      defer { groups.killAll() }
      let (child, box) = try spawn("exit 3", groups: groups)
      #expect(await box.wait() == .status(3))
      #expect(!child.isRunning)
    }

    @Test func passesEnvironmentAndNullStdin() async throws {
      let groups = Groups()
      defer { groups.killAll() }
      // `cat` must not block on stdin, and the variable must arrive verbatim (quotes, JSON, `+`).
      let (_, box) = try spawn(
        #"cat >/dev/null && test "$DOCK_BADGES" = '{"A":"1","B":"99+"}'"#,
        env: ["DOCK_BADGES": #"{"A":"1","B":"99+"}"#, "PATH": "/usr/bin:/bin"],
        groups: groups)
      #expect(await box.wait() == .status(0))
    }

    @Test func everyInstantExitIsReportedExactlyOnce() async throws {
      let groups = Groups()
      defer { groups.killAll() }
      var boxes: [ExitBox] = []
      for i in 0..<20 {
        boxes.append(try spawn("exit \(i % 4)", groups: groups).1)
      }
      for (i, box) in boxes.enumerated() {
        #expect(await box.wait() == .status(Int32(i % 4)))
      }
      // Any duplicate callback (source + WNOHANG check both reaping) would already be enqueued on
      // the main queue by now; drain it with a barrier rather than sleeping for a while.
      await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
      #expect(boxes.allSatisfy { $0.exits.count == 1 })
    }

    @Test func exitCallbackNeverFiresDuringInit() async throws {
      // Regression: a synchronous onExit from init let CommandRunner overwrite `running` with an
      // already-reaped child and coalesce every later delivery forever.
      let groups = Groups()
      defer { groups.killAll() }
      for _ in 0..<30 {
        var initReturned = false
        var firedDuringInit = false
        let box = ExitBox()
        let child = try ChildProcess(shellCommand: "exit 0", environment: [:]) { exit in
          if !initReturned { firedDuringInit = true }
          box.resolve(exit)
        }
        groups.track(child.pid)
        initReturned = true
        #expect(await box.wait() == .status(0))
        #expect(!firedDuringInit)
      }
    }

    @Test func terminateGroupKillsGrandchildrenEvenWhenParentIgnoresSigterm() async throws {
      // The watcher ignores SIGTERM in-process (Dispatch signal sources). Reproduce that here to
      // prove the spawn attributes reset the disposition for the child tree.
      let previous = signal(SIGTERM, SIG_IGN)
      defer { signal(SIGTERM, previous) }
      let groups = Groups()
      defer { groups.killAll() }

      // `sleep … &` + `wait` guarantees a separate child process even if the shell would exec its
      // last command.
      let (child, box) = try spawn("sleep 100 & wait $!", groups: groups)
      #expect(await waitUntil { pids(inGroup: child.pid).count >= 2 })

      child.terminateGroup(SIGTERM)
      #expect(await box.wait() == .signal(SIGTERM))
      #expect(await waitUntil { pids(inGroup: child.pid).isEmpty }, "grandchild sleep must be gone")
    }
  }

  @MainActor
  @Suite struct CommandRunnerTests {
    private func runner(_ command: String, timeout: Double = 30) -> CommandRunner {
      CommandRunner(command: command, timeout: timeout, log: Logger(verbose: false))
    }

    @Test func passesSnapshotDiffAndReason() async throws {
      let groups = Groups()
      defer { groups.killAll() }
      let probe = Probe(groups)
      defer { probe.remove() }
      let r = runner(
        probe.prelude
          + #"echo "$DOCK_BADGES_REASON|$DOCK_BADGES|$DOCK_BADGES_CHANGED" >> "\#(probe.outFile.path)""#
      )
      r.submit(Delivery(snapshot: ["A": "1", "B": "2"], changed: ["B": "2"], reason: .change))
      #expect(await waitUntil { r.isIdle })
      #expect(probe.output == [#"change|{"A":"1","B":"2"}|{"B":"2"}"#])
    }

    @Test func coalescesDeliveriesWhileCommandRuns() async throws {
      let groups = Groups()
      defer { groups.killAll() }
      let probe = Probe(groups)
      defer { probe.remove() }
      // The first invocation blocks on a gate the test controls, so "while the command runs" is
      // exact rather than a race against a sleep.
      let r = runner(
        probe.prelude
          + #"echo "$DOCK_BADGES_REASON|$DOCK_BADGES|$DOCK_BADGES_CHANGED" >> "\#(probe.outFile.path)"; "#
          + #"if [ "$DOCK_BADGES_REASON" = start ]; then \#(probe.waitForGate); fi"#)

      r.submit(Delivery(snapshot: ["A": "1"], changed: ["A": "1"], reason: .start))
      _ = try #require(await probe.waitForGroup(0))
      // These three arrive while the first command is blocked and must collapse into ONE follow-up.
      r.submit(Delivery(snapshot: ["A": "2"], changed: ["A": "2"], reason: .change))
      r.submit(Delivery(snapshot: ["A": "2"], changed: [:], reason: .heartbeat))
      r.submit(
        Delivery(snapshot: ["A": "3", "B": "9"], changed: ["A": "3", "B": "9"], reason: .change))
      probe.openGate()

      // Idle = the follow-up finished and nothing is queued, so a wrongly queued third invocation
      // is excluded deterministically.
      #expect(await waitUntil { r.isIdle })
      #expect(
        probe.output == [
          #"start|{"A":"1"}|{"A":"1"}"#,
          #"change|{"A":"3","B":"9"}|{"A":"3","B":"9"}"#,
        ])
    }

    @Test func timeoutKillsCommandTreeAndContinuesWithPending() async throws {
      let groups = Groups()
      defer { groups.killAll() }
      let probe = Probe(groups)
      defer { probe.remove() }
      // First invocation hangs (with a `sleep` grandchild); the timeout must kill both and the
      // pending delivery must still run afterwards.
      let r = runner(
        probe.prelude
          + #"echo "$DOCK_BADGES_REASON" >> "\#(probe.outFile.path)"; if [ "$DOCK_BADGES_REASON" = start ]; then sleep 100 & wait $!; fi"#,
        timeout: 0.3)
      r.submit(Delivery(snapshot: [:], changed: [:], reason: .start))
      r.submit(Delivery(snapshot: ["A": "1"], changed: ["A": "1"], reason: .change))

      let first = try #require(
        await probe.waitForGroup(0, members: 2), "first invocation should be running with its sleep"
      )
      #expect(await waitUntil { r.isIdle })
      #expect(probe.output == ["start", "change"])
      #expect(await probe.waitForGroupGone(first), "sh and its sleep must both be dead")
    }

    @Test func timeoutEscalatesToSigkillForTrappingCommand() async throws {
      let groups = Groups()
      defer { groups.killAll() }
      let probe = Probe(groups)
      defer { probe.remove() }
      let r = runner(
        probe.prelude
          + #"echo "$DOCK_BADGES_REASON" >> "\#(probe.outFile.path)"; if [ "$DOCK_BADGES_REASON" = start ]; then trap "" TERM; sleep 100 & wait $!; fi"#,
        timeout: 0.2)
      r.submit(Delivery(snapshot: [:], changed: [:], reason: .start))
      let first = try #require(await probe.waitForGroup(0, members: 2))
      // SIGTERM is ignored by the shell; SIGKILL follows after 2 s (deadline is generous, not a limit).
      #expect(await probe.waitForGroupGone(first, timeout: 10))
      // Runner is free again afterwards and the next command exits immediately.
      r.submit(Delivery(snapshot: ["A": "1"], changed: ["A": "1"], reason: .change))
      #expect(await waitUntil { r.isIdle })
      #expect(probe.output == ["start", "change"])
    }

    @Test func shutdownTerminatesRunningCommand() async throws {
      let groups = Groups()
      defer { groups.killAll() }
      let probe = Probe(groups)
      defer { probe.remove() }
      let r = runner(probe.prelude + "sleep 100 & wait $!")
      r.submit(Delivery(snapshot: [:], changed: [:], reason: .start))
      let first = try #require(await probe.waitForGroup(0, members: 2))
      r.shutdown()
      #expect(await probe.waitForGroupGone(first))
      // The child was reaped through ChildProcess (exactly-once), so the runner is idle again.
      #expect(await waitUntil { r.isIdle })
    }

    @Test func shutdownForceKillsTrappingCommandAndDropsPending() async throws {
      let groups = Groups()
      defer { groups.killAll() }
      let probe = Probe(groups)
      defer { probe.remove() }
      let r = runner(
        probe.prelude
          + #"trap "" TERM; echo "$DOCK_BADGES_REASON" >> "\#(probe.outFile.path)"; sleep 100 & wait $!"#
      )
      r.submit(Delivery(snapshot: [:], changed: [:], reason: .start))
      r.submit(Delivery(snapshot: ["A": "1"], changed: ["A": "1"], reason: .change))  // pending
      let first = try #require(await probe.waitForGroup(0, members: 2))

      r.shutdown(graceSeconds: 0.3)  // blocks ≤ 0.3 s, then SIGKILL
      #expect(await probe.waitForGroupGone(first))
      // The pending delivery must have been dropped, not started: once idle, only "start" ran.
      #expect(await waitUntil { r.isIdle })
      #expect(probe.output == ["start"])
    }

    @Test func secondDeliveryRunsAfterInstantCommand() async throws {
      // Companion to exitCallbackNeverFiresDuringInit at the CommandRunner level.
      let groups = Groups()
      defer { groups.killAll() }
      let probe = Probe(groups)
      defer { probe.remove() }
      let r = runner(probe.prelude + #"echo "$DOCK_BADGES_REASON" >> "\#(probe.outFile.path)""#)
      for i in 0..<10 {
        r.submit(Delivery(snapshot: ["A": "\(i)"], changed: ["A": "\(i)"], reason: .change))
        #expect(await waitUntil { r.isIdle })
      }
      #expect(probe.output.count == 10)
    }

    @Test func nonZeroExitLeavesRunnerUsable() async throws {
      // A command that fails (here: exec of a missing binary inside the shell) must be logged and
      // must not wedge the runner. (A failure of posix_spawn itself is not reachable while /bin/sh
      // exists and stays untested.)
      let groups = Groups()
      defer { groups.killAll() }
      let probe = Probe(groups)
      defer { probe.remove() }
      let r = runner(
        probe.prelude
          + #"echo "$DOCK_BADGES_REASON" >> "\#(probe.outFile.path)"; /nonexistent/binary"#)
      r.submit(Delivery(snapshot: [:], changed: [:], reason: .start))
      #expect(await waitUntil { r.isIdle })
      r.submit(Delivery(snapshot: ["A": "1"], changed: ["A": "1"], reason: .change))
      #expect(await waitUntil { r.isIdle })
      #expect(probe.output == ["start", "change"])
    }
  }
}
