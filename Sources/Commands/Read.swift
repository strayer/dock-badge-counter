import ArgumentParser
import Foundation

struct Read: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Print the current Dock badges as JSON once (default)."
  )

  @Flag(name: .customLong("include-empty"), help: "Include applications that do not have a badge.")
  var includeEmpty = false

  func run() throws {
    let reader = BadgeReader(includeEmpty: includeEmpty)
    do {
      if !BadgeReader.isTrusted(prompt: true) {
        throw DockBadgeError.accessibilityPermissionDenied
      }
      print(try JSON.encode(try reader.read()))
    } catch {
      let payload =
        (try? JSON.encode(["error": error.localizedDescription])) ?? "{\"error\":\"unknown\"}"
      FileHandle.standardError.write(Data((payload + "\n").utf8))
      throw ExitCode.failure
    }
  }
}
