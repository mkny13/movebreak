import AppKit
import Foundation

let rawArguments = CommandLine.arguments.dropFirst()
for arg in rawArguments {
    if arg.hasPrefix("--token") || arg.hasPrefix("--secret") || arg.hasPrefix("--notion-token") || arg.hasPrefix("--api-key") {
        FileHandle.standardError.write(Data("error: secrets must not be provided via command-line arguments. Use --configure-notion for secure interactive setup.\n".utf8))
        exit(1)
    }
}
let arguments = Set(rawArguments)

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    MoveBreak — prompts you to move when you enter a meeting or start watching a video.

      --diagnose   Print live detection state (audio streams, browser tabs, verdict)
                   instead of launching the app. Use this to validate detection.
                   Add --verbose for full URLs instead of host-level summary.
      --self-test  Run the video-vs-music classification cases and exit.
      --tabs       Show what your browsers have open and how it would classify.
                   Add --verbose for full URLs instead of hosts.
      --demo          Launch and show the prompt immediately.
      --demo-pt       Launch and show the PT checklist immediately.
      --demo-builder  Launch and show the routine editor immediately.

      --configure-notion  Set up Notion session logging (integration token + database ID).

    Control an already-running instance (works when the menu bar is full and the
    status item cannot be shown):

      --show          Show the prompt right now.
      --toggle-pause  Pause or resume detection.
      --quit          Quit the running instance.

      --status-check      Report whether the status item got a slot in the menu bar.
      --version           Print the current version and exit.
      --check-update-now  Check GitHub for a newer release right now and exit.
      --help              Show this message.
    """)
    exit(0)
}

if arguments.contains("--version") {
    print(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")
    exit(0)
}

if arguments.contains("--check-update-now") {
    var finished = false
    Updater.shared.checkForUpdate {
        finished = true
    }
    let deadline = Date().addingTimeInterval(30)
    while !finished && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    exit(0)
}

if let command = RemoteControl.command(in: arguments) {
    RemoteControl.send(command)
}

if arguments.contains("--self-test") {
    SelfTest.run()
}

if arguments.contains("--tabs") {
    TabProbe.run(verbose: arguments.contains("--verbose"))
}

if arguments.contains("--diagnose") {
    Diagnose.run(verbose: arguments.contains("--verbose"))
}

if arguments.contains("--configure-notion") {
    NotionSetup.run()
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Menu-bar only: no Dock icon, never steals focus from the meeting you're in.
application.setActivationPolicy(.accessory)
application.run()
