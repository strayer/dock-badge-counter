import Darwin
import Foundation

/// A `/bin/sh -c` child spawned into its own process group, so that terminating it also terminates
/// everything it started (pipelines, background jobs), unlike `Process.terminate()` which only
/// signals the shell.
@MainActor
final class ChildProcess {
  enum Exit: Equatable {
    case status(Int32)
    case signal(Int32)
  }

  let pid: pid_t
  private var source: DispatchSourceProcess?
  private var reaped = false
  private let onExit: (Exit) -> Void

  /// Spawns `/bin/sh -c command` with `environment`, stdin from /dev/null, stdout/stderr inherited.
  /// `onExit` is called once on the main actor after the child has been reaped.
  init(
    shellCommand command: String, environment: [String: String], onExit: @escaping (Exit) -> Void
  ) throws {
    self.onExit = onExit

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    // SETPGROUP: pgid = child's pid, so the whole tree can be signalled.
    // SETSIGDEF/SETSIGMASK: the parent ignores SIGTERM/SIGINT (it handles them via Dispatch), and
    // ignored dispositions survive exec — reset them so the child can actually be terminated.
    posix_spawnattr_setflags(
      &attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
    posix_spawnattr_setpgroup(&attr, 0)
    var allSignals = sigset_t()
    sigfillset(&allSignals)
    posix_spawnattr_setsigdefault(&attr, &allSignals)
    var noSignals = sigset_t()
    sigemptyset(&noSignals)
    posix_spawnattr_setsigmask(&attr, &noSignals)

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)

    // Explicit element types: older compilers otherwise resolve `[...].map { strdup } + [nil]`
    // against the wrong `+` overload.
    let arguments: [String] = ["/bin/sh", "-c", command]
    var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
    argv.append(nil)
    var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
    envp.append(nil)
    defer {
      for p in argv { free(p) }
      for p in envp { free(p) }
    }

    var pid: pid_t = 0
    let rc = posix_spawn(&pid, "/bin/sh", &actions, &attr, argv, envp)
    guard rc == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EINVAL)
    }
    self.pid = pid

    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
    source.setEventHandler { MainActor.assumeIsolated { self.reap(block: true) } }
    source.resume()
    self.source = source
    // The child may already have exited before the source was registered; check once without
    // blocking. Deferred to the next main-queue turn so `onExit` never fires inside `init` —
    // callers must be able to store the handle before the callback runs.
    DispatchQueue.main.async { MainActor.assumeIsolated { self.reap(block: false) } }
  }

  var isRunning: Bool { !reaped }

  /// Reaps the child now if it has already exited (delivering `onExit`), without blocking.
  /// Lets a caller that must wait synchronously do so through the owner, preserving exactly-once
  /// delivery instead of calling `waitpid` behind this object's back.
  @discardableResult
  func reapIfExited() -> Bool {
    reap(block: false)
    return reaped
  }

  /// Sends `signal` to the child's whole process group.
  func terminateGroup(_ signal: Int32 = SIGTERM) {
    guard !reaped else { return }
    Darwin.kill(-pid, signal)
  }

  private func reap(block: Bool) {
    guard !reaped else { return }
    var status: Int32 = 0
    let rc = waitpid(pid, &status, block ? 0 : WNOHANG)
    guard rc == pid else { return }  // 0 = still running (WNOHANG); -1 = error, nothing to do
    reaped = true
    source?.cancel()
    source = nil
    // Manual WIFEXITED / WIFSIGNALED: the C macros aren't importable.
    let termsig = status & 0x7f
    onExit(termsig == 0 ? .status((status >> 8) & 0xff) : .signal(termsig))
  }
}
