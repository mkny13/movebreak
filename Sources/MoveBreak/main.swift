import AppKit
import Foundation

let arguments = Set(CommandLine.arguments.dropFirst())

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    MoveBreak — prompts you to move when you enter a meeting or start watching a video.

      --diagnose   Print live detection state (audio streams, browser tabs, verdict)
                   instead of launching the app. Use this to validate detection.
      --self-test  Run the video-vs-music classification cases and exit.
      --tabs       Show what your browsers have open and how it would classify.
                   Add --verbose for full URLs instead of hosts.
      --demo          Launch and show the prompt immediately.
      --demo-pt       Launch and show the PT checklist immediately.
      --demo-builder  Launch and show the routine editor immediately.

    Control an already-running instance (works when the menu bar is full and the
    status item cannot be shown):

      --show          Show the prompt right now.
      --toggle-pause  Pause or resume detection.
      --quit          Quit the running instance.

      --status-check  Report whether the status item got a slot in the menu bar.
      --help          Show this message.
    """)
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
    Diagnose.run()
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Menu-bar only: no Dock icon, never steals focus from the meeting you're in.
application.setActivationPolicy(.accessory)
application.run()
