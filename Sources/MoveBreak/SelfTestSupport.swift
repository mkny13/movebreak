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

enum SelfTestSupport {
    static func captureOutput(block: () -> Void) -> (stdout: String, stderr: String) {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { return ("", "") }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0])
            close(outPipe[1])
            return ("", "")
        }

        let savedOut = dup(STDOUT_FILENO)
        let savedErr = dup(STDERR_FILENO)
        guard savedOut >= 0, savedErr >= 0 else {
            if savedOut >= 0 { close(savedOut) }
            if savedErr >= 0 { close(savedErr) }
            outPipe.forEach { close($0) }
            errPipe.forEach { close($0) }
            return ("", "")
        }

        fflush(stdout)
        fflush(stderr)
        _ = dup2(outPipe[1], STDOUT_FILENO)
        _ = dup2(errPipe[1], STDERR_FILENO)
        close(outPipe[1])
        close(errPipe[1])

        defer {
            fflush(stdout)
            fflush(stderr)
            _ = dup2(savedOut, STDOUT_FILENO)
            _ = dup2(savedErr, STDERR_FILENO)
            close(savedOut)
            close(savedErr)
        }

        block()
        fflush(stdout)
        fflush(stderr)

        _ = dup2(savedOut, STDOUT_FILENO)
        _ = dup2(savedErr, STDERR_FILENO)

        func readPipe(_ descriptor: Int32) -> String {
            defer { close(descriptor) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            let flags = fcntl(descriptor, F_GETFL, 0)
            if flags >= 0 {
                _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
            }
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    data.append(buffer, count: count)
                } else {
                    break
                }
            }
            return String(data: data, encoding: .utf8) ?? ""
        }

        return (readPipe(outPipe[0]), readPipe(errPipe[0]))
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
