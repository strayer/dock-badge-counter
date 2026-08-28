import Testing

@testable import dock_badge_counter

@Suite struct DeliveryTests {
  @Test func diffReportsAddedChangedAndRemoved() {
    let old = ["Mail": "3", "Slack": "12", "Gone": "1"]
    let new = ["Mail": "3", "Slack": "13", "New": "•"]
    #expect(Delivery.diff(old: old, new: new) == ["Slack": "13", "New": "•", "Gone": ""])
  }

  @Test func diffIsEmptyForIdenticalSnapshots() {
    #expect(Delivery.diff(old: ["A": "1"], new: ["A": "1"]) == [:])
    #expect(Delivery.diff(old: [:], new: [:]) == [:])
  }

  @Test func diffTreatsEmptyValueAndMissingKeyAsDifferent() {
    // include_empty mode: "" present vs. key absent must still be detected when the app disappears.
    #expect(Delivery.diff(old: ["A": ""], new: [:]) == ["A": ""])
    #expect(Delivery.diff(old: [:], new: ["A": ""]) == ["A": ""])
  }

  @Test func mergeKeepsNewestSnapshotAndAccumulatesChanges() {
    let first = Delivery(snapshot: ["A": "1", "B": "2"], changed: ["A": "1"], reason: .change)
    let second = Delivery(snapshot: ["A": "1", "B": "3"], changed: ["B": "3"], reason: .change)
    let merged = first.merged(with: second)
    #expect(merged.snapshot == ["A": "1", "B": "3"])
    #expect(merged.changed == ["A": "1", "B": "3"])
    #expect(merged.reason == .change)
  }

  /// change > start > heartbeat, in both merge directions.
  @Test(arguments: [
    (FireReason.change, FireReason.change, FireReason.change),
    (.change, .start, .change), (.start, .change, .change),
    (.change, .heartbeat, .change), (.heartbeat, .change, .change),
    (.start, .start, .start),
    (.start, .heartbeat, .start), (.heartbeat, .start, .start),
    (.heartbeat, .heartbeat, .heartbeat),
  ])
  func mergeReasonPriority(older: FireReason, newer: FireReason, expected: FireReason) {
    let a = Delivery(snapshot: ["A": "1"], changed: [:], reason: older)
    let b = Delivery(snapshot: ["A": "1"], changed: [:], reason: newer)
    #expect(a.merged(with: b).reason == expected)
  }

  @Test func mergeCarriesFinalValueForAppChangedTwice() {
    let pending = Delivery(snapshot: ["A": "2"], changed: ["A": "2"], reason: .change)
    let newer = Delivery(snapshot: ["A": "1"], changed: ["A": "1"], reason: .change)
    #expect(pending.merged(with: newer).changed == ["A": "1"])
  }

  @Test func mergeKeepsRemovalRecordedWhilePending() {
    let pending = Delivery(snapshot: ["A": "2", "B": "1"], changed: ["A": "2"], reason: .change)
    let newer = Delivery(snapshot: ["A": "2"], changed: ["B": ""], reason: .change)
    #expect(pending.merged(with: newer).changed == ["A": "2", "B": ""])
  }

  @Test func pauseStateRequiresAllReasonsToClear() {
    var state = PauseState()
    #expect(!state.isPaused)
    let lockedTransition = state.add(.screenLocked)
    #expect(lockedTransition)
    let sleepTransition = state.add(.sleep)
    #expect(!sleepTransition)  // already paused: no transition
    let wakeTransition = state.remove(.sleep)
    #expect(!wakeTransition)  // still locked
    #expect(state.isPaused)
    let unlockTransition = state.remove(.screenLocked)
    #expect(unlockTransition)
    #expect(!state.isPaused)
    let repeated = state.remove(.screenLocked)
    #expect(!repeated)  // idempotent
  }

  @Test func jsonIsSortedCompactAndUnescaped() throws {
    // The wire format consumers script against: deterministic key order, no escaped slashes,
    // non-ASCII badge glyphs and "99+" verbatim.
    let json = try JSON.encode(["Zen": "•", "App/Two": "99+", "Mail": "3"])
    #expect(json == #"{"App/Two":"99+","Mail":"3","Zen":"•"}"#)
    #expect(try JSON.encode([:]) == "{}")
  }
}
