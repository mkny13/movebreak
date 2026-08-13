import AppKit
import Foundation

/// Maps PIDs to bundle identifiers, with a small cache.
///
/// CoreAudio reports an empty bundle ID for some processes (helper processes especially),
/// so this fills the gap. The cache exists because the detector polls every 2s and
/// `NSRunningApplication(processIdentifier:)` is not free.
final class RunningAppLookup {
    static let shared = RunningAppLookup()

    private var cache: [pid_t: String?] = [:]
    private let lock = NSLock()

    func bundleID(forPID pid: pid_t) -> String? {
        lock.lock()
        if let cached = cache[pid] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier

        lock.lock()
        cache[pid] = resolved
        lock.unlock()
        return resolved
    }

    /// PIDs get recycled, so the cache can't live forever. Called once per poll.
    func invalidate() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
