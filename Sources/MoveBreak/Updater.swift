import AppKit
import Foundation

struct UpdateDownloadOperation {
    let resume: () -> Void
    let cancel: () -> Void
}

/// Synchronous staging boundary around URLSession's callback-based download API. The caller
/// runs this off the main thread. Cancellation must eventually invoke the supplied completion,
/// allowing a timeout to drain the callback before staging cleanup begins.
final class UpdateDownloader {
    typealias Completion = (URL?, URLResponse?, Error?) -> Void
    typealias StartOperation = (URLRequest, @escaping Completion) -> UpdateDownloadOperation

    private enum Outcome {
        case success
        case failure(String)
    }

    private final class CompletionState {
        private let lock = NSLock()
        private var outcome: Outcome?
        let callbackFinished = DispatchSemaphore(value: 0)

        func finish(
            tempURL: URL?,
            response: URLResponse?,
            error: Error?,
            destination: URL
        ) {
            defer { callbackFinished.signal() }
            lock.withLock {
                guard outcome == nil else { return }

                if let error {
                    removeDestination(destination)
                    outcome = .failure(error.localizedDescription)
                    return
                }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let tempURL else {
                    removeDestination(destination)
                    outcome = .failure("bad download response")
                    return
                }
                do {
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    outcome = .success
                } catch {
                    removeDestination(destination)
                    outcome = .failure("couldn't save download: \(error.localizedDescription)")
                }
            }
        }

        func claimTimeout(destination: URL, timeout: TimeInterval) -> Bool {
            lock.withLock {
                guard outcome == nil else { return false }
                removeDestination(destination)
                outcome = .failure("download timed out after \(Self.timeoutDescription(timeout)) seconds")
                return true
            }
        }

        var failure: String? {
            lock.withLock {
                guard case .failure(let message) = outcome else { return nil }
                return message
            }
        }

        private func removeDestination(_ destination: URL) {
            try? FileManager.default.removeItem(at: destination)
        }

        private static func timeoutDescription(_ timeout: TimeInterval) -> String {
            timeout.rounded(.towardZero) == timeout
                ? String(Int(timeout))
                : String(format: "%g", timeout)
        }
    }

    private let timeout: TimeInterval
    private let startOperation: StartOperation

    init(timeout: TimeInterval = 120, startOperation: @escaping StartOperation = UpdateDownloader.urlSessionOperation) {
        self.timeout = timeout
        self.startOperation = startOperation
    }

    func download(from url: URL, to destination: URL) -> String? {
        var request = URLRequest(url: url)
        request.setValue("MoveBreak-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let state = CompletionState()
        let operation = startOperation(request) { tempURL, response, error in
            state.finish(tempURL: tempURL, response: response, error: error, destination: destination)
        }
        operation.resume()

        if state.callbackFinished.wait(timeout: .now() + timeout) == .timedOut {
            if state.claimTimeout(destination: destination, timeout: timeout) {
                operation.cancel()
            }
            // If completion won at the deadline, it may still be finishing its destination
            // move. If timeout won, cancellation completion must be observed. Either way,
            // staging cleanup cannot race callback-owned filesystem work after this wait.
            state.callbackFinished.wait()
        }
        return state.failure
    }

    private static func urlSessionOperation(
        request: URLRequest,
        completion: @escaping Completion
    ) -> UpdateDownloadOperation {
        let task = URLSession.shared.downloadTask(with: request, completionHandler: completion)
        return UpdateDownloadOperation(resume: { task.resume() }, cancel: { task.cancel() })
    }
}

/// Checks GitHub Releases for a newer MoveBreak build and installs it in place once the
/// app is idle. No external dependencies — this project can't use SwiftPM (see
/// scripts/build_app.sh), so this is plain URLSession/Process/Security.
///
/// The app has no fixed install location (install_login_item.sh points a LaunchAgent at
/// wherever it was built), so every install replaces the bundle at its own
/// `Bundle.main.bundlePath` rather than assuming /Applications.
final class Updater {
    static let shared = Updater()
    private let downloader: UpdateDownloader

    init(downloader: UpdateDownloader = UpdateDownloader()) {
        self.downloader = downloader
    }

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

        if let error = downloader.download(from: candidate.downloadURL, to: zipPath) {
            try? fm.removeItem(at: stagingDir)
            return .failure(error)
        }

        do {
            try ArchiveDigestValidation.verifyArchive(at: zipPath, expectedHexDigest: candidate.expectedDigest)
        } catch {
            try? fm.removeItem(at: stagingDir)
            return .failure(error.localizedDescription)
        }

        let unzipResult = ProcessRunner.run(
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
        let xattrResult = ProcessRunner.run(
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

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[Updater] \(message)\n".utf8))
    }
}
