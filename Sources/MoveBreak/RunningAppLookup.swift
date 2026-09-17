import AppKit
import CoreAudio
import Foundation

/// Bounded fallback identity cache, keyed by CoreAudio object and PID to reject PID reuse.
final class RunningAppLookup {
    static let shared = RunningAppLookup()
    private struct Key: Hashable { let objectID: AudioObjectID; let pid: pid_t }
    private struct Entry { let value: String?; let expires: Date }
    private var cache: [Key: Entry] = [:]
    private let lock = NSLock()
    private let lifetime: TimeInterval
    private let now: () -> Date
    private let resolve: (pid_t) -> String?

    init(lifetime: TimeInterval = 10, now: @escaping () -> Date = Date.init,
         resolve: @escaping (pid_t) -> String? = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }) {
        self.lifetime = lifetime; self.now = now; self.resolve = resolve
    }

    func bundleID(forPID pid: pid_t, objectID: AudioObjectID) -> String? {
        let key = Key(objectID: objectID, pid: pid), instant = now()
        if let hit = lock.withLock({ cache[key] }), hit.expires > instant { return hit.value }
        let value = resolve(pid)
        lock.withLock { cache[key] = Entry(value: value, expires: instant.addingTimeInterval(lifetime)) }
        return value
    }

    func retain(objectIDs: Set<AudioObjectID>) {
        let instant = now()
        lock.withLock { cache = cache.filter { objectIDs.contains($0.key.objectID) && $0.value.expires > instant } }
    }
}
