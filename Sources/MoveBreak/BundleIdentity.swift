import Foundation

/// Maps a *process* bundle ID back to the app it belongs to.
///
/// This exists because audio is almost never attributed to the app you'd expect. Chrome's
/// playback is reported as `com.google.Chrome.helper`, not `com.google.Chrome`; Electron
/// apps (Slack, Teams, Discord) do the same thing; and Safari's audio comes from
/// `com.apple.WebKit.GPU`, which doesn't even share Safari's prefix.
///
/// Matching raw bundle IDs against an app list therefore silently matches nothing, which
/// is exactly the failure this guards against.
enum BundleIdentity {

    /// Engine/helper prefixes that belong to an app but don't share its bundle prefix.
    /// Checked after the generic `<app>.` rule below.
    private static let engineOwners: [String: String] = [
        "com.apple.WebKit": "com.apple.Safari",
        "com.apple.SafariServices": "com.apple.Safari",
    ]

    /// Returns the entry from `knownApps` that this process belongs to, or nil.
    static func owner(of bundleID: String, in knownApps: Set<String>) -> String? {
        if knownApps.contains(bundleID) { return bundleID }

        // Generic helper rule: com.google.Chrome.helper -> com.google.Chrome
        // Longest match wins so a more specific app entry isn't shadowed by a shorter one.
        let prefixMatch = knownApps
            .filter { bundleID.hasPrefix($0 + ".") }
            .max(by: { $0.count < $1.count })
        if let prefixMatch { return prefixMatch }

        // Engine processes that don't carry the app's prefix at all.
        for (enginePrefix, app) in engineOwners
        where bundleID == enginePrefix || bundleID.hasPrefix(enginePrefix + ".") {
            if knownApps.contains(app) { return app }
        }

        return nil
    }

    /// Convenience: does this process belong to any app in the set?
    static func belongs(_ bundleID: String?, to knownApps: Set<String>) -> Bool {
        guard let bundleID else { return false }
        return owner(of: bundleID, in: knownApps) != nil
    }
}
