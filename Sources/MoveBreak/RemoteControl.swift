import AppKit
import Foundation

/// Lets a second invocation drive the already-running instance.
///
/// This exists because the menu bar is not guaranteed to be available: macOS silently
/// drops a status item when the menu bar is full (it parks the window off-screen at a
/// negative y), which leaves the app running with no way to reach it. On a narrow or
/// rotated display with a lot of status items that is the normal case, not an edge case.
///
/// Uses DistributedNotificationCenter — same-user IPC, no permissions, no port to manage.
enum RemoteControl {

    enum Command: String, CaseIterable {
        case show  = "com.mike.movebreak.show"
        case quit  = "com.mike.movebreak.quit"
        case pause = "com.mike.movebreak.pause"

        var flag: String {
            switch self {
            case .show:  return "--show"
            case .quit:  return "--quit"
            case .pause: return "--toggle-pause"
            }
        }
    }

    /// Called by the short-lived invocation: post and exit.
    static func send(_ command: Command) -> Never {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(command.rawValue),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        print("sent \(command.flag) to any running MoveBreak instance")
        exit(0)
    }

    /// Matches a command from the argument list, if present.
    static func command(in arguments: Set<String>) -> Command? {
        Command.allCases.first { arguments.contains($0.flag) }
    }

    /// Called by the long-running instance to start listening.
    static func listen(handler: @escaping (Command) -> Void) {
        for command in Command.allCases {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(command.rawValue),
                object: nil,
                queue: .main
            ) { _ in handler(command) }
        }
    }
}
