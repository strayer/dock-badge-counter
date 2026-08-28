import Foundation

/// Why a snapshot is being delivered.
enum FireReason: String {
  case start, change, heartbeat
}

/// One unit of work for the `on_change` command / stdout: the full snapshot plus what changed.
struct Delivery: Equatable {
  var snapshot: BadgeSnapshot
  var changed: BadgeSnapshot
  var reason: FireReason

  /// Keys whose value differs; keys that disappeared are reported with an empty value.
  static func diff(old: BadgeSnapshot, new: BadgeSnapshot) -> BadgeSnapshot {
    var changed: BadgeSnapshot = [:]
    for (app, badge) in new where old[app] != badge { changed[app] = badge }
    for app in old.keys where new[app] == nil { changed[app] = "" }
    return changed
  }

  /// Coalesces a delivery that could not be sent yet with a newer one: the newest snapshot wins,
  /// every app that changed in either delivery is reported with its final value, and `change`
  /// outranks `start`, which outranks `heartbeat`.
  func merged(with newer: Delivery) -> Delivery {
    var changed: BadgeSnapshot = [:]
    for app in Set(self.changed.keys).union(newer.changed.keys) {
      changed[app] = newer.snapshot[app] ?? ""
    }
    let reason: FireReason
    switch (self.reason, newer.reason) {
    case (.change, _), (_, .change): reason = .change
    case (.start, _), (_, .start): reason = .start
    default: reason = .heartbeat
    }
    return Delivery(snapshot: newer.snapshot, changed: changed, reason: reason)
  }
}

/// Why polling is currently suspended. Several reasons can be active at once (lock, then sleep);
/// polling resumes only when the last one clears.
enum PauseReason: String, Hashable {
  case sleep, screenLocked
}

struct PauseState: Equatable {
  private(set) var reasons: Set<PauseReason> = []
  var isPaused: Bool { !reasons.isEmpty }

  /// Returns `true` when this call changed the paused state.
  @discardableResult
  mutating func add(_ reason: PauseReason) -> Bool {
    let was = isPaused
    reasons.insert(reason)
    return was != isPaused
  }

  /// Returns `true` when this call resumed polling (the last reason was cleared).
  @discardableResult
  mutating func remove(_ reason: PauseReason) -> Bool {
    let was = isPaused
    reasons.remove(reason)
    return was != isPaused
  }
}

/// Monotonic seconds, unaffected by wall-clock adjustments.
func monotonicNow() -> Double {
  Double(DispatchTime.now().uptimeNanoseconds) / 1e9
}
