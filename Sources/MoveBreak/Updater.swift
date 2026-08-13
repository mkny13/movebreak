import AppKit
import Foundation

/// Checks GitHub Releases for a newer MoveBreak build and installs it in place once the
/// app is idle. No external dependencies — this project can't use SwiftPM (see
/// scripts/build_app.sh), so this is plain URLSession/Process.
///
/// The app has no fixed install location (install_login_item.sh points a LaunchAgent at
/// wherever it was built), so every install replaces the bundle at its own
/// `Bundle.main.bundlePath` rather than assuming /Applications.
final class Updater {
    static let shared = Updater()
    private init() {}

    /// Set by AppDelegate. Installing only proceeds while this returns true, so an update
    /// never interrupts an active prompt or routine.
    var isSafeToInstall: (() -> Bool)?

    private let repo = "mkny13/movebreak"
    private let assetName = "MoveBreak.app.zip"
    private let checkInterval: TimeInterval = 24 * 60 * 60

    private var checkTimer: Timer?
    private var isBusy = false
    private var stagedAppURL: URL?
    private var stagedVersion: String?

    func start() {
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

    // MARK: - Check

    /// Public so a `--check-update-now` debug invocation can trigger it directly instead
    /// of waiting for the timer.
    func checkForUpdate() {
        guard !isBusy else { return }
        isBusy = true

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub's API 403s requests with no User-Agent.
        request.setValue("MoveBreak-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            onMain {
                guard let self else { return }
                self.handleLatestRelease(data: data, response: response, error: error)
            }
        }.resume()
    }

    private func handleLatestRelease(data: Data?, response: URLResponse?, error: Error?) {
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
        guard let asset = release.assets.first(where: { $0.name == assetName }) else {
            finishCheck(log: "no \(assetName) asset on latest release")
            return
        }

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard SemVer.isNewer(release.tagName, than: currentVersion) else {
            finishCheck(log: nil)
            return
        }
        guard stagedVersion != release.tagName else {
            finishCheck(log: nil)
            return
        }

        log("found \(release.tagName), currently on \(currentVersion) — staging")
        stage(tag: release.tagName, downloadURL: asset.browserDownloadURL)
    }

    private func finishCheck(log message: String?) {
        if let message { log(message) }
        isBusy = false
    }

    // MARK: - Stage

    private enum StageOutcome {
        case success(URL)
        case failure(String)
    }

    private func stage(tag: String, downloadURL: URL) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let outcome = self.downloadAndVerify(tag: tag, downloadURL: downloadURL)
            onMain {
                switch outcome {
                case .success(let appURL):
                    self.stagedAppURL = appURL
                    self.stagedVersion = tag
                    self.log("staged \(tag), will install once idle")
                case .failure(let message):
                    self.log("stage failed: \(message)")
                }
                self.isBusy = false
            }
        }
    }

    /// Runs entirely on a background queue: download, unzip, verify, de-quarantine.
    private func downloadAndVerify(tag: String, downloadURL: URL) -> StageOutcome {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return .failure("no Application Support directory")
        }
        let updatesRoot = appSupport.appendingPathComponent("MoveBreak/Updates", isDirectory: true)
        try? fm.createDirectory(at: updatesRoot, withIntermediateDirectories: true)

        // Drop staging directories from previous checks so these don't accumulate.
        if let existing = try? fm.contentsOfDirectory(at: updatesRoot, includingPropertiesForKeys: nil) {
            for url in existing { try? fm.removeItem(at: url) }
        }

        let destDir = updatesRoot.appendingPathComponent(tag, isDirectory: true)
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let zipPath = destDir.appendingPathComponent(assetName)

        if let error = download(from: downloadURL, to: zipPath) {
            try? fm.removeItem(at: destDir)
            return .failure(error)
        }

        guard run("/usr/bin/ditto", ["-x", "-k", zipPath.path, destDir.path]) else {
            try? fm.removeItem(at: destDir)
            return .failure("couldn't unzip download")
        }

        let appPath = destDir.appendingPathComponent("MoveBreak.app").path
        guard fm.fileExists(atPath: appPath) else {
            try? fm.removeItem(at: destDir)
            return .failure("no MoveBreak.app in downloaded zip")
        }

        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appPath]) else {
            try? fm.removeItem(at: destDir)
            return .failure("downloaded app failed signature verification, discarding")
        }

        // URLSession-downloaded files carry com.apple.quarantine; the bundle isn't
        // notarized, so Gatekeeper would block it on relaunch unless this is cleared.
        guard run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appPath]) else {
            try? fm.removeItem(at: destDir)
            return .failure("couldn't clear quarantine flag")
        }

        return .success(URL(fileURLWithPath: appPath))
    }

    private func download(from url: URL, to destination: URL) -> String? {
        var request = URLRequest(url: url)
        request.setValue("MoveBreak-Updater", forHTTPHeaderField: "User-Agent")

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
        semaphore.wait()
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

    @discardableResult
    private func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[Updater] \(message)\n".utf8))
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

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
}
