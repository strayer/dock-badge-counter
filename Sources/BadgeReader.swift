import AppKit
import ApplicationServices
import Foundation

/// A snapshot of Dock badges: app name -> badge text ("" when `includeEmpty` is set and no badge is shown).
typealias BadgeSnapshot = [String: String]

enum DockBadgeError: Error, LocalizedError, Equatable {
  case accessibilityPermissionDenied
  case dockProcessNotFound
  case dockStructureUnexpected
  case noAppListFound
  /// A transient or unexpected Accessibility error (e.g. the Dock is restarting or busy).
  case accessibilityError(AXError)
  case jsonEncodingFailed(String)

  var errorDescription: String? {
    switch self {
    case .accessibilityPermissionDenied:
      return
        "Accessibility permissions not granted. Grant access in System Settings > Privacy & Security > Accessibility"
    case .dockProcessNotFound:
      return "Dock process not found"
    case .dockStructureUnexpected:
      return "Dock structure unexpected"
    case .noAppListFound:
      return "No app list found in Dock"
    case .accessibilityError(let code):
      return "Accessibility request failed (AXError \(code.rawValue))"
    case .jsonEncodingFailed(let message):
      return "Failed to encode JSON: \(message)"
    }
  }
}

/// Reads badge labels from the Dock via the Accessibility API.
///
/// One `read()` is a full walk of the Dock's app list (~1 ms for ~20 icons on the author's machine).
/// The Dock does not emit accessibility notifications for badge changes, so polling is the only option.
///
/// Error semantics: `read()` either returns a snapshot built entirely from successful AX replies, or
/// throws. Transient AX failures (`cannotComplete`, `invalidUIElement`, ...) are never turned into
/// "no badge", so callers can keep their previous state instead of reporting false removals.
struct BadgeReader {
  private static let dockBundleID = "com.apple.dock"
  private static let badgeAttribute = "AXStatusLabel"
  private static let applicationSubrole = "AXApplicationDockItem"

  let includeEmpty: Bool
  /// Upper bound for a single AX request, so a busy Dock can't stall the caller.
  let messagingTimeout: Float

  init(includeEmpty: Bool, messagingTimeout: Float = 1.0) {
    self.includeEmpty = includeEmpty
    self.messagingTimeout = messagingTimeout
    // The system-wide element's timeout applies to every element this process talks to.
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
  }

  /// Returns `true` when this process is trusted for Accessibility. Passing `prompt: true` shows the
  /// system dialog (once) if it is not.
  static func isTrusted(prompt: Bool) -> Bool {
    let options =
      [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  func read() throws -> BadgeSnapshot {
    guard BadgeReader.isTrusted(prompt: false) else {
      throw DockBadgeError.accessibilityPermissionDenied
    }
    let dockElement = try findDockElement()
    return try readBadges(from: dockElement)
  }

  private func findDockElement() throws -> AXUIElement {
    guard
      let dock = NSRunningApplication.runningApplications(
        withBundleIdentifier: BadgeReader.dockBundleID
      )
      .first
    else {
      throw DockBadgeError.dockProcessNotFound
    }
    let element = AXUIElementCreateApplication(dock.processIdentifier)
    AXUIElementSetMessagingTimeout(element, messagingTimeout)
    return element
  }

  private func readBadges(from dockElement: AXUIElement) throws -> BadgeSnapshot {
    guard let dockChildren = try children(of: dockElement), !dockChildren.isEmpty else {
      throw DockBadgeError.dockStructureUnexpected
    }
    // The app list is the child with role AXList (normally the first one).
    var appList: AXUIElement?
    for child in dockChildren {
      if try attribute(child, kAXRoleAttribute) as? String == kAXListRole as String {
        appList = child
        break
      }
    }
    guard let appList else { throw DockBadgeError.noAppListFound }
    return try collectBadges(from: try children(of: appList) ?? [])
  }

  private func collectBadges(from icons: [AXUIElement]) throws -> BadgeSnapshot {
    var snapshot: BadgeSnapshot = [:]
    for icon in icons {
      try autoreleasepool {
        guard let (appName, badgeText) = try readIconBadge(from: icon) else { return }
        // Keys are display titles. If two Dock items share a title, the first one wins.
        guard snapshot[appName] == nil else { return }
        if !badgeText.isEmpty {
          snapshot[appName] = badgeText
        } else if includeEmpty {
          snapshot[appName] = ""
        }
      }
    }
    return snapshot
  }

  /// Returns `nil` for Dock items that are not applications (folders, Trash, minimized windows, Handoff).
  private func readIconBadge(from icon: AXUIElement) throws -> (String, String)? {
    guard try attribute(icon, kAXSubroleAttribute) as? String == BadgeReader.applicationSubrole
    else {
      return nil
    }
    guard let appName = try attribute(icon, kAXTitleAttribute) as? String, !appName.isEmpty else {
      return nil
    }
    let badge = try attribute(icon, BadgeReader.badgeAttribute) as? String ?? ""
    return (appName, badge)
  }

  private func children(of element: AXUIElement) throws -> [AXUIElement]? {
    try attribute(element, kAXChildrenAttribute) as? [AXUIElement]
  }

  /// Returns the attribute value, `nil` when the element legitimately has no such value, and throws
  /// for every other AX error.
  private func attribute(_ element: AXUIElement, _ name: String) throws -> AnyObject? {
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    switch result {
    case .success:
      return value
    case .noValue, .attributeUnsupported:
      return nil
    case .apiDisabled, .notImplemented:
      throw DockBadgeError.accessibilityPermissionDenied
    default:
      throw DockBadgeError.accessibilityError(result)
    }
  }
}

enum JSON {
  /// Deterministic (sorted keys) compact JSON, suitable for env vars and NDJSON lines.
  static func encode(_ snapshot: BadgeSnapshot) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      return String(decoding: try encoder.encode(snapshot), as: UTF8.self)
    } catch {
      throw DockBadgeError.jsonEncodingFailed(error.localizedDescription)
    }
  }
}
