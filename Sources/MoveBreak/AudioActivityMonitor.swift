import CoreAudio
import Foundation

struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningInput: Bool
    let isRunningOutput: Bool
    init(objectID: AudioObjectID = 0, pid: pid_t = 0, bundleID: String?, isRunningInput: Bool = false, isRunningOutput: Bool = false) {
        self.objectID = objectID; self.pid = pid; self.bundleID = bundleID
        self.isRunningInput = isRunningInput; self.isRunningOutput = isRunningOutput
    }
}

struct AudioPropertyReader {
    var objectIDs: () -> [AudioObjectID]
    var pid: (AudioObjectID) -> pid_t
    var bundleID: (AudioObjectID) -> String?
    var runningInput: (AudioObjectID) -> Bool
    var runningOutput: (AudioObjectID) -> Bool
}

final class AudioActivityMonitor {
    private let reader: AudioPropertyReader
    private let fallbackBundleID: (AudioObjectID, pid_t) -> String?

    init(reader: AudioPropertyReader = .coreAudio, fallbackBundleID: @escaping (AudioObjectID, pid_t) -> String? = {
        RunningAppLookup.shared.bundleID(forPID: $1, objectID: $0)
    }) { self.reader = reader; self.fallbackBundleID = fallbackBundleID }

    static var isSupported: Bool {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        return AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address)
    }

    /// Full diagnostic snapshot deliberately resolves metadata for every object.
    func snapshot() -> [AudioProcess] { reader.objectIDs().map { process($0) } }

    /// Detection path reads stream state first and resolves identity only for live objects.
    func activeSnapshot() -> [AudioProcess] {
        let ids = reader.objectIDs()
        var active: [AudioProcess] = []
        for id in ids {
            let input = reader.runningInput(id), output = reader.runningOutput(id)
            guard input || output else { continue }
            active.append(process(id, input: input, output: output))
        }
        RunningAppLookup.shared.retain(objectIDs: Set(ids))
        return active
    }

    private func process(_ id: AudioObjectID, input: Bool? = nil, output: Bool? = nil) -> AudioProcess {
        let pid = reader.pid(id)
        return AudioProcess(objectID: id, pid: pid,
            bundleID: reader.bundleID(id) ?? (pid > 0 ? fallbackBundleID(id, pid) : nil),
            isRunningInput: input ?? reader.runningInput(id), isRunningOutput: output ?? reader.runningOutput(id))
    }

    fileprivate static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}

extension AudioPropertyReader {
    static let coreAudio = AudioPropertyReader(
        objectIDs: {
            var address = AudioActivityMonitor.address(kAudioHardwarePropertyProcessObjectList)
            let system = AudioObjectID(kAudioObjectSystemObject); var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
            var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
            return ids
        },
        pid: { id in
            var address = AudioActivityMonitor.address(kAudioProcessPropertyPID), value: pid_t = -1
            var size = UInt32(MemoryLayout<pid_t>.size)
            return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : -1
        },
        bundleID: { id in
            var address = AudioActivityMonitor.address(kAudioProcessPropertyBundleID)
            var size = UInt32(MemoryLayout<CFString?>.size), value: CFString?
            let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
            guard status == noErr, let value, !(value as String).isEmpty else { return nil }
            return value as String
        },
        runningInput: { flag($0, kAudioProcessPropertyIsRunningInput) },
        runningOutput: { flag($0, kAudioProcessPropertyIsRunningOutput) }
    )

    private static func flag(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioActivityMonitor.address(selector), value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr && value != 0
    }
}
