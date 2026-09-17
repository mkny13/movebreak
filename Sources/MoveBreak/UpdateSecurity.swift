import Darwin
import Foundation
import Security

// MARK: - Staging Path & Containment Validation

enum StagingPathError: Error, CustomStringConvertible, Equatable {
    case stagingDirectoryEscaped(String)
    case appNotFound(String)
    case appIsSymlink(String)
    case appEscapesStaging(String)
    case internalSymlinkEscapes(path: String, destination: String)
    case invalidAppStructure(String)

    var description: String {
        switch self {
        case .stagingDirectoryEscaped(let path):
            return "staging directory escaped root: \(path)"
        case .appNotFound(let path):
            return "no MoveBreak.app found in staging directory: \(path)"
        case .appIsSymlink(let path):
            return "MoveBreak.app is a symbolic link: \(path)"
        case .appEscapesStaging(let path):
            return "MoveBreak.app resolves outside staging directory: \(path)"
        case .internalSymlinkEscapes(let path, let destination):
            return "bundle contains symlink '\(path)' pointing outside staging directory to '\(destination)'"
        case .invalidAppStructure(let message):
            return "invalid app bundle structure: \(message)"
        }
    }
}

enum StagingPathValidation {
    static func ensureSecureDirectory(at url: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        _ = chmod(url.path, 0o700)
    }

    static func cleanStagingRoot(at url: URL) {
        let fileManager = FileManager.default
        if let existing = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            for item in existing {
                try? fileManager.removeItem(at: item)
            }
        }
    }

    static func validateContainment(
        appURL: URL,
        stagingDir: URL,
        expectedExecutable: String = "MoveBreak"
    ) throws {
        let fileManager = FileManager.default
        let canonicalStaging = (stagingDir.resolvingSymlinksInPath().path as NSString).standardizingPath

        var appStat = stat()
        guard lstat(appURL.path, &appStat) == 0 else {
            throw StagingPathError.appNotFound(appURL.path)
        }
        guard (appStat.st_mode & S_IFMT) != S_IFLNK else {
            throw StagingPathError.appIsSymlink(appURL.path)
        }
        guard (appStat.st_mode & S_IFMT) == S_IFDIR else {
            throw StagingPathError.invalidAppStructure("candidate is not a directory")
        }

        let canonicalApp = (appURL.resolvingSymlinksInPath().path as NSString).standardizingPath
        let standardizedAppPath = (appURL.path as NSString).standardizingPath
        guard canonicalApp == standardizedAppPath else {
            throw StagingPathError.appEscapesStaging(canonicalApp)
        }
        guard canonicalApp.hasPrefix(canonicalStaging + "/") else {
            throw StagingPathError.appEscapesStaging(canonicalApp)
        }

        if let enumerator = fileManager.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: []
        ) {
            for case let itemURL as URL in enumerator {
                var itemStat = stat()
                if lstat(itemURL.path, &itemStat) == 0 && (itemStat.st_mode & S_IFMT) == S_IFLNK {
                    let destination = (itemURL.resolvingSymlinksInPath().path as NSString).standardizingPath
                    if !destination.hasPrefix(canonicalStaging + "/") && destination != canonicalStaging {
                        throw StagingPathError.internalSymlinkEscapes(
                            path: itemURL.path,
                            destination: destination
                        )
                    }
                }
            }
        }

        let executableURL = appURL.appendingPathComponent("Contents/MacOS/\(expectedExecutable)")
        var executableStat = stat()
        guard lstat(executableURL.path, &executableStat) == 0 else {
            throw StagingPathError.invalidAppStructure("missing executable at \(executableURL.path)")
        }
        guard (executableStat.st_mode & S_IFMT) == S_IFREG else {
            throw StagingPathError.invalidAppStructure("executable at \(executableURL.path) is not a regular file")
        }
        guard (executableStat.st_mode & 0o111) != 0 else {
            throw StagingPathError.invalidAppStructure("executable at \(executableURL.path) is not marked executable")
        }
    }
}

// MARK: - Code Signing Policy

struct CodeSigningIdentity: Equatable {
    let isAdHoc: Bool
    let bundleID: String?
    let leafCertificateData: Data?
    let leafCertificateSubject: String?
}

enum SigningTrustError: Error, CustomStringConvertible, Equatable {
    case runningAppAdHoc(String)
    case runningAppNoCertificate(String)
    case candidateSignatureInvalid(String)
    case candidateAdHoc(String)
    case candidateNoCertificate(String)
    case certificateMismatch(expectedSubject: String, candidateSubject: String)
    case certificateDataMismatch

    var description: String {
        switch self {
        case .runningAppAdHoc(let message):
            return "running app is ad-hoc signed; automatic update installation is disabled (\(message))"
        case .runningAppNoCertificate(let message):
            return "running app has no code signing certificate; automatic update installation is disabled (\(message))"
        case .candidateSignatureInvalid(let message):
            return "candidate bundle signature verification failed: \(message)"
        case .candidateAdHoc(let message):
            return "candidate bundle is ad-hoc signed, rejecting: \(message)"
        case .candidateNoCertificate(let message):
            return "candidate bundle has no signing certificate, rejecting: \(message)"
        case .certificateMismatch(let expected, let candidate):
            return "signing certificate subject mismatch: expected '\(expected)', got '\(candidate)'"
        case .certificateDataMismatch:
            return "candidate signing certificate does not match running app leaf certificate"
        }
    }
}

enum CodeSigningPolicy {
    static func inspect(at bundleURL: URL) -> Result<CodeSigningIdentity, Error> {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else {
            return .failure(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }
        return inspect(staticCode: staticCode)
    }

    static func inspectRunningApp() -> Result<CodeSigningIdentity, Error> {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return inspect(at: Bundle.main.bundleURL)
        }
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else {
            return .failure(NSError(domain: NSOSStatusErrorDomain, code: -1))
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode else {
            return .failure(NSError(domain: NSOSStatusErrorDomain, code: -1))
        }
        return inspect(staticCode: staticCode)
    }

    private static func inspect(staticCode: SecStaticCode) -> Result<CodeSigningIdentity, Error> {
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard status == errSecSuccess, let info = information as? [String: Any] else {
            return .failure(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }
        let flags = info[kSecCodeInfoFlags as String] as? UInt32 ?? 0
        let isAdHoc = (flags & SecCodeSignatureFlags.adhoc.rawValue) != 0
        let bundleID = info[kSecCodeInfoIdentifier as String] as? String

        var leafData: Data?
        var leafSubject: String?
        if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certificates.first {
            leafData = SecCertificateCopyData(leaf) as Data
            leafSubject = SecCertificateCopySubjectSummary(leaf) as String?
        }

        return .success(CodeSigningIdentity(
            isAdHoc: isAdHoc,
            bundleID: bundleID,
            leafCertificateData: leafData,
            leafCertificateSubject: leafSubject
        ))
    }

    static func verifyStrictCodeSignature(
        at appURL: URL,
        processRunner: (String, [String], TimeInterval) -> ProcessResult = ProcessRunner.run
    ) throws {
        let result = processRunner(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", appURL.path],
            30.0
        )
        if result.timedOut {
            throw SigningTrustError.candidateSignatureInvalid("codesign verification timed out after 30 seconds")
        }
        guard result.isSuccess else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SigningTrustError.candidateSignatureInvalid(
                message.isEmpty ? "exit code \(result.exitCode)" : message
            )
        }
    }

    static func verifySignerContinuity(
        running: CodeSigningIdentity,
        candidate: CodeSigningIdentity
    ) throws {
        if running.isAdHoc || running.leafCertificateData == nil {
            throw SigningTrustError.runningAppAdHoc(
                "running build is ad-hoc signed (requires \"MoveBreak Signing\" certificate)"
            )
        }
        if candidate.isAdHoc || candidate.leafCertificateData == nil {
            throw SigningTrustError.candidateAdHoc("candidate app is ad-hoc signed")
        }
        guard let runningLeaf = running.leafCertificateData,
              let candidateLeaf = candidate.leafCertificateData else {
            throw SigningTrustError.candidateNoCertificate("missing leaf certificate")
        }
        guard runningLeaf == candidateLeaf else {
            let expectedSubject = running.leafCertificateSubject ?? "unknown"
            let candidateSubject = candidate.leafCertificateSubject ?? "unknown"
            if expectedSubject != candidateSubject {
                throw SigningTrustError.certificateMismatch(
                    expectedSubject: expectedSubject,
                    candidateSubject: candidateSubject
                )
            }
            throw SigningTrustError.certificateDataMismatch
        }
    }
}
