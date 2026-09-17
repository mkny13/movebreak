import Darwin
import Foundation

struct ProcessResult {
    /// A stable status for failures where no child exit status is available.
    static let unavailableExitCode: Int32 = -1

    let exitCode: Int32
    let timedOut: Bool
    let stdout: String
    let stderr: String

    var isSuccess: Bool { !timedOut && exitCode == 0 }
}

/// Runs a child process while continuously draining both output pipes.
///
/// Pipe reads are nonblocking and serialized on the calling thread. This avoids both
/// the back-pressure deadlock caused by waiting for a noisy child and the lifetime
/// races caused by `FileHandle.readabilityHandler` callbacks outliving a result.
struct ProcessRunner {
    static let shared = ProcessRunner()

    let terminationGracePeriod: TimeInterval
    let forceKillGracePeriod: TimeInterval
    let pollIntervalMicroseconds: useconds_t

    init(
        terminationGracePeriod: TimeInterval = 2.0,
        forceKillGracePeriod: TimeInterval = 1.0,
        pollIntervalMicroseconds: useconds_t = 5_000
    ) {
        self.terminationGracePeriod = max(0, terminationGracePeriod)
        self.forceKillGracePeriod = max(0, forceKillGracePeriod)
        self.pollIntervalMicroseconds = pollIntervalMicroseconds
    }

    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 30.0
    ) -> ProcessResult {
        shared.run(executable: executable, arguments: arguments, timeout: timeout)
    }

    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutRead = stdoutPipe.fileHandleForReading
        let stdoutWrite = stdoutPipe.fileHandleForWriting
        let stderrRead = stderrPipe.fileHandleForReading
        let stderrWrite = stderrPipe.fileHandleForWriting
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // This is the single ownership cleanup path, including Process.run() failure.
        defer {
            try? stdoutRead.close()
            try? stdoutWrite.close()
            try? stderrRead.close()
            try? stderrWrite.close()
        }

        do {
            try process.run()
        } catch {
            return ProcessResult(
                exitCode: ProcessResult.unavailableExitCode,
                timedOut: false,
                stdout: "",
                stderr: error.localizedDescription
            )
        }

        // Process.run() duplicates these descriptors into the child. The parent must
        // relinquish its writer copies so EOF is observable as soon as the child exits.
        try? stdoutWrite.close()
        try? stderrWrite.close()
        Self.makeNonblocking(stdoutRead.fileDescriptor)
        Self.makeNonblocking(stderrRead.fileDescriptor)

        var stdoutData = Data()
        var stderrData = Data()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let timeoutDeadline = startedAt + max(0, timeout)
        var terminationDeadline: TimeInterval?
        var forceKillDeadline: TimeInterval?
        var timedOut = false

        while process.isRunning {
            Self.drainAvailable(from: stdoutRead.fileDescriptor, into: &stdoutData)
            Self.drainAvailable(from: stderrRead.fileDescriptor, into: &stderrData)

            let now = ProcessInfo.processInfo.systemUptime
            if !timedOut, now >= timeoutDeadline {
                timedOut = true
                process.terminate()
                terminationDeadline = now + terminationGracePeriod
            } else if let deadline = terminationDeadline, now >= deadline {
                // `terminate()` is SIGTERM and may be ignored. Escalate once, then
                // retain a final bound rather than assuming SIGKILL was observed.
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                terminationDeadline = nil
                forceKillDeadline = now + forceKillGracePeriod
            } else if let deadline = forceKillDeadline, now >= deadline {
                break
            }

            if pollIntervalMicroseconds > 0 {
                usleep(pollIntervalMicroseconds)
            }
        }

        // Drain everything already written after observing exit. Reads remain
        // nonblocking, so an inherited writer in an errant descendant cannot hang us.
        Self.drainAvailable(from: stdoutRead.fileDescriptor, into: &stdoutData, chunkLimit: .max)
        Self.drainAvailable(from: stderrRead.fileDescriptor, into: &stderrData, chunkLimit: .max)

        let exitCode: Int32
        if timedOut || process.isRunning {
            // Never consult terminationStatus unless Foundation reports that the child
            // has exited. Timed-out callers receive the same result for TERM and KILL.
            exitCode = ProcessResult.unavailableExitCode
        } else {
            exitCode = process.terminationStatus
        }

        return ProcessResult(
            exitCode: exitCode,
            timedOut: timedOut,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private static func makeNonblocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    /// A per-pass limit keeps one continuously noisy stream from starving the other
    /// or delaying timeout enforcement. The final post-exit drain has no limit.
    private static func drainAvailable(
        from descriptor: Int32,
        into data: inout Data,
        chunkLimit: Int = 64
    ) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var chunksRead = 0

        while chunksRead < chunkLimit {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                chunksRead += 1
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            // EOF, EAGAIN, and permanent descriptor errors all end this drain pass.
            break
        }
    }
}
