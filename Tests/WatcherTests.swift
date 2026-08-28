import Foundation
import Testing

@testable import dock_badge_counter

/// Drives the Watcher's polling state machine directly: scripted Dock reads, a manual clock,
/// a manual permission switch and a recording sink. No timer, no run loop, no OS.
@MainActor
private final class Harness {
  var reads: [Result<BadgeSnapshot, DockBadgeError>] = []
  var clock = 1000.0
  var trusted = true
  var deliveries: [Delivery] = []
  private(set) var permissionChecks = 0
  let watcher: Watcher

  struct UnscriptedRead: Error {}

  init(configure: (inout WatchConfig) -> Void = { _ in }) {
    var config = WatchConfig()
    configure(&config)
    var box: Harness?
    watcher = Watcher(
      config: config,
      readSnapshot: { try box!.nextRead() },
      now: { box!.clock },
      isTrusted: { _ in
        box!.permissionChecks += 1
        return box!.trusted
      },
      sink: { box!.deliveries.append($0) })
    box = self
  }

  private func nextRead() throws -> BadgeSnapshot {
    guard !reads.isEmpty else {
      // Fail the test rather than crash the whole run. The watcher treats the thrown error as a
      // transient read failure, so the recorded issue is what makes this visible.
      Issue.record("the watcher read the Dock although no read was scripted")
      throw UnscriptedRead()
    }
    return try reads.removeFirst().get()
  }

  /// Scripts one successful read and polls.
  func poll(_ snapshot: BadgeSnapshot) {
    reads.append(.success(snapshot))
    watcher.poll()
  }

  func poll(failing error: DockBadgeError) {
    reads.append(.failure(error))
    watcher.poll()
  }

  var reasons: [FireReason] { deliveries.map(\.reason) }
}

@MainActor
@Suite struct WatcherTests {
  @Test func firstPollDeliversStartWithFullSnapshotAsDiff() {
    let h = Harness()
    h.poll(["Mail": "3"])
    #expect(
      h.deliveries == [Delivery(snapshot: ["Mail": "3"], changed: ["Mail": "3"], reason: .start)])
  }

  @Test func firstPollIsSilentWithoutRunOnStart() {
    let h = Harness { $0.runOnStart = false }
    h.poll(["Mail": "3"])
    #expect(h.deliveries.isEmpty)
    // ...but it still establishes the baseline for diffs.
    h.poll(["Mail": "4"])
    #expect(
      h.deliveries == [Delivery(snapshot: ["Mail": "4"], changed: ["Mail": "4"], reason: .change)])
  }

  @Test func changesDeliverDiffAndUnchangedPollsAreSilent() {
    let h = Harness()
    h.poll(["Mail": "3", "Slack": "1"])
    h.poll(["Mail": "3", "Slack": "1"])
    h.poll(["Mail": "3", "Slack": "1"])
    #expect(h.reasons == [.start])

    h.poll(["Mail": "5"])
    #expect(
      h.deliveries.last
        == Delivery(snapshot: ["Mail": "5"], changed: ["Mail": "5", "Slack": ""], reason: .change))

    h.poll(["Mail": "5", "Slack": "2"])
    #expect(h.deliveries.last?.changed == ["Slack": "2"])
    #expect(h.reasons == [.start, .change, .change])
  }

  @Test func heartbeatIsMeasuredFromTheFirstAcceptedSnapshot() {
    // Regression: with run_on_start = false the baseline used to be "distant past", so the first
    // heartbeat fired on the very next poll.
    let h = Harness {
      $0.runOnStart = false
      $0.heartbeat = 60
    }
    h.poll(["A": "1"])  // t = 1000, baseline established, nothing delivered
    h.clock += 30
    h.poll(["A": "1"])
    #expect(h.deliveries.isEmpty)
    h.clock += 30  // t = 1060: exactly 60 s since baseline
    h.poll(["A": "1"])
    #expect(h.deliveries == [Delivery(snapshot: ["A": "1"], changed: [:], reason: .heartbeat)])

    // Heartbeat timer restarts after every delivery, including a change.
    h.clock += 10
    h.poll(["A": "2"])
    #expect(h.reasons == [.heartbeat, .change])
    h.clock += 59
    h.poll(["A": "2"])
    #expect(h.reasons == [.heartbeat, .change])
    h.clock += 1
    h.poll(["A": "2"])
    #expect(h.reasons == [.heartbeat, .change, .heartbeat])
  }

  @Test func heartbeatDisabledByDefault() {
    let h = Harness()
    h.poll(["A": "1"])
    h.clock += 100_000
    h.poll(["A": "1"])
    #expect(h.reasons == [.start])
  }

  @Test func transientErrorKeepsPreviousSnapshotAndDiffsAgainstIt() {
    // Regression class: a Dock hiccup must not look like "all badges removed" and then "all added".
    let h = Harness()
    h.poll(["Mail": "3", "Slack": "1"])
    h.poll(failing: .accessibilityError(.cannotComplete))
    h.poll(failing: .dockStructureUnexpected)
    h.poll(failing: .noAppListFound)
    #expect(h.reasons == [.start])

    h.poll(["Mail": "3", "Slack": "1"])
    #expect(h.reasons == [.start], "identical snapshot after errors is not a change")

    h.poll(["Mail": "4", "Slack": "1"])
    #expect(h.deliveries.last?.changed == ["Mail": "4"])
  }

  @Test func transientErrorBeforeFirstSnapshotDelaysStart() {
    let h = Harness()
    h.poll(failing: .accessibilityError(.cannotComplete))
    #expect(h.deliveries.isEmpty)
    h.poll(["A": "1"])
    #expect(h.reasons == [.start])
  }

  @Test func permissionRevokedFallsBackToRetryLoopAndRecovers() {
    let h = Harness()
    // The watcher starts untrusted (run() normally resolves this); the first tick flips it and polls.
    h.reads.append(.success(["A": "1"]))
    h.watcher.tick()
    #expect(h.watcher.trusted)
    #expect(h.reasons == [.start])

    h.poll(failing: .accessibilityPermissionDenied)
    #expect(!h.watcher.trusted)
    #expect(h.watcher.currentInterval == Watcher.permissionRetryInterval)
    #expect(h.reasons == [.start], "no delivery on permission loss")

    // While untrusted, ticks don't read the Dock at all (no scripted read is consumed).
    h.trusted = false
    h.watcher.tick()
    h.watcher.tick()
    #expect(h.reads.isEmpty)

    // Permission comes back: the next tick flips to trusted, reschedules at the normal interval
    // and polls immediately, diffing against the snapshot from before the outage.
    h.trusted = true
    h.reads.append(.success(["A": "2"]))
    h.watcher.tick()
    #expect(h.watcher.trusted)
    #expect(h.watcher.currentInterval == 1.0)
    #expect(h.deliveries.last?.changed == ["A": "2"])
  }

  @Test func tickSkipsPollingWhilePausedAndResumePollsImmediately() {
    let h = Harness()
    h.reads.append(.success(["A": "1"]))
    h.watcher.tick()  // untrusted → trusted flip consumes the read
    #expect(h.reasons == [.start])

    h.watcher.handlePause(reason: .screenLocked, pausing: true, source: "test")
    h.watcher.tick()
    h.watcher.tick()
    #expect(h.reads.isEmpty, "no reads while paused")
    #expect(h.watcher.pause.isPaused)

    // Lock → sleep → wake: still locked, so still no polling.
    h.watcher.handlePause(reason: .sleep, pausing: true, source: "test")
    h.watcher.handlePause(reason: .sleep, pausing: false, source: "test")
    #expect(h.watcher.pause.isPaused)
    h.watcher.tick()
    #expect(h.deliveries.count == 1)

    // Unlock resumes with an immediate poll (not waiting for the next tick).
    h.reads.append(.success(["A": "2"]))
    h.watcher.handlePause(reason: .screenLocked, pausing: false, source: "test")
    #expect(h.reads.isEmpty)
    #expect(h.deliveries.last?.changed == ["A": "2"])
  }

  @Test func resumeWhileUntrustedDoesNotPoll() {
    let h = Harness()
    h.trusted = false
    h.watcher.handlePause(reason: .sleep, pausing: true, source: "test")
    h.watcher.handlePause(reason: .sleep, pausing: false, source: "test")
    #expect(h.deliveries.isEmpty)
  }

  @Test func changeWinsOverSimultaneouslyDueHeartbeat() {
    let h = Harness { $0.heartbeat = 10 }
    h.poll(["A": "1"])
    h.clock += 10
    h.poll(["A": "2"])
    #expect(h.reasons == [.start, .change])
    #expect(h.deliveries.last?.changed == ["A": "2"])
  }

  @Test func transientErrorsDoNotResetHeartbeatBaseline() {
    let h = Harness { $0.heartbeat = 10 }
    h.poll(["A": "1"])  // t = 1000
    h.clock += 6
    h.poll(failing: .accessibilityError(.cannotComplete))
    h.clock += 6  // t = 1012: deadline passed during the outage
    h.poll(["A": "1"])
    #expect(h.reasons == [.start, .heartbeat])
  }

  @Test func regainingPermissionWhilePausedDoesNotRead() {
    let h = Harness()
    h.trusted = false
    h.watcher.tick()
    #expect(!h.watcher.trusted)
    h.watcher.handlePause(reason: .sleep, pausing: true, source: "test")
    h.trusted = true
    h.watcher.tick()
    #expect(h.watcher.trusted)
    #expect(h.deliveries.isEmpty)  // no read was scripted; an attempt would record an issue
  }

  @Test func resumeForInactiveReasonDoesNotPoll() {
    let h = Harness()
    h.poll(["A": "1"])
    h.watcher.handlePause(reason: .screenLocked, pausing: false, source: "test")
    h.watcher.handlePause(reason: .sleep, pausing: false, source: "test")
    #expect(h.reasons == [.start])
  }

  @Test func trustedTickPollsWithoutRecheckingPermission() {
    let h = Harness()
    h.reads.append(.success(["A": "1"]))
    h.watcher.tick()  // untrusted -> trusted: one permission check
    #expect(h.permissionChecks == 1)
    h.reads.append(.success(["A": "1"]))
    h.watcher.tick()
    h.reads.append(.success(["A": "1"]))
    h.watcher.tick()
    #expect(h.permissionChecks == 1)
    #expect(h.reads.isEmpty)
  }
}
