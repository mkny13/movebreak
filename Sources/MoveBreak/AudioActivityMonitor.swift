import CoreAudio
import Foundation

/// One process as CoreAudio sees it.
struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningInput: Bool     // holds a live microphone stream
    let isRunningOutput: Bool    // holds a live playback stream
}

/// Reads which processes currently hold live audio streams.
///
/// This is the whole foundation of the app: a process with a running *input* stream is in
/// a call, and one with a running *output* stream is playing something. Crucially, a
/// paused video holds no running output stream, which is what separates "YouTube tab is
/// open" from "a video is playing".
///
/// Uses `kAudioHardwarePropertyProcessObjectList` (macOS 14.4+). This reads stream *state*
/// only — it does not tap or record audio, so it needs no TCC permission and raises no
/// prompt.
final class AudioActivityMonitor {

    /// True if this OS exposes the process-object API at all.
    static var isSupported: Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address)
    }

    /// Snapshot of every process currently known to the audio system.
    func snapshot() -> [AudioProcess] {
        processObjectIDs().compactMap { objectID in
            let pid = pid(of: objectID)
            return AudioProcess(
                objectID: objectID,
                pid: pid,
                bundleID: bundleID(of: objectID) ?? bundleIDFromRunningApps(pid: pid),
                isRunningInput: flag(objectID, kAudioProcessPropertyIsRunningInput),
                isRunningOutput: flag(objectID, kAudioProcessPropertyIsRunningOutput)
            )
        }
    }

    /// Just the processes actually holding a stream right now.
    func activeSnapshot() -> [AudioProcess] {
        snapshot().filter { $0.isRunningInput || $0.isRunningOutput }
    }

    // MARK: - CoreAudio plumbing

    private func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }
        return ids
    }

    private func pid(of objectID: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return -1
        }
        return value
    }

    private func bundleID(of objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        let string = value as String
        return string.isEmpty ? nil : string
    }

    private func flag(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    /// Some processes report an empty bundle ID to CoreAudio (helper processes in
    /// particular). Fall back to asking the workspace what that PID belongs to.
    private func bundleIDFromRunningApps(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        return RunningAppLookup.shared.bundleID(forPID: pid)
    }
}
