import AppKit
import Foundation

// Constants
private let kDockBundleID = "com.apple.dock"
private let kBadgeAttribute = "AXStatusLabel"
private let kEmptyJSON = "{}"

// Error types
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

struct DockBadgeCounter {
  let includeEmpty: Bool

  func run() throws {
    // Check accessibility permissions
    try checkAccessibilityPermissions()

    // Find dock element
    let dockElement = try findDockElement()

    // Read badges
    let badgeData = try readBadges(from: dockElement)

    // Output JSON
    try outputJSON(badgeData)
  }

  private func checkAccessibilityPermissions() throws {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(options)
    if !trusted {
      throw DockBadgeError.accessibilityPermissionDenied
    }
  }

  private func findDockElement() throws -> AXUIElement {
    guard
      let dock = NSRunningApplication.runningApplications(withBundleIdentifier: kDockBundleID).first
    else {
      throw DockBadgeError.dockProcessNotFound
    }

    return AXUIElementCreateApplication(dock.processIdentifier)
  }

  private func readBadges(from dockElement: AXUIElement) throws -> [String: String] {
    var badgeData: [String: String] = [:]

    // Get the list of UI elements in the Dock
    var children: AnyObject?
    let result = AXUIElementCopyAttributeValue(
      dockElement, kAXChildrenAttribute as CFString, &children)

    if result == .success, let elements = children as? [AXUIElement] {
      // The app list is typically the first child
      guard let appList = elements.first else {
        throw DockBadgeError.noAppListFound
      }

      // Verify it's actually a list
      try verifyAppList(appList)

      // Process all icons
      let icons = try getIcons(from: appList)
      badgeData = collectBadges(from: icons)
    }

    return badgeData
  }

  private func verifyAppList(_ appList: AXUIElement) throws {
    var role: AnyObject?
    let roleResult = AXUIElementCopyAttributeValue(appList, kAXRoleAttribute as CFString, &role)
    if roleResult == .success {
      if (role as? String) != kAXListRole as String {
        throw DockBadgeError.dockStructureUnexpected
      }
    }
  }

  private func getIcons(from appList: AXUIElement) throws -> [AXUIElement] {
    var appIcons: AnyObject?
    if AXUIElementCopyAttributeValue(appList, kAXChildrenAttribute as CFString, &appIcons)
      == .success,
      let icons = appIcons as? [AXUIElement]
    {
      return icons
    }
    return []
  }

  private func collectBadges(from icons: [AXUIElement]) -> [String: String] {
    var badgeData: [String: String] = [:]

    for icon in icons {
      autoreleasepool {
        if let (appName, badgeText) = readIconBadge(from: icon) {
          if !badgeText.isEmpty {
            badgeData[appName] = badgeText
          } else if includeEmpty {
            badgeData[appName] = ""
          }
        }
      }
    }

    return badgeData
  }

  private func readIconBadge(from icon: AXUIElement) -> (String, String)? {
    // Get title
    var title: AnyObject?
    let titleResult = AXUIElementCopyAttributeValue(icon, kAXTitleAttribute as CFString, &title)

    guard titleResult == .success, let appName = title as? String, !appName.isEmpty else {
      return nil
    }

    // Get badge
    var badge: AnyObject?
    let badgeResult = AXUIElementCopyAttributeValue(icon, kBadgeAttribute as CFString, &badge)

    if badgeResult == .success, let badgeText = badge as? String {
      return (appName, badgeText)
    }

    return (appName, "")
  }

  private func outputJSON(_ badgeData: [String: String]) throws {
    do {
      let jsonData = try JSONEncoder().encode(badgeData)
      FileHandle.standardOutput.write(jsonData)
      print()  // Add newline
    } catch {
      throw DockBadgeError.jsonEncodingFailed(error)
    }
  }
}

// Entry point
func main() {
  // Handle help flag
  if CommandLine.arguments.contains("--help") {
    print(
      """
      dock-badge-counter - Read notification badges from macOS Dock

      Usage: dock-badge-counter [--include-empty]

      Options:
        --include-empty    Include apps without badges in output
        --help            Show this help message
      """)
    exit(0)
  }

  // Parse arguments
  let includeEmpty = CommandLine.arguments.contains("--include-empty")

  // Create and run counter
  let counter = DockBadgeCounter(includeEmpty: includeEmpty)

  do {
    try counter.run()
    exit(0)
  } catch {
    print("{\"error\": \"\(error.localizedDescription)\"}")
    exit(1)
  }
}

// Run the main function
main()
