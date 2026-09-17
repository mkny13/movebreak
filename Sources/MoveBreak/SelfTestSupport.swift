import Darwin
import Foundation

enum SelfTestSuiteID: String, CaseIterable {
    case detection
    case security
    case persistence
    case update
}
struct SelfTestSuite {
    let id: SelfTestSuiteID
    let run: () -> Int
}

final class SelfTestTemporaryDirectory {
    let url: URL
    private var isCleanedUp = false

    init(prefix: String, baseURL: URL = URL(fileURLWithPath: NSTemporaryDirectory())) {
        url = baseURL
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    func create(permissions: Int? = nil) throws {
        let attributes = permissions.map { [FileAttributeKey.posixPermissions: $0] }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: attributes
        )
    }

    func cleanup(removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws {
        guard !isCleanedUp else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            isCleanedUp = true
            return
        }
        guard chmod(url.path, 0o700) == 0 else {
            throw SelfTestInfrastructureError.posix(operation: "chmod temporary directory", code: errno)
        }
        try removeItem(url)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw SelfTestInfrastructureError.fixtureCleanupFailed(path: url.path)
        }
        isCleanedUp = true
    }

    deinit {
        // Explicit cleanup is required so failures can be reported by the owning test. This is
        // only a last-resort attempt for an early return or an unexpected test bug.
        try? cleanup()
    }
}

enum SelfTestInfrastructureError: Error, CustomStringConvertible {
    case posix(operation: String, code: Int32)
    case fixtureCleanupFailed(path: String)
    case invalidUTF8(stream: String)

    var description: String {
        switch self {
        case .posix(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code))) (errno \(code))"
        case .fixtureCleanupFailed(let path):
            return "temporary fixture still exists after cleanup: \(path)"
        case .invalidUTF8(let stream):
            return "captured \(stream) was not valid UTF-8"
        }
    }
}

final class SelfTestReporter {
    private(set) var failureCount = 0

    func check(_ name: String, _ passed: Bool, detail: String = "") {
        record(name, passed: passed, details: detail.isEmpty ? [] : [detail])
    }

    func check(_ name: String, passed: Bool, detail: String = "") {
        check(name, passed, detail: detail)
    }

    func check<T: Equatable>(_ name: String, expected: T, actual: T) {
        check(name, expected == actual, detail: "expected \(expected), got \(actual)")
    }

    func record(
        _ name: String,
        passed: Bool,
        details: [String] = [],
        alwaysShowDetails: Bool = false
    ) {
        if !passed { failureCount += 1 }
        print("\(passed ? "✓" : "✗ FAIL")  \(name)")
        if !passed || alwaysShowDetails {
            details.forEach { print("      \($0)") }
        }
    }
}

enum SelfTestSupport {
    static func withStandardInput<T>(from descriptor: Int32, perform: () -> T) throws -> T {
        let savedInput = dup(STDIN_FILENO)
        guard savedInput >= 0 else {
            throw SelfTestInfrastructureError.posix(operation: "duplicate stdin", code: errno)
        }
        guard dup2(descriptor, STDIN_FILENO) >= 0 else {
            let code = errno
            close(savedInput)
            throw SelfTestInfrastructureError.posix(operation: "redirect stdin", code: code)
        }
        let result = perform()
        guard dup2(savedInput, STDIN_FILENO) >= 0 else {
            let code = errno
            close(savedInput)
            throw SelfTestInfrastructureError.posix(operation: "restore stdin", code: code)
        }
        close(savedInput)
        return result
    }

    static func captureOutput(
        pipeFactory: (UnsafeMutablePointer<Int32>) -> Int32 = { Darwin.pipe($0) },
        block: () -> Void
    ) throws -> (stdout: String, stderr: String) {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        let outPipeResult = outPipe.withUnsafeMutableBufferPointer {
            pipeFactory($0.baseAddress!)
        }
        guard outPipeResult == 0 else {
            throw SelfTestInfrastructureError.posix(operation: "create stdout capture pipe", code: errno)
        }
        let errPipeResult = errPipe.withUnsafeMutableBufferPointer {
            pipeFactory($0.baseAddress!)
        }
        guard errPipeResult == 0 else {
            let code = errno
            close(outPipe[0])
            close(outPipe[1])
            throw SelfTestInfrastructureError.posix(operation: "create stderr capture pipe", code: code)
        }

        let savedOut = dup(STDOUT_FILENO)
        let savedErr = dup(STDERR_FILENO)
        guard savedOut >= 0, savedErr >= 0 else {
            let code = errno
            if savedOut >= 0 { close(savedOut) }
            if savedErr >= 0 { close(savedErr) }
            outPipe.forEach { close($0) }
            errPipe.forEach { close($0) }
            throw SelfTestInfrastructureError.posix(operation: "duplicate standard output", code: code)
        }

        fflush(stdout)
        fflush(stderr)
        guard dup2(outPipe[1], STDOUT_FILENO) >= 0 else {
            let code = errno
            close(savedOut)
            close(savedErr)
            outPipe.forEach { close($0) }
            errPipe.forEach { close($0) }
            throw SelfTestInfrastructureError.posix(operation: "redirect stdout", code: code)
        }
        guard dup2(errPipe[1], STDERR_FILENO) >= 0 else {
            let code = errno
            _ = dup2(savedOut, STDOUT_FILENO)
            close(savedOut)
            close(savedErr)
            outPipe.forEach { close($0) }
            errPipe.forEach { close($0) }
            throw SelfTestInfrastructureError.posix(operation: "redirect stderr", code: code)
        }
        close(outPipe[1])
        close(errPipe[1])

        block()
        fflush(stdout)
        fflush(stderr)

        let restoreOutResult = dup2(savedOut, STDOUT_FILENO)
        let restoreOutError = errno
        let restoreErrResult = dup2(savedErr, STDERR_FILENO)
        let restoreErrError = errno
        close(savedOut)
        close(savedErr)
        guard restoreOutResult >= 0 else {
            close(outPipe[0])
            close(errPipe[0])
            throw SelfTestInfrastructureError.posix(operation: "restore stdout", code: restoreOutError)
        }
        guard restoreErrResult >= 0 else {
            close(outPipe[0])
            close(errPipe[0])
            throw SelfTestInfrastructureError.posix(operation: "restore stderr", code: restoreErrError)
        }

        func readPipe(_ descriptor: Int32, stream: String) throws -> String {
            defer { close(descriptor) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    data.append(buffer, count: count)
                } else if count < 0 && errno == EINTR {
                    continue
                } else if count < 0 {
                    throw SelfTestInfrastructureError.posix(operation: "read captured \(stream)", code: errno)
                } else {
                    break
                }
            }
            guard let value = String(data: data, encoding: .utf8) else {
                throw SelfTestInfrastructureError.invalidUTF8(stream: stream)
            }
            return value
        }

        let capturedOut: String
        do {
            capturedOut = try readPipe(outPipe[0], stream: "stdout")
        } catch {
            close(errPipe[0])
            throw error
        }
        let capturedErr = try readPipe(errPipe[0], stream: "stderr")
        return (capturedOut, capturedErr)
    }

    static func posixMode(at path: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return nil
        }
        return permissions.intValue
    }

    static func openFileDescriptorCount() -> Int {
        (0..<getdtablesize()).reduce(into: 0) { count, descriptor in
            errno = 0
            if fcntl(descriptor, F_GETFD) != -1 || errno != EBADF {
                count += 1
            }
        }
    }
}
