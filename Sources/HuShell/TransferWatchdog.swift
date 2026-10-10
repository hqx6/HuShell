import Foundation
import Darwin

/// A small copy of the app executable watches its parent while an SFTP transfer
/// runs. macOS does not automatically stop child processes when an app exits.
enum TransferWatchdog {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, arguments[1] == "--transfer-watchdog" else { return false }
        guard let parent = Int32(arguments[2]), let target = Int32(arguments[3]),
              parent > 1, target > 1 else { exit(1) }

        let descriptor = kqueue()
        guard descriptor >= 0 else { exit(1) }
        defer { close(descriptor) }
        var registration = kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC),
                                  flags: UInt16(EV_ADD | EV_ONESHOT), fflags: UInt32(NOTE_EXIT),
                                  data: 0, udata: nil)
        if kevent(descriptor, &registration, 1, nil, 0, nil) < 0 || kill(parent, 0) < 0 {
            // The app may have exited before the watcher registered.
            stop(target)
            exit(0)
        }
        var event = kevent()
        while true {
            let count = kevent(descriptor, nil, 0, &event, 1, nil)
            if count > 0 { break }
            if count < 0 && errno != EINTR { exit(1) }
        }
        stop(target)
        exit(0)
    }

    static func start(for transfer: Process) -> Process? {
        guard let executable = Bundle.main.executableURL,
              executable.lastPathComponent == "HuShell" else { return nil }
        let watcher = Process()
        watcher.executableURL = executable
        watcher.arguments = ["--transfer-watchdog", String(getpid()), String(transfer.processIdentifier)]
        watcher.standardInput = FileHandle.nullDevice
        watcher.standardOutput = FileHandle.nullDevice
        watcher.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment.keys.filter { $0.hasPrefix("HUSHELL_") || $0 == "SSH_ASKPASS" }
            .forEach { environment.removeValue(forKey: $0) }
        watcher.environment = environment
        do {
            try watcher.run()
            return watcher
        } catch {
            return nil
        }
    }

    private static func stop(_ pid: Int32) {
        if getpgid(pid) == pid {
            _ = kill(-pid, SIGTERM)
        } else if kill(pid, 0) == 0 {
            _ = kill(pid, SIGTERM)
        }
    }
}
