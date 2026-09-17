import AppKit
import CryptoKit
import Foundation
import Security

/// Checks GitHub Releases for a newer MoveBreak build and installs it in place once the
/// app is idle. No external dependencies — this project can't use SwiftPM (see
/// scripts/build_app.sh), so this is plain URLSession/Process/Security.
///
/// The app has no fixed install location (install_login_item.sh points a LaunchAgent at
/// wherever it was built), so every install replaces the bundle at its own
/// `Bundle.main.bundlePath` rather than assuming /Applications.
final class Updater {
    static let shared = Updater()
    init() {}

    /// Set by AppDelegate. Installing only proceeds while this returns true, so an update
    /// never interrupts an active prompt or routine.
    var isSafeToInstall: (() -> Bool)?

    static let defaultRepo = "mkny13/movebreak"
    static let defaultAssetName = "MoveBreak.app.zip"
    let repo: String = defaultRepo
    let assetName: String = defaultAssetName
    private let checkInterval: TimeInterval = 24 * 60 * 60

    private var checkTimer: Timer?
    private var isBusy = false
    private var stagedAppURL: URL?
    private var stagedVersion: String?

    /// Injectable for offline testing.
    var runningSignerInspector: () -> Result<CodeSigningIdentity, Error> = {
        CodeSigningPolicy.inspectRunningApp()
    }

    func start() {
        let runningSignerResult = runningSignerInspector()
        if case .success(let identity) = runningSignerResult, identity.isAdHoc || identity.leafCertificateData == nil {
            let reason = identity.isAdHoc ? "running build is ad-hoc signed" : "running build has no signing certificate"
            log("automatic installation is disabled: \(reason) (requires \"MoveBreak Signing\" certificate)")
            return
        }

        checkForUpdate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
        checkTimer?.tolerance = 60
    }

    /// Cheap to call often — a no-op unless a verified update is staged and now is a safe
    /// moment to install it.
    func installStagedUpdateIfPossible() {
        guard !isBusy, let stagedAppURL, isSafeToInstall?() == true else { return }
        performSwapAndRelaunch(from: stagedAppURL)
    }

    private var onCheckFinished: (() -> Void)?

    // MARK: - Check

    /// Public so a `--check-update-now` debug invocation can trigger it directly instead
    /// of waiting for the timer.
    func checkForUpdate(completion: (() -> Void)? = nil) {
        guard !isBusy else {
            completion?()
            return
        }
        isBusy = true
        onCheckFinished = completion

        let runningSignerResult = runningSignerInspector()
        guard case .success(let identity) = runningSignerResult, !identity.isAdHoc, identity.leafCertificateData != nil else {
            let reason: String
            if case .success(let id) = runningSignerResult, id.isAdHoc {
                reason = "running build is ad-hoc signed"
            } else {
                reason = "running build has no signing certificate"
            }
            finishCheck(log: "automatic installation is disabled: \(reason) (requires \"MoveBreak Signing\" certificate)")
            return
        }

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub's API 403s requests with no User-Agent.
        request.setValue("MoveBreak-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            onMain {
                guard let self else { return }
                self.handleLatestRelease(data: data, response: response, error: error, runningSigner: identity)
            }
        }.resume()
    }

    private func handleLatestRelease(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        runningSigner: CodeSigningIdentity
    ) {
        if let error {
            finishCheck(log: "check failed: \(error.localizedDescription)")
            return
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else {
            finishCheck(log: "check failed: bad response")
            return
        }
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
            finishCheck(log: "check failed: couldn't decode release")
            return
        }

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let candidate: ReleaseCandidate
        do {
            candidate = try ReleaseValidation.validateRelease(
                release: release,
                repo: repo,
                assetName: assetName,
                currentVersion: currentVersion
            )
        } catch {
            finishCheck(log: "check failed: \(error.localizedDescription)")
            return
        }

        guard stagedVersion != candidate.tagName else {
            finishCheck(log: nil)
            return
        }

        log("found \(candidate.tagName), currently on \(currentVersion) — staging")
        stage(candidate: candidate, runningSigner: runningSigner)
    }

    private func finishCheck(log message: String?) {
        if let message { log(message) }
        isBusy = false
        let callback = onCheckFinished
        onCheckFinished = nil
        callback?()
    }

    // MARK: - Stage

    private enum StageOutcome {
        case success(URL)
        case failure(String)
    }

    private func stage(candidate: ReleaseCandidate, runningSigner: CodeSigningIdentity) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let outcome = self.downloadAndVerify(candidate: candidate, runningSigner: runningSigner)
            onMain {
                switch outcome {
                case .success(let appURL):
                    self.stagedAppURL = appURL
                    self.stagedVersion = candidate.tagName
                    self.log("staged \(candidate.tagName), will install once idle")
                case .failure(let message):
                    self.log("stage failed: \(message)")
                }
                self.isBusy = false
                let callback = self.onCheckFinished
                self.onCheckFinished = nil
                callback?()
            }
        }
    }

    /// Runs entirely on a background queue: download, digest check, unzip, verify, de-quarantine.
    private func downloadAndVerify(candidate: ReleaseCandidate, runningSigner: CodeSigningIdentity) -> StageOutcome {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return .failure("no Application Support directory")
        }
        let updatesRoot = appSupport.appendingPathComponent("MoveBreak/Updates", isDirectory: true)

        do {
            try StagingPathValidation.ensureSecureDirectory(at: updatesRoot)
        } catch {
            return .failure("could not prepare updates root: \(error.localizedDescription)")
        }

        // Drop staging directories from previous checks so these don't accumulate.
        StagingPathValidation.cleanStagingRoot(at: updatesRoot)

        let stagingDir = updatesRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try StagingPathValidation.ensureSecureDirectory(at: stagingDir)
        } catch {
            return .failure("could not create staging directory: \(error.localizedDescription)")
        }

        let zipPath = stagingDir.appendingPathComponent(assetName)

        if let error = download(from: candidate.downloadURL, to: zipPath) {
            try? fm.removeItem(at: stagingDir)
            return .failure(error)
        }

        do {
            try ArchiveDigestValidation.verifyArchive(at: zipPath, expectedHexDigest: candidate.expectedDigest)
        } catch {
            try? fm.removeItem(at: stagingDir)
            return .failure(error.localizedDescription)
        }

        let unzipResult = Updater.runCommand(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", zipPath.path, stagingDir.path],
            timeout: 60.0
        )
        guard unzipResult.isSuccess else {
            try? fm.removeItem(at: stagingDir)
            let detail = unzipResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure("couldn't unzip download: \(detail.isEmpty ? "exit code \(unzipResult.exitCode)" : detail)")
        }

        try? fm.removeItem(at: zipPath)

        let appURL = stagingDir.appendingPathComponent("MoveBreak.app")
        let expectedBundleID = Bundle.main.bundleIdentifier ?? "com.mike.movebreak"
        let expectedExecutable = (Bundle.main.infoDictionary?["CFBundleExecutable"] as? String) ?? "MoveBreak"

        do {
            try StagingPathValidation.validateContainment(
                appURL: appURL,
                stagingDir: stagingDir,
                expectedExecutable: expectedExecutable
            )
            try BundleMetadataValidation.validateBundleMetadata(
                appURL: appURL,
                expectedBundleID: expectedBundleID,
                expectedExecutable: expectedExecutable,
                releaseTag: candidate.tagName
            )
            try CodeSigningPolicy.verifyStrictCodeSignature(at: appURL)

            let candidateSignerResult = CodeSigningPolicy.inspect(at: appURL)
            guard case .success(let candidateSigner) = candidateSignerResult else {
                throw SigningTrustError.candidateSignatureInvalid("could not read code signature information")
            }
            try CodeSigningPolicy.verifySignerContinuity(running: runningSigner, candidate: candidateSigner)
        } catch {
            try? fm.removeItem(at: stagingDir)
            return .failure(error.localizedDescription)
        }

        // URLSession-downloaded files carry com.apple.quarantine; the bundle isn't
        // notarized, so Gatekeeper would block it on relaunch unless this is cleared.
        // Clear quarantine ONLY after every signature, digest, and containment check succeeds.
        let xattrResult = Updater.runCommand(
            executable: "/usr/bin/xattr",
            arguments: ["-dr", "com.apple.quarantine", appURL.path],
            timeout: 30.0
        )
        guard xattrResult.isSuccess else {
            try? fm.removeItem(at: stagingDir)
            return .failure("couldn't clear quarantine flag")
        }

        return .success(appURL)
    }

    private func download(from url: URL, to destination: URL) -> String? {
        var request = URLRequest(url: url)
        request.setValue("MoveBreak-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let semaphore = DispatchSemaphore(value: 0)
        var failure: String?
        let task = URLSession.shared.downloadTask(with: request) { tempURL, response, error in
            defer { semaphore.signal() }
            if let error {
                failure = error.localizedDescription
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let tempURL else {
                failure = "bad download response"
                return
            }
            do {
                try FileManager.default.moveItem(at: tempURL, to: destination)
            } catch {
                failure = "couldn't save download: \(error.localizedDescription)"
            }
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 120) == .timedOut {
            task.cancel()
            failure = "download timed out after 120 seconds"
        }
        return failure
    }

    // MARK: - Install

    private func performSwapAndRelaunch(from stagedURL: URL) {
        isBusy = true
        checkTimer?.invalidate()

        let currentURL = URL(fileURLWithPath: Bundle.main.bundlePath)
        do {
            try FileManager.default.replaceItem(
                at: currentURL, withItemAt: stagedURL,
                backupItemName: nil, options: [], resultingItemURL: nil
            )
        } catch {
            log("install failed: \(error.localizedDescription) — will retry once idle again")
            isBusy = false
            checkTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
                self?.checkForUpdate()
            }
            return
        }

        log("installed \(stagedVersion ?? "update"), relaunching")
        relaunch(at: currentURL)
    }

    private func relaunch(at appURL: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { [weak self] _, error in
            onMain {
                guard let self else { return }
                if let error {
                    self.log("relaunch failed: \(error.localizedDescription)")
                    self.isBusy = false
                    return
                }
                // Give the new instance a moment to fully start — claim the status item,
                // register its RemoteControl listener — before this one exits.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    // MARK: - Helpers

    struct ProcessResult {
        let exitCode: Int32
        let timedOut: Bool
        let stdout: String
        let stderr: String

        var isSuccess: Bool { !timedOut && exitCode == 0 }
    }

    static func runCommand(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 30.0
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var outData = Data()
        var errData = Data()
        let pipeQueue = DispatchQueue(label: "com.mike.movebreak.process-pipe")

        stdoutPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if !d.isEmpty { pipeQueue.sync { outData.append(d) } }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if !d.isEmpty { pipeQueue.sync { errData.append(d) } }
        }

        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, timedOut: false, stdout: "", stderr: error.localizedDescription)
        }

        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            sema.signal()
        }

        var timedOut = false
        if sema.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = sema.wait(timeout: .now() + 2.0)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let remainingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        pipeQueue.sync {
            outData.append(remainingOut)
            errData.append(remainingErr)
        }

        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        return ProcessResult(
            exitCode: process.terminationStatus,
            timedOut: timedOut,
            stdout: outStr,
            stderr: errStr
        )
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[Updater] \(message)\n".utf8))
    }
}

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
            guard !part.isEmpty, part.allSatisfy({ $0.isNumber }), let _ = Int(part) else {
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
        case .fileUnreadable(let msg):
            return "failed to read archive for digest computation: \(msg)"
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
        case .internalSymlinkEscapes(let path, let dest):
            return "bundle contains symlink '\(path)' pointing outside staging directory to '\(dest)'"
        case .invalidAppStructure(let msg):
            return "invalid app bundle structure: \(msg)"
        }
    }
}

enum StagingPathValidation {
    static func ensureSecureDirectory(at url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        _ = chmod(url.path, 0o700)
    }

    static func cleanStagingRoot(at url: URL) {
        let fm = FileManager.default
        if let existing = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            for item in existing {
                try? fm.removeItem(at: item)
            }
        }
    }

    static func validateContainment(
        appURL: URL,
        stagingDir: URL,
        expectedExecutable: String = "MoveBreak"
    ) throws {
        let fm = FileManager.default
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

        if let enumerator = fm.enumerator(at: appURL, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: []) {
            for case let itemURL as URL in enumerator {
                var itemStat = stat()
                if lstat(itemURL.path, &itemStat) == 0 && (itemStat.st_mode & S_IFMT) == S_IFLNK {
                    let dest = (itemURL.resolvingSymlinksInPath().path as NSString).standardizingPath
                    if !dest.hasPrefix(canonicalStaging + "/") && dest != canonicalStaging {
                        throw StagingPathError.internalSymlinkEscapes(path: itemURL.path, destination: dest)
                    }
                }
            }
        }

        let execURL = appURL.appendingPathComponent("Contents/MacOS/\(expectedExecutable)")
        var execStat = stat()
        guard lstat(execURL.path, &execStat) == 0 else {
            throw StagingPathError.invalidAppStructure("missing executable at \(execURL.path)")
        }
        guard (execStat.st_mode & S_IFMT) == S_IFREG else {
            throw StagingPathError.invalidAppStructure("executable at \(execURL.path) is not a regular file")
        }
        guard (execStat.st_mode & 0o111) != 0 else {
            throw StagingPathError.invalidAppStructure("executable at \(execURL.path) is not marked executable")
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
        case .unreadableInfoPlist(let msg):
            return "failed to read Info.plist: \(msg)"
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
              let plistObj = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let plist = plistObj as? [String: Any] else {
            throw BundleMetadataError.unreadableInfoPlist("cannot parse Contents/Info.plist")
        }

        guard let bundleID = plist["CFBundleIdentifier"] as? String, bundleID == expectedBundleID else {
            throw BundleMetadataError.bundleIdentifierMismatch(
                expected: expectedBundleID,
                actual: (plist["CFBundleIdentifier"] as? String) ?? "missing"
            )
        }

        guard let execName = plist["CFBundleExecutable"] as? String, execName == expectedExecutable else {
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
        case .runningAppAdHoc(let msg):
            return "running app is ad-hoc signed; automatic update installation is disabled (\(msg))"
        case .runningAppNoCertificate(let msg):
            return "running app has no code signing certificate; automatic update installation is disabled (\(msg))"
        case .candidateSignatureInvalid(let msg):
            return "candidate bundle signature verification failed: \(msg)"
        case .candidateAdHoc(let msg):
            return "candidate bundle is ad-hoc signed, rejecting: \(msg)"
        case .candidateNoCertificate(let msg):
            return "candidate bundle has no signing certificate, rejecting: \(msg)"
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
        var infoCF: CFDictionary?
        let status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF)
        guard status == errSecSuccess, let info = infoCF as? [String: Any] else {
            return .failure(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }
        let flags = info[kSecCodeInfoFlags as String] as? UInt32 ?? 0
        let isAdHoc = (flags & SecCodeSignatureFlags.adhoc.rawValue) != 0
        let bundleID = info[kSecCodeInfoIdentifier as String] as? String

        var leafData: Data? = nil
        var leafSubject: String? = nil
        if let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first {
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
        processRunner: (String, [String], TimeInterval) -> Updater.ProcessResult = Updater.runCommand
    ) throws {
        let result = processRunner("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path], 30.0)
        if result.timedOut {
            throw SigningTrustError.candidateSignatureInvalid("codesign verification timed out after 30 seconds")
        }
        guard result.isSuccess else {
            let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SigningTrustError.candidateSignatureInvalid(msg.isEmpty ? "exit code \(result.exitCode)" : msg)
        }
    }

    static func verifySignerContinuity(
        running: CodeSigningIdentity,
        candidate: CodeSigningIdentity
    ) throws {
        if running.isAdHoc || running.leafCertificateData == nil {
            throw SigningTrustError.runningAppAdHoc("running build is ad-hoc signed (requires \"MoveBreak Signing\" certificate)")
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
            } else {
                throw SigningTrustError.certificateDataMismatch
            }
        }
    }
}

// MARK: - SemVer

/// Dot-separated integer version comparison. Tolerates a leading "v" and a non-numeric
/// suffix (so "v1.2.0", "1.2.0-test" both parse as [1, 2, 0]), and fails closed — an
/// unparseable version is never treated as newer.
enum SemVer {
    static func components(from raw: String) -> [Int]? {
        var s = raw
        if s.hasPrefix("v") { s.removeFirst() }
        if let cut = s.firstIndex(where: { !($0.isNumber || $0 == ".") }) {
            s = String(s[s.startIndex..<cut])
        }
        guard !s.isEmpty else { return nil }

        var result: [Int] = []
        for part in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(part) else { return nil }
            result.append(n)
        }
        return result
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let c = components(from: candidate), let cur = components(from: current) else { return false }
        for i in 0..<max(c.count, cur.count) {
            let a = i < c.count ? c[i] : 0
            let b = i < cur.count ? cur[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    static func areEqual(_ a: String, _ b: String) -> Bool {
        guard let ca = components(from: a), let cb = components(from: b) else { return false }
        let maxLen = max(ca.count, cb.count)
        for i in 0..<maxLen {
            let va = i < ca.count ? ca[i] : 0
            let vb = i < cb.count ? cb[i] : 0
            if va != vb { return false }
        }
        return true
    }
}
