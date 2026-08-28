import AppKit
import ApplicationServices
import Foundation

/// A snapshot of Dock badges: app name -> badge text ("" when `includeEmpty` is set and no badge is shown).
typealias BadgeSnapshot = [String: String]

enum DockBadgeError: Error, LocalizedError {
  case accessibilityPermissionDenied
  case dockProcessNotFound
  case dockStructureUnexpected
  case noAppListFound
  case jsonEncodingFailed(Error)

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
    case .jsonEncodingFailed(let error):
      return "Failed to encode JSON: \(error.localizedDescription)"
    }
  }
}

/// Reads badge labels from the Dock via the Accessibility API.
///
/// One `read()` is a full walk of the Dock's app list (~1 ms for ~20 icons). The Dock does not emit
/// accessibility notifications for badge changes, so polling is the only option.
struct BadgeReader {
  private static let dockBundleID = "com.apple.dock"
  private static let badgeAttribute = "AXStatusLabel"
  private static let handoffSubrole = "AXHandoffDockItem"

  let includeEmpty: Bool
  /// Upper bound for a single AX request, so a busy Dock can't stall the caller.
  let messagingTimeout: Float

  init(includeEmpty: Bool, messagingTimeout: Float = 1.0) {
    self.includeEmpty = includeEmpty
    self.messagingTimeout = messagingTimeout
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
    guard let elements = children(of: dockElement) else {
      throw DockBadgeError.dockStructureUnexpected
    }
    // The app list is the first child of the Dock's AX tree.
    guard let appList = elements.first else {
      throw DockBadgeError.noAppListFound
    }
    if let role = attribute(appList, kAXRoleAttribute) as? String, role != kAXListRole as String {
      throw DockBadgeError.dockStructureUnexpected
    }
    return collectBadges(from: children(of: appList) ?? [])
  }

  private func collectBadges(from icons: [AXUIElement]) -> BadgeSnapshot {
    var snapshot: BadgeSnapshot = [:]
    for icon in icons {
      autoreleasepool {
        guard let (appName, badgeText) = readIconBadge(from: icon) else { return }
        if !badgeText.isEmpty {
          snapshot[appName] = badgeText
        } else if includeEmpty {
          snapshot[appName] = ""
        }
      }
    }
    return snapshot
  }

  private func readIconBadge(from icon: AXUIElement) -> (String, String)? {
    guard let appName = attribute(icon, kAXTitleAttribute) as? String, !appName.isEmpty else {
      return nil
    }
    // Skip Handoff items from other devices.
    if let subrole = attribute(icon, kAXSubroleAttribute) as? String,
      subrole == BadgeReader.handoffSubrole
    {
      return nil
    }
    let badge = attribute(icon, BadgeReader.badgeAttribute) as? String ?? ""
    return (appName, badge)
  }

  private func children(of element: AXUIElement) -> [AXUIElement]? {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement]
  }

  private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value
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
      throw DockBadgeError.jsonEncodingFailed(error)
    }
  }
}
