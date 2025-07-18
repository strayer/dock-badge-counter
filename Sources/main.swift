// Save this code as get_badges.swift

import Foundation
import AppKit // Using AppKit gives us access to NSRunningApplication and Accessibility

// --- Command Line Arguments ---
var includeEmpty = false

// Parse command line arguments
for argument in CommandLine.arguments {
    if argument == "--include-empty" {
        includeEmpty = true
    }
}

// --- Main Logic ---

var badgeData: [String: String] = [:]

// 1. Find the Dock's process identifier (PID).
guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
    // If Dock isn't running, print an empty JSON object and exit.
    print("{}")
    exit(0)
}

// 2. Create an accessibility element for the Dock application.
let dockElement = AXUIElementCreateApplication(dock.processIdentifier)

// 3. Get the list of UI elements in the Dock. The main list of apps is usually the first child list.
var children: AnyObject?
let result = AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &children)

if result == .success, let elements = children as? [AXUIElement] {
    // Find the list element that contains the app icons.
    if let appList = elements.first(where: {
        var role: AnyObject?
        AXUIElementCopyAttributeValue($0, kAXRoleAttribute as CFString, &role)
        return (role as? String) == kAXListRole as String
    }) {
        // 4. Get all the icons from within that list.
        var appIcons: AnyObject?
        if AXUIElementCopyAttributeValue(appList, kAXChildrenAttribute as CFString, &appIcons) == .success,
           let icons = appIcons as? [AXUIElement] {
            
            // 5. Iterate over each icon to find its title and badge.
            for icon in icons {
                var title: AnyObject?
                var badge: AnyObject?
                
                // Get the app's title (e.g., "WhatsApp")
                AXUIElementCopyAttributeValue(icon, kAXTitleAttribute as CFString, &title)
                
                if let appName = title as? String, !appName.isEmpty {
                    // Get the badge for this app
                    // The attribute is officially called "AXStatusLabel".
                    let badgeResult = AXUIElementCopyAttributeValue(icon, "AXStatusLabel" as CFString, &badge)
                    
                    if badgeResult == .success, let badgeText = badge as? String, !badgeText.isEmpty {
                        // We found a badge!
                        badgeData[appName] = badgeText
                    } else if includeEmpty {
                        // No badge or it's empty, but we want to include empty badges
                        badgeData[appName] = ""
                    }
                    // If includeEmpty is false and there's no badge, we skip this app
                }
            }
        }
    }
}

// 6. Encode the final dictionary to JSON and print it.
do {
    let jsonData = try JSONEncoder().encode(badgeData)
    if let jsonString = String(data: jsonData, encoding: .utf8) {
        print(jsonString)
    } else {
        print("{}")
    }
} catch {
    print("{\"error\": \"Failed to encode JSON\"}")
}