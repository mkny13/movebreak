import Foundation
import Darwin

/// Helper for reading secret input securely from the terminal.
///
/// When attached to an interactive terminal, it turns off terminal echo (`ECHO`)
/// and installs signal handlers (`SIGINT`, `SIGTERM`, `SIGHUP`, `SIGQUIT`) so that
/// if the user interrupts or an error occurs, the terminal's original settings are
/// guaranteed to be restored.
///
/// When reading from noninteractive standard input (pipes, redirected files, automated tests),
/// echo manipulation is bypassed, but the supplied value is never echoed or printed.
enum SecretInput {

    // MARK: - State for Signal Safety

    private static var savedTermios: termios? = nil
    private static var previousSigint: sig_t? = nil
    private static var previousSigterm: sig_t? = nil
    private static var previousSighup: sig_t? = nil
    private static var previousSigquit: sig_t? = nil

    private static let signalHandler: @convention(c) (Int32) -> Void = { sig in
        SecretInput.restoreTerminalState()
        signal(sig, SIG_DFL)
        raise(sig)
    }

    private static func restoreTerminalState() {
        if var term = savedTermios {
            tcsetattr(STDIN_FILENO, TCSANOW, &term)
            savedTermios = nil
        }
    }

    // MARK: - Test Hook

    static var customReader: ((String?) -> String?)? = nil

    @discardableResult
    static func withCustomReader<T>(_ reader: @escaping (String?) -> String?, perform: () throws -> T) rethrows -> T {
        let previous = customReader
        customReader = reader
        defer { customReader = previous }
        return try perform()
    }

    // MARK: - Reading Secret

    /// Reads a secret string.
    ///
    /// - Parameter prompt: The prompt message displayed before reading (printed to stdout).
    /// - Returns: The entered string (without trailing newline), or `nil` if EOF was reached.
    static func readSecret(prompt: String? = nil) -> String? {
        if let custom = customReader {
            return custom(prompt)
        }

        if let prompt = prompt, !prompt.isEmpty {
            FileHandle.standardOutput.write(Data(prompt.utf8))
        }

        let isInteractive = isatty(STDIN_FILENO) != 0

        if isInteractive {
            var original = termios()
            guard tcgetattr(STDIN_FILENO, &original) == 0 else {
                return readLine(strippingNewline: true)
            }

            savedTermios = original
            previousSigint = signal(SIGINT, signalHandler)
            previousSigterm = signal(SIGTERM, signalHandler)
            previousSighup = signal(SIGHUP, signalHandler)
            previousSigquit = signal(SIGQUIT, signalHandler)

            var raw = original
            raw.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)

            defer {
                restoreTerminalState()
                if let sigint = previousSigint { signal(SIGINT, sigint) }
                if let sigterm = previousSigterm { signal(SIGTERM, sigterm) }
                if let sighup = previousSighup { signal(SIGHUP, sighup) }
                if let sigquit = previousSigquit { signal(SIGQUIT, sigquit) }
                FileHandle.standardOutput.write(Data("\n".utf8))
            }

            return readLine(strippingNewline: true)
        } else {
            return readLine(strippingNewline: true)
        }
    }
}
