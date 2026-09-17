import CryptoKit
import Foundation

// MARK: - Release Metadata & Validation

struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: URL
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case digest
    }
}

struct ReleaseCandidate: Equatable {
    let tagName: String
    let downloadURL: URL
    let expectedDigest: String
}

enum ReleaseValidationError: Error, CustomStringConvertible, Equatable {
    case invalidTag(String)
    case notNewer(tag: String, current: String)
    case missingAsset(String)
    case invalidDownloadURL(String)
    case invalidDigest(String)

    var description: String {
        switch self {
        case .invalidTag(let tag):
            return "invalid release tag '\(tag)': must match expected version format"
        case .notNewer(let tag, let current):
            return "release tag '\(tag)' is not newer than current version '\(current)'"
        case .missingAsset(let name):
            return "release is missing required asset '\(name)'"
        case .invalidDownloadURL(let url):
            return "untrusted or malformed download URL '\(url)'"
        case .invalidDigest(let digest):
            return "invalid or missing SHA-256 digest '\(digest)'"
        }
    }
}

enum ReleaseValidation {
    static func validateTag(_ tag: String) -> Bool {
        guard tag.hasPrefix("v"), tag.count >= 2, tag.count <= 32 else { return false }
        let stripped = String(tag.dropFirst())
        let parts = stripped.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return false }
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isNumber }), Int(part) != nil else {
                return false
            }
        }
        return true
    }

    static func validateDownloadURL(
        url: URL,
        repo: String,
        tag: String,
        assetName: String
    ) -> Bool {
        guard url.scheme == "https",
              url.host == "github.com",
              url.port == nil || url.port == 443,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return false
        }
        let expectedPath = "/\(repo)/releases/download/\(tag)/\(assetName)"
        return url.path == expectedPath
    }

    static func parseDigest(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix("sha256:") else {
            return nil
        }
        let hex = String(raw.dropFirst(7)).lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return hex
    }

    static func validateRelease(
        release: GitHubRelease,
        repo: String,
        assetName: String,
        currentVersion: String
    ) throws -> ReleaseCandidate {
        guard validateTag(release.tagName) else {
            throw ReleaseValidationError.invalidTag(release.tagName)
        }
        guard SemVer.isNewer(release.tagName, than: currentVersion) else {
            throw ReleaseValidationError.notNewer(tag: release.tagName, current: currentVersion)
        }
        guard let asset = release.assets.first(where: { $0.name == assetName }) else {
            throw ReleaseValidationError.missingAsset(assetName)
        }
        guard validateDownloadURL(url: asset.browserDownloadURL, repo: repo, tag: release.tagName, assetName: assetName) else {
            throw ReleaseValidationError.invalidDownloadURL(asset.browserDownloadURL.absoluteString)
        }
        guard let digest = parseDigest(asset.digest) else {
            throw ReleaseValidationError.invalidDigest(asset.digest ?? "none")
        }
        return ReleaseCandidate(
            tagName: release.tagName,
            downloadURL: asset.browserDownloadURL,
            expectedDigest: digest
        )
    }
}

// MARK: - Archive Digest Validation

enum ArchiveDigestError: Error, CustomStringConvertible, Equatable {
    case fileUnreadable(String)
    case digestMismatch(expected: String, actual: String)

    var description: String {
        switch self {
        case .fileUnreadable(let message):
            return "failed to read archive for digest computation: \(message)"
        case .digestMismatch(let expected, let actual):
            return "archive digest mismatch: expected \(expected), got \(actual)"
        }
    }
}

enum ArchiveDigestValidation {
    static func computeSHA256(at url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ArchiveDigestError.fileUnreadable("could not open file at \(url.path)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verifyArchive(at url: URL, expectedHexDigest: String) throws {
        let actual = try computeSHA256(at: url)
        guard actual.lowercased() == expectedHexDigest.lowercased() else {
            throw ArchiveDigestError.digestMismatch(expected: expectedHexDigest.lowercased(), actual: actual.lowercased())
        }
    }
}

// MARK: - Bundle Metadata Validation

enum BundleMetadataError: Error, CustomStringConvertible, Equatable {
    case missingInfoPlist(String)
    case unreadableInfoPlist(String)
    case bundleIdentifierMismatch(expected: String, actual: String)
    case executableNameMismatch(expected: String, actual: String)
    case versionMismatch(tag: String, plistVersion: String)

    var description: String {
        switch self {
        case .missingInfoPlist(let path):
            return "missing Info.plist at \(path)"
        case .unreadableInfoPlist(let message):
            return "failed to read Info.plist: \(message)"
        case .bundleIdentifierMismatch(let expected, let actual):
            return "bundle identifier mismatch: expected '\(expected)', got '\(actual)'"
        case .executableNameMismatch(let expected, let actual):
            return "executable name mismatch: expected '\(expected)', got '\(actual)'"
        case .versionMismatch(let tag, let plistVersion):
            return "bundle version '\(plistVersion)' does not match release tag '\(tag)'"
        }
    }
}

enum BundleMetadataValidation {
    static func validateBundleMetadata(
        appURL: URL,
        expectedBundleID: String = "com.mike.movebreak",
        expectedExecutable: String = "MoveBreak",
        releaseTag: String
    ) throws {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            throw BundleMetadataError.missingInfoPlist(plistURL.path)
        }
        guard let plistData = try? Data(contentsOf: plistURL),
              let plistObject = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let plist = plistObject as? [String: Any] else {
            throw BundleMetadataError.unreadableInfoPlist("cannot parse Contents/Info.plist")
        }

        guard let bundleID = plist["CFBundleIdentifier"] as? String, bundleID == expectedBundleID else {
            throw BundleMetadataError.bundleIdentifierMismatch(
                expected: expectedBundleID,
                actual: (plist["CFBundleIdentifier"] as? String) ?? "missing"
            )
        }

        guard let executable = plist["CFBundleExecutable"] as? String, executable == expectedExecutable else {
            throw BundleMetadataError.executableNameMismatch(
                expected: expectedExecutable,
                actual: (plist["CFBundleExecutable"] as? String) ?? "missing"
            )
        }

        guard let plistVersion = plist["CFBundleShortVersionString"] as? String else {
            throw BundleMetadataError.versionMismatch(tag: releaseTag, plistVersion: "missing")
        }

        guard SemVer.areEqual(releaseTag, plistVersion) else {
            throw BundleMetadataError.versionMismatch(tag: releaseTag, plistVersion: plistVersion)
        }
    }
}

// MARK: - SemVer

/// Dot-separated integer version comparison. Tolerates a leading "v" and a non-numeric
/// suffix (so "v1.2.0", "1.2.0-test" both parse as [1, 2, 0]), and fails closed — an
/// unparseable version is never treated as newer.
enum SemVer {
    static func components(from raw: String) -> [Int]? {
        var string = raw
        if string.hasPrefix("v") { string.removeFirst() }
        if let cut = string.firstIndex(where: { !($0.isNumber || $0 == ".") }) {
            string = String(string[string.startIndex..<cut])
        }
        guard !string.isEmpty else { return nil }

        var result: [Int] = []
        for part in string.split(separator: ".", omittingEmptySubsequences: false) {
            guard let number = Int(part) else { return nil }
            result.append(number)
        }
        return result
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidateComponents = components(from: candidate),
              let currentComponents = components(from: current) else {
            return false
        }
        for index in 0..<max(candidateComponents.count, currentComponents.count) {
            let candidatePart = index < candidateComponents.count ? candidateComponents[index] : 0
            let currentPart = index < currentComponents.count ? currentComponents[index] : 0
            if candidatePart != currentPart { return candidatePart > currentPart }
        }
        return false
    }

    static func areEqual(_ first: String, _ second: String) -> Bool {
        guard let firstComponents = components(from: first),
              let secondComponents = components(from: second) else {
            return false
        }
        let maxLength = max(firstComponents.count, secondComponents.count)
        for index in 0..<maxLength {
            let firstPart = index < firstComponents.count ? firstComponents[index] : 0
            let secondPart = index < secondComponents.count ? secondComponents[index] : 0
            if firstPart != secondPart { return false }
        }
        return true
    }
}
