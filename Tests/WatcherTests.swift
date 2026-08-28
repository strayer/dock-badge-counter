import Foundation
import Testing

@testable import dock_badge_counter

/// Scripted inputs and recorded outputs for a Watcher under test. Created before the Watcher so
/// the injected closures never capture an uninitialized harness.
@MainActor
private final class Script {
  var reads: [Result<BadgeSnapshot, DockBadgeError>] = []
  var clock = 1000.0
  var trusted = true
  var deliveries: [Delivery] = []

  struct UnscriptedRead: Error {}

  func nextRead() throws -> BadgeSnapshot {
    guard !reads.isEmpty else {
      // Fail the test rather than crash the whole run. The watcher treats the thrown error as a
      // transient read failure, so the recorded issue is what makes this visible.
      Issue.record("the watcher read the Dock although no read was scripted")
      throw UnscriptedRead()
    }
    return try reads.removeFirst().get()
  }
}

/// Drives the Watcher's polling state machine directly: scripted Dock reads, a manual clock,
/// a manual permission switch and a recording sink. No timer, no run loop, no OS.
@MainActor
private final class Harness {
  let script = Script()
  let watcher: Watcher

  init(configure: (inout WatchConfig) -> Void = { _ in }) {
    var config = WatchConfig()
    configure(&config)
    let script = self.script
    watcher = Watcher(
      config: config,
      readSnapshot: { try script.nextRead() },
      now: { script.clock },
      isTrusted: { _ in script.trusted },
      sink: { script.deliveries.append($0) })
  }

  var clock: Double {
    get { script.clock }
    set { script.clock = newValue }
  }
  var trusted: Bool {
    get { script.trusted }
    set { script.trusted = newValue }
  }
  var deliveries: [Delivery] { script.deliveries }
  var reasons: [FireReason] { deliveries.map(\.reason) }
  var unreadScriptedReads: Int { script.reads.count }

  /// Scripts one successful read and polls.
  func poll(_ snapshot: BadgeSnapshot) {
    script.reads.append(.success(snapshot))
    watcher.poll()
  }

  func poll(failing error: DockBadgeError) {
    script.reads.append(.failure(error))
    watcher.poll()
  }

  /// Scripts a read that must NOT be consumed until the test says so.
  func queue(_ snapshot: BadgeSnapshot) {
    script.reads.append(.success(snapshot))
  }

  /// Makes the watcher trusted (as `run()` would) by ticking once with a scripted read.
  func grantAndTick(_ snapshot: BadgeSnapshot) {
    script.trusted = true
    queue(snapshot)
    watcher.tick()
  }
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

  @Test func changeWinsOverSimultaneouslyDueHeartbeat() {
    let h = Harness { $0.heartbeat = 10 }
    h.poll(["A": "1"])
    h.clock += 10
    h.poll(["A": "2"])
    #expect(h.reasons == [.start, .change])
    #expect(h.deliveries.last?.changed == ["A": "2"])
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

  @Test func transientErrorsDoNotResetHeartbeatBaseline() {
    let h = Harness { $0.heartbeat = 10 }
    h.poll(["A": "1"])  // t = 1000
    h.clock += 6
    h.poll(failing: .accessibilityError(.cannotComplete))
    h.clock += 6  // t = 1012: deadline passed during the outage
    h.poll(["A": "1"])
    #expect(h.reasons == [.start, .heartbeat])
  }

  @Test func permissionRevokedStopsReadingAndRecoveryDiffsAgainstOldSnapshot() {
    let h = Harness()
    h.grantAndTick(["A": "1"])
    #expect(h.reasons == [.start])

    h.poll(failing: .accessibilityPermissionDenied)
    #expect(h.reasons == [.start], "no delivery on permission loss")

    // While denied, ticks must not touch the Dock: the queued read stays unconsumed.
    h.trusted = false
    h.queue(["A": "2"])
    h.watcher.tick()
    h.watcher.tick()
    #expect(h.unreadScriptedReads == 1)
    #expect(h.reasons == [.start])

    // Permission comes back: the next tick polls immediately and diffs against the snapshot from
    // before the outage.
    h.trusted = true
    h.watcher.tick()
    #expect(h.unreadScriptedReads == 0)
    #expect(h.deliveries.last?.changed == ["A": "2"])
  }

  @Test func untrustedTicksDoNotReadUntilGranted() {
    let h = Harness()
    h.trusted = false
    h.queue(["A": "1"])
    h.watcher.tick()
    h.watcher.tick()
    #expect(h.unreadScriptedReads == 1)
    h.trusted = true
    h.watcher.tick()
    #expect(h.unreadScriptedReads == 0)
    #expect(h.reasons == [.start])
  }

  @Test func pausedTicksDoNotReadAndUnlockPollsImmediately() {
    let h = Harness()
    h.grantAndTick(["A": "1"])
    #expect(h.reasons == [.start])

    h.queue(["A": "2"])
    h.watcher.handlePause(reason: .screenLocked, pausing: true, source: "test")
    h.watcher.tick()
    h.watcher.tick()
    #expect(h.unreadScriptedReads == 1, "no reads while paused")

    // Lock → sleep → wake: still locked, so still no polling.
    h.watcher.handlePause(reason: .sleep, pausing: true, source: "test")
    h.watcher.handlePause(reason: .sleep, pausing: false, source: "test")
    h.watcher.tick()
    #expect(h.unreadScriptedReads == 1)

    // Unlock resumes with an immediate poll (not waiting for the next tick).
    h.watcher.handlePause(reason: .screenLocked, pausing: false, source: "test")
    #expect(h.unreadScriptedReads == 0)
    #expect(h.deliveries.last?.changed == ["A": "2"])
  }

  @Test func resumeWhileUntrustedDoesNotPoll() {
    let h = Harness()
    h.trusted = false
    h.queue(["A": "1"])
    h.watcher.handlePause(reason: .sleep, pausing: true, source: "test")
    h.watcher.handlePause(reason: .sleep, pausing: false, source: "test")
    #expect(h.unreadScriptedReads == 1)
    #expect(h.deliveries.isEmpty)
  }

  @Test func regainingPermissionWhilePausedDoesNotReadUntilResumed() {
    let h = Harness()
    h.trusted = false
    h.watcher.tick()
    h.watcher.handlePause(reason: .sleep, pausing: true, source: "test")
    h.trusted = true
    h.queue(["A": "1"])
    h.watcher.tick()  // becomes trusted, but paused: must not read
    #expect(h.unreadScriptedReads == 1)
    h.watcher.handlePause(reason: .sleep, pausing: false, source: "test")
    #expect(h.unreadScriptedReads == 0)
    #expect(h.reasons == [.start])
  }

  @Test func resumeForInactiveReasonDoesNotPoll() {
    let h = Harness()
    h.poll(["A": "1"])
    h.queue(["A": "2"])
    h.watcher.handlePause(reason: .screenLocked, pausing: false, source: "test")
    h.watcher.handlePause(reason: .sleep, pausing: false, source: "test")
    #expect(h.unreadScriptedReads == 1)
    #expect(h.reasons == [.start])
  }
}
