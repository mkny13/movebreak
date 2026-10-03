import Darwin
import Foundation

/// Descriptor-relative storage: never follow filesystem indirection in app-owned paths.
/// System /var and /tmp aliases are expanded explicitly, not by resolving arbitrary links.
final class PrivateFileStore {
    private let directory: Int32

    init(directoryURL: URL, protectingParent: Bool = false) throws {
        var path = directoryURL.path
        for alias in ["/var", "/tmp"] where path == alias || path.hasPrefix(alias + "/") {
            path = "/private" + path
        }
        let components = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), !components.contains(".."), !components.isEmpty else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure() }
        do {
            for (index, component) in components.enumerated() {
                let protected = index >= components.count - (protectingParent ? 2 : 1)
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT {
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw Self.failure() }
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw Self.failure() }
                Darwin.close(fd)
                fd = next
                if protected { try Self.protect(fd, directory: true) }
            }
            directory = fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    deinit { Darwin.close(directory) }

    private static func failure() -> Error { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private static func protect(_ fd: Int32, directory: Bool = false) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw failure() }
        guard info.st_uid == geteuid(),
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              directory || info.st_nlink == 1 else { throw CocoaError(.fileReadNoPermission) }
        guard let acl = acl_init(0) else { throw failure() }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd(fd, acl) == 0,
              fchmod(fd, directory ? 0o700 : 0o600) == 0 else { throw failure() }
    }

    private func openFile(_ name: String, flags: Int32) throws -> Int32? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        var target = stat()
        if fstatat(directory, name, &target, AT_SYMLINK_NOFOLLOW) == 0 {
            guard target.st_mode & S_IFMT == S_IFREG, target.st_uid == geteuid(), target.st_nlink == 1 else {
                throw CocoaError(.fileReadNoPermission)
            }
        } else if errno != ENOENT { throw Self.failure() }
        let fd = openat(directory, name, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        if fd < 0 {
            if errno == ENOENT && flags & O_CREAT == 0 { return nil }
            throw Self.failure()
        }
        do { try Self.protect(fd) }
        catch { Darwin.close(fd); throw error }
        return fd
    }

    func read(_ name: String) throws -> Data? {
        guard let fd = try openFile(name, flags: O_RDONLY) else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return try handle.readToEnd() ?? Data()
    }

    func append(_ data: Data, to name: String) throws {
        guard let fd = try openFile(name, flags: O_WRONLY | O_APPEND | O_CREAT) else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard fsync(directory) == 0 else { throw Self.failure() }
    }

    /// The original remains in place until the fully written, private staging file is synced.
    /// Internal hooks let self-tests exercise actual write/rename failure cleanup deterministically.
    func replace(_ data: Data, at name: String,
                 write: (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) },
                 renameFile: (Int32, String, Int32, String) -> Int32 = { renameat($0, $1, $2, $3) }) throws {
        if let fd = try openFile(name, flags: O_RDONLY) { Darwin.close(fd) }
        let temporary = ".movebreak-\(UUID().uuidString).tmp"
        guard let fd = try openFile(temporary, flags: O_WRONLY | O_CREAT | O_EXCL) else { return }
        defer { unlinkat(directory, temporary, 0) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try write(handle, data)
        try handle.synchronize()
        if let target = try openFile(name, flags: O_RDONLY) { Darwin.close(target) }
        guard renameFile(directory, temporary, directory, name) == 0 else { throw Self.failure() }
        guard fsync(directory) == 0 else { throw Self.failure() }
    }
}
