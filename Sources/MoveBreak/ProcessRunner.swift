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
    let maximumWaitInterval: TimeInterval

    init(
        terminationGracePeriod: TimeInterval = 2.0,
        forceKillGracePeriod: TimeInterval = 1.0,
        maximumWaitInterval: TimeInterval = 0.05
    ) {
        self.terminationGracePeriod = max(0, terminationGracePeriod)
        self.forceKillGracePeriod = max(0, forceKillGracePeriod)
        self.maximumWaitInterval = max(0.001, maximumWaitInterval)
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
        var stdoutOpen = true
        var stderrOpen = true
        var drainStdoutFirst = true

        while process.isRunning {
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

            let waitDeadline = Self.nextWaitDeadline(
                now: now,
                maximumWaitInterval: maximumWaitInterval,
                timeoutDeadline: timedOut ? nil : timeoutDeadline,
                terminationDeadline: terminationDeadline,
                forceKillDeadline: forceKillDeadline
            )
            var descriptors = [
                pollfd(
                    fd: stdoutOpen ? stdoutRead.fileDescriptor : -1,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                ),
                pollfd(
                    fd: stderrOpen ? stderrRead.fileDescriptor : -1,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                )
            ]
            let waitResult = Self.waitForReadiness(&descriptors, until: waitDeadline)
            if waitResult < 0 {
                // A permanent poll failure cannot safely identify readable streams.
                // End the bounded wait loop; the final nonblocking drain still keeps
                // already-buffered output and descriptor ownership deterministic.
                break
            }

            let stdoutReady = stdoutOpen && descriptors[0].revents != 0
            let stderrReady = stderrOpen && descriptors[1].revents != 0
            if drainStdoutFirst {
                if stdoutReady {
                    stdoutOpen = Self.drainAvailable(
                        from: stdoutRead.fileDescriptor, into: &stdoutData
                    )
                }
                if stderrReady {
                    stderrOpen = Self.drainAvailable(
                        from: stderrRead.fileDescriptor, into: &stderrData
                    )
                }
            } else {
                if stderrReady {
                    stderrOpen = Self.drainAvailable(
                        from: stderrRead.fileDescriptor, into: &stderrData
                    )
                }
                if stdoutReady {
                    stdoutOpen = Self.drainAvailable(
                        from: stdoutRead.fileDescriptor, into: &stdoutData
                    )
                }
            }
            drainStdoutFirst.toggle()
        }

        // Drain everything already written after observing exit. Reads remain
        // nonblocking, so an inherited writer in an errant descendant cannot hang us.
        _ = Self.drainAvailable(
            from: stdoutRead.fileDescriptor, into: &stdoutData, chunkLimit: .max
        )
        _ = Self.drainAvailable(
            from: stderrRead.fileDescriptor, into: &stderrData, chunkLimit: .max
        )

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

    private static func nextWaitDeadline(
        now: TimeInterval,
        maximumWaitInterval: TimeInterval,
        timeoutDeadline: TimeInterval?,
        terminationDeadline: TimeInterval?,
        forceKillDeadline: TimeInterval?
    ) -> TimeInterval {
        var deadline = now + maximumWaitInterval
        for candidate in [timeoutDeadline, terminationDeadline, forceKillDeadline].compactMap({ $0 }) {
            deadline = min(deadline, candidate)
        }
        return deadline
    }

    /// Blocks until either pipe changes state or the next lifecycle deadline arrives.
    /// Signals are handled by recomputing the remaining monotonic-clock interval, so
    /// repeated EINTR cannot extend a timeout or turn into a spin loop.
    private static func waitForReadiness(
        _ descriptors: inout [pollfd],
        until deadline: TimeInterval
    ) -> Int32 {
        while true {
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            let milliseconds = Int32(min(
                Double(Int32.max),
                ceil(remaining * 1_000)
            ))
            let result = descriptors.withUnsafeMutableBufferPointer { buffer in
                Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), milliseconds)
            }
            if result >= 0 || errno != EINTR {
                return result
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                return 0
            }
        }
    }

    /// A per-pass limit keeps one continuously noisy stream from starving the other
    /// or delaying timeout enforcement. The final post-exit drain has no limit.
    /// Returns whether the descriptor can still produce data. EOF, POLLNVAL-driven
    /// EBADF, and other permanent read errors retire it from subsequent poll calls.
    private static func drainAvailable(
        from descriptor: Int32,
        into data: inout Data,
        chunkLimit: Int = 64
    ) -> Bool {
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
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                return true
            }
            // EOF and permanent descriptor errors cannot become readable later.
            return false
        }
        return true
    }
}
