import Darwin
import Foundation

enum UpdateSelfTests {
    // MARK: - External Process and Pipe Lifecycle Cases

    private static func runProcessRunnerCases() -> Int {
        let reporter = SelfTestReporter()

        let runner = ProcessRunner(
            terminationGracePeriod: 0.15,
            forceKillGracePeriod: 0.5,
            pollIntervalMicroseconds: 1_000
        )

        let normal = runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'normal stdout'; printf 'normal stderr' >&2"],
            timeout: 2
        )
        reporter.check(
            "process runner captures normal stdout and stderr",
            normal.isSuccess && normal.stdout == "normal stdout" && normal.stderr == "normal stderr"
        )

        let nonzero = runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'failure detail' >&2; exit 23"],
            timeout: 2
        )
        reporter.check(
            "process runner preserves nonzero exit and stderr",
            !nonzero.timedOut && nonzero.exitCode == 23 && nonzero.stderr == "failure detail"
        )

        let missing = runner.run(
            executable: "/definitely/missing/movebreak-test-executable",
            arguments: [],
            timeout: 0.1
        )
        reporter.check(
            "missing executable returns structured launch failure",
            !missing.timedOut
                && missing.exitCode == ProcessResult.unavailableExitCode
                && !missing.stderr.isEmpty
        )

        let noisyCommand = """
        i=0
        while [ "$i" -lt 5000 ]; do
          printf 'stdout-%05d-xxxxxxxxxxxxxxxx\n' "$i"
          printf 'stderr-%05d-yyyyyyyyyyyyyyyy\n' "$i" >&2
          i=$((i + 1))
        done
        """
        let noisy = runner.run(
            executable: "/bin/sh",
            arguments: ["-c", noisyCommand],
            timeout: 5
        )
        reporter.check(
            "high-volume stdout and stderr drain without truncation",
            noisy.isSuccess
                && noisy.stdout.contains("stdout-00000-")
                && noisy.stdout.contains("stdout-04999-")
                && noisy.stderr.contains("stderr-00000-")
                && noisy.stderr.contains("stderr-04999-")
                && noisy.stdout.split(separator: "\n").count == 5000
                && noisy.stderr.split(separator: "\n").count == 5000,
            detail: "stdout=\(noisy.stdout.utf8.count) bytes stderr=\(noisy.stderr.utf8.count) bytes"
        )

        let processFixture = SelfTestTemporaryDirectory(prefix: "movebreak-process-runner")
        let fixtureDir = processFixture.url
        let ignoresTermURL = fixtureDir.appendingPathComponent("ignores-term.sh")
        do {
            try processFixture.create()
            let script = "#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n"
            try Data(script.utf8).write(to: ignoresTermURL)
            guard chmod(ignoresTermURL.path, 0o700) == 0 else {
                reporter.check("termination-resistant helper fixture is executable", false)
                do { try processFixture.cleanup() } catch {
                    reporter.check("process runner fixture cleanup after setup failure", false, detail: "\(error)")
                }
                return reporter.failureCount
            }
        } catch {
            reporter.check("termination-resistant helper fixture is created", false, detail: "\(error)")
            do { try processFixture.cleanup() } catch {
                reporter.check("process runner fixture cleanup after setup failure", false, detail: "\(error)")
            }
            return reporter.failureCount
        }

        let timeoutStart = ProcessInfo.processInfo.systemUptime
        let timedOut = runner.run(executable: ignoresTermURL.path, arguments: [], timeout: 0.1)
        let timeoutDuration = ProcessInfo.processInfo.systemUptime - timeoutStart
        reporter.check(
            "termination-resistant process is force-killed within the bound",
            timedOut.timedOut
                && timedOut.exitCode == ProcessResult.unavailableExitCode
                && timeoutDuration < 1.25,
            detail: String(format: "completed in %.3fs", timeoutDuration)
        )

        // Repeat every lifecycle class while comparing the current descriptor table.
        // This catches leaked read/write pipe ends on success, failure, and timeout.
        let descriptorsBefore = SelfTestSupport.openFileDescriptorCount()
        var repeatsPassed = true
        for _ in 0..<12 {
            repeatsPassed = repeatsPassed && runner.run(
                executable: "/bin/sh", arguments: ["-c", "printf ok"], timeout: 1
            ).isSuccess
            repeatsPassed = repeatsPassed && runner.run(
                executable: "/bin/sh", arguments: ["-c", "printf bad >&2; exit 7"], timeout: 1
            ).exitCode == 7
            repeatsPassed = repeatsPassed && runner.run(
                executable: "/missing/movebreak-repeat", arguments: [], timeout: 0.1
            ).exitCode == ProcessResult.unavailableExitCode
            let repeatedTimeout = runner.run(
                executable: ignoresTermURL.path, arguments: [], timeout: 0.02
            )
            repeatsPassed = repeatsPassed && repeatedTimeout.timedOut
        }
        let descriptorsAfter = SelfTestSupport.openFileDescriptorCount()
        reporter.check("repeated process runs leave file-descriptor count stable",
              repeatsPassed && descriptorsAfter == descriptorsBefore,
              detail: "before=\(descriptorsBefore), after=\(descriptorsAfter)")

        do {
            try processFixture.cleanup()
            reporter.check("process runner temporary fixture is removed", true)
        } catch {
            reporter.check("process runner temporary fixture is removed", false, detail: "\(error)")
        }

        return reporter.failureCount
    }

    // MARK: - Automatic Update Trust Boundary & Verification Cases

    private static func runUpdateTrustCases() -> Int {
        let reporter = SelfTestReporter()

        func fixtureStep(_ name: String, _ operation: () throws -> Void) -> Bool {
            do {
                try operation()
                return true
            } catch {
                reporter.check(name, false, detail: "\(error)")
                return false
            }
        }

        // 1. Release Tag Validation
        let validTags = ["v1.1", "v1.2.0", "v2.0", "v10.12.3", "v0.1"]
        for tag in validTags {
            reporter.check("valid release tag '\(tag)' accepted", passed: ReleaseValidation.validateTag(tag))
        }

        let maliciousTags = [
            "../../evil",
            "v1.1/../../etc",
            "v1.1/escape",
            "../v1.2",
            "v1.1\\traversal",
            "v1.1\0null",
            "v1.1 ",
            " v1.1",
            "1.1",
            "v1",
            "v1.2.3.4",
            "v",
            "",
            "v1.1-beta",
            "v1.2.0?query=1",
            "v1.2.0#fragment"
        ]
        for tag in maliciousTags {
            reporter.check("malicious/invalid tag '\(tag)' rejected", passed: !ReleaseValidation.validateTag(tag))
        }

        // 2. Download URL Validation
        let expectedRepo = "mkny13/movebreak"
        let expectedTag = "v1.2.0"
        let expectedAsset = "MoveBreak.app.zip"

        let validURL = URL(string: "https://github.com/mkny13/movebreak/releases/download/v1.2.0/MoveBreak.app.zip")!
        reporter.check(
            "valid release asset HTTPS URL accepted",
            passed: ReleaseValidation.validateDownloadURL(url: validURL, repo: expectedRepo, tag: expectedTag, assetName: expectedAsset)
        )

        let invalidURLs: [(String, String)] = [
            ("http://github.com/mkny13/movebreak/releases/download/v1.2.0/MoveBreak.app.zip", "insecure HTTP scheme rejected"),
            ("https://evilgithub.com/mkny13/movebreak/releases/download/v1.2.0/MoveBreak.app.zip", "deceptive host evilgithub.com rejected"),
            ("https://github.com.attacker.com/mkny13/movebreak/releases/download/v1.2.0/MoveBreak.app.zip", "subdomain spoof rejected"),
            ("https://attacker.com/mkny13/movebreak/releases/download/v1.2.0/MoveBreak.app.zip", "external host rejected"),
            ("https://github.com/otheruser/movebreak/releases/download/v1.2.0/MoveBreak.app.zip", "wrong repository owner rejected"),
            ("https://github.com/mkny13/otherrepo/releases/download/v1.2.0/MoveBreak.app.zip", "wrong repository name rejected"),
            ("https://github.com/mkny13/movebreak/releases/download/v1.3.0/MoveBreak.app.zip", "tag mismatch in download URL rejected"),
            ("https://github.com/mkny13/movebreak/releases/download/v1.2.0/Other.zip", "asset name mismatch rejected"),
            ("https://github.com:8443/mkny13/movebreak/releases/download/v1.2.0/MoveBreak.app.zip", "non-standard port rejected"),
            ("https://user:pass@github.com/mkny13/movebreak/releases/download/v1.2.0/MoveBreak.app.zip", "credentials in URL rejected"),
            ("https://github.com/mkny13/movebreak/releases/download/v1.2.0/MoveBreak.app.zip?extra=1", "query parameters rejected"),
            ("https://github.com/mkny13/movebreak/releases/download/v1.2.0/MoveBreak.app.zip#frag", "URL fragment rejected")
        ]
        for (rawURL, label) in invalidURLs {
            let url = URL(string: rawURL)!
            reporter.check(label, passed: !ReleaseValidation.validateDownloadURL(url: url, repo: expectedRepo, tag: expectedTag, assetName: expectedAsset))
        }

        // 3. Digest Parsing
        let validHex = "f8cbaae40ff571b5cf019035e90a601ea90efa3f3c6643a10b0726277dbd19a9"
        reporter.check(
            "valid sha256: digest parsed and lowercased",
            passed: ReleaseValidation.parseDigest("sha256:\(validHex.uppercased())") == validHex
        )

        let invalidDigests = [
            nil,
            "",
            "   ",
            "md5:f8cbaae40ff571b5cf019035e90a601e",
            "sha256:tooshort",
            "sha256:\(String(repeating: "a", count: 63))",
            "sha256:\(String(repeating: "a", count: 65))",
            "sha256:\(String(repeating: "g", count: 64))",
            validHex
        ]
        for (idx, raw) in invalidDigests.enumerated() {
            reporter.check("invalid digest format [\(idx)] rejected", passed: ReleaseValidation.parseDigest(raw) == nil)
        }

        // 4. Release Validation Helper (End-to-end Release JSON)
        let validReleaseJSON = """
        {
            "tag_name": "v1.2.0",
            "assets": [
                {
                    "name": "MoveBreak.app.zip",
                    "browser_download_url": "https://github.com/mkny13/movebreak/releases/download/v1.2.0/MoveBreak.app.zip",
                    "digest": "sha256:\(validHex)"
                }
            ]
        }
        """
        if let data = validReleaseJSON.data(using: .utf8),
           let rel = try? JSONDecoder().decode(GitHubRelease.self, from: data) {
            let candidate = try? ReleaseValidation.validateRelease(
                release: rel,
                repo: expectedRepo,
                assetName: expectedAsset,
                currentVersion: "1.1.0"
            )
            reporter.check("valid release metadata produces ReleaseCandidate", passed: candidate != nil && candidate?.tagName == "v1.2.0")

            var notNewerThrew = false
            do {
                _ = try ReleaseValidation.validateRelease(
                    release: rel,
                    repo: expectedRepo,
                    assetName: expectedAsset,
                    currentVersion: "1.2.0"
                )
            } catch let err as ReleaseValidationError {
                if case .notNewer = err { notNewerThrew = true }
            } catch {}
            reporter.check("older or equal release version rejected", passed: notNewerThrew)
        } else {
            reporter.check("validReleaseJSON decode", passed: false)
        }

        let malformedReleaseJSON = """
        {
            "tag_name": 120,
            "assets": "MoveBreak.app.zip"
        }
        """
        let malformedReleaseData = malformedReleaseJSON.data(using: .utf8)!
        reporter.check(
            "malformed release metadata is rejected during decoding",
            passed: (try? JSONDecoder().decode(GitHubRelease.self, from: malformedReleaseData)) == nil
        )

        let missingAssetJSON = """
        {
            "tag_name": "v1.2.0",
            "assets": [
                {
                    "name": "other.zip",
                    "browser_download_url": "https://github.com/mkny13/movebreak/releases/download/v1.2.0/other.zip",
                    "digest": "sha256:\(validHex)"
                }
            ]
        }
        """
        if let data = missingAssetJSON.data(using: .utf8),
           let rel = try? JSONDecoder().decode(GitHubRelease.self, from: data) {
            var missingAssetThrew = false
            do {
                _ = try ReleaseValidation.validateRelease(
                    release: rel,
                    repo: expectedRepo,
                    assetName: expectedAsset,
                    currentVersion: "1.1.0"
                )
            } catch let err as ReleaseValidationError {
                if case .missingAsset = err { missingAssetThrew = true }
            } catch {}
            reporter.check("missing MoveBreak.app.zip asset rejected", passed: missingAssetThrew)
        }

        // 5. Archive SHA-256 Digest Verification & Tampering
        let updateFixture = SelfTestTemporaryDirectory(prefix: "movebreak-update-test")
        let tempFixtureDir = updateFixture.url
        do {
            try updateFixture.create()
        } catch {
            reporter.check("update fixture directory is created", false, detail: "\(error)")
            return reporter.failureCount
        }

        let sampleArchiveURL = tempFixtureDir.appendingPathComponent("test.zip")
        let testPayload = Data("MoveBreakSecurePayloadData123456789".utf8)
        do {
            try testPayload.write(to: sampleArchiveURL)
        } catch {
            reporter.check("sample update archive is written", false, detail: "\(error)")
        }

        if let computedHex = try? ArchiveDigestValidation.computeSHA256(at: sampleArchiveURL) {
            var verifyPassed = false
            do {
                try ArchiveDigestValidation.verifyArchive(at: sampleArchiveURL, expectedHexDigest: computedHex)
                verifyPassed = true
            } catch {}
            reporter.check("archive SHA-256 computation and matching verification succeed", passed: verifyPassed)

            var mismatchThrew = false
            let wrongHex = "0000000000000000000000000000000000000000000000000000000000000000"
            do {
                try ArchiveDigestValidation.verifyArchive(at: sampleArchiveURL, expectedHexDigest: wrongHex)
            } catch let err as ArchiveDigestError {
                if case .digestMismatch = err { mismatchThrew = true }
            } catch {}
            reporter.check("tampered archive / mismatched SHA-256 digest rejected before swap", passed: mismatchThrew)
        } else {
            reporter.check("computeSHA256 succeeded", passed: false)
        }

        // 6. Staging Directory Permissions (0700)
        let stagingDir = tempFixtureDir.appendingPathComponent("staging", isDirectory: true)
        do {
            try StagingPathValidation.ensureSecureDirectory(at: stagingDir)
            let mode = SelfTestSupport.posixMode(at: stagingDir.path)
            reporter.check("staging directory enforced with mode 0700", passed: mode == 0o700, detail: "got \(String(format: "%o", mode ?? 0))")
        } catch {
            reporter.check("ensureSecureDirectory threw", passed: false, detail: "\(error)")
        }

        // 7. Staging Containment & Symlink Defense
        let appBundleDir = stagingDir.appendingPathComponent("MoveBreak.app", isDirectory: true)
        let macosDir = appBundleDir.appendingPathComponent("Contents/MacOS", isDirectory: true)
        _ = fixtureStep("sample app executable directory is created") {
            try FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)
        }
        let execURL = macosDir.appendingPathComponent("MoveBreak")
        reporter.check(
            "sample app executable is created",
            FileManager.default.createFile(atPath: execURL.path, contents: Data([0xCF, 0xFA, 0xED, 0xFE]), attributes: [.posixPermissions: 0o755])
        )

        var validContainment = false
        do {
            try StagingPathValidation.validateContainment(appURL: appBundleDir, stagingDir: stagingDir)
            validContainment = true
        } catch {}
        reporter.check("valid app bundle inside staging directory passes containment", passed: validContainment)

        let symlinkAppURL = stagingDir.appendingPathComponent("SymlinkEscape.app")
        _ = fixtureStep("escaping app symlink fixture is created") {
            try FileManager.default.createSymbolicLink(at: symlinkAppURL, withDestinationURL: URL(fileURLWithPath: "/Applications"))
        }
        var symlinkAppThrew = false
        do {
            try StagingPathValidation.validateContainment(appURL: symlinkAppURL, stagingDir: stagingDir)
        } catch let err as StagingPathError {
            if case .appIsSymlink = err { symlinkAppThrew = true }
        } catch {}
        reporter.check("symlinked app bundle pointing outside staging rejected", passed: symlinkAppThrew)

        let escapeSymlink = appBundleDir.appendingPathComponent("Contents/Resources/escape_link")
        let resourcesDir = appBundleDir.appendingPathComponent("Contents/Resources", isDirectory: true)
        _ = fixtureStep("sample app resources directory is created") {
            try FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        }
        _ = fixtureStep("internal escaping symlink fixture is created") {
            try FileManager.default.createSymbolicLink(at: escapeSymlink, withDestinationURL: URL(fileURLWithPath: "/etc"))
        }
        var internalSymlinkThrew = false
        do {
            try StagingPathValidation.validateContainment(appURL: appBundleDir, stagingDir: stagingDir)
        } catch let err as StagingPathError {
            if case .internalSymlinkEscapes = err { internalSymlinkThrew = true }
        } catch {}
        reporter.check("bundle with internal symlink escaping staging directory rejected", passed: internalSymlinkThrew)
        _ = fixtureStep("internal escaping symlink fixture is removed") {
            try FileManager.default.removeItem(at: escapeSymlink)
        }

        let outsideAppURL = tempFixtureDir.appendingPathComponent("Outside.app", isDirectory: true)
        let outsideMacOSURL = outsideAppURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        _ = fixtureStep("outside app executable directory is created") {
            try FileManager.default.createDirectory(at: outsideMacOSURL, withIntermediateDirectories: true)
        }
        reporter.check(
            "outside app executable is created",
            FileManager.default.createFile(
                atPath: outsideMacOSURL.appendingPathComponent("MoveBreak").path,
                contents: Data([0xCF, 0xFA, 0xED, 0xFE]),
                attributes: [.posixPermissions: 0o755]
            )
        )
        var outsideAppThrew = false
        do {
            try StagingPathValidation.validateContainment(appURL: outsideAppURL, stagingDir: stagingDir)
        } catch let error as StagingPathError {
            if case .appEscapesStaging = error { outsideAppThrew = true }
        } catch {}
        reporter.check("app bundle outside staging directory rejected", passed: outsideAppThrew)

        _ = fixtureStep("sample executable is removed for missing-file case") {
            try FileManager.default.removeItem(at: execURL)
        }
        var missingExecutableThrew = false
        do {
            try StagingPathValidation.validateContainment(appURL: appBundleDir, stagingDir: stagingDir)
        } catch let error as StagingPathError {
            if case .invalidAppStructure = error { missingExecutableThrew = true }
        } catch {}
        reporter.check("bundle with missing executable rejected as invalid structure", passed: missingExecutableThrew)
        reporter.check(
            "sample executable is recreated",
            FileManager.default.createFile(
                atPath: execURL.path,
                contents: Data([0xCF, 0xFA, 0xED, 0xFE]),
                attributes: [.posixPermissions: 0o755]
            )
        )

        // 8. Bundle Metadata & Version Verification
        let plistURL = appBundleDir.appendingPathComponent("Contents/Info.plist")
        func writePlist(bundleID: String, executable: String, version: String) throws {
            let dict: [String: Any] = [
                "CFBundleIdentifier": bundleID,
                "CFBundleExecutable": executable,
                "CFBundleShortVersionString": version
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: plistURL)
        }

        _ = fixtureStep("valid bundle plist fixture is written") {
            try writePlist(bundleID: "com.mike.movebreak", executable: "MoveBreak", version: "1.2.0")
        }
        var metadataValid = false
        do {
            try BundleMetadataValidation.validateBundleMetadata(
                appURL: appBundleDir,
                expectedBundleID: "com.mike.movebreak",
                expectedExecutable: "MoveBreak",
                releaseTag: "v1.2.0"
            )
            metadataValid = true
        } catch {}
        reporter.check("matching bundle metadata (identifier, executable, version) passes", passed: metadataValid)

        _ = fixtureStep("malformed bundle plist fixture is written") {
            try Data("not a property list".utf8).write(to: plistURL)
        }
        var malformedPlistThrew = false
        do {
            try BundleMetadataValidation.validateBundleMetadata(
                appURL: appBundleDir,
                expectedBundleID: "com.mike.movebreak",
                expectedExecutable: "MoveBreak",
                releaseTag: "v1.2.0"
            )
        } catch let error as BundleMetadataError {
            if case .unreadableInfoPlist = error { malformedPlistThrew = true }
        } catch {}
        reporter.check("malformed bundle Info.plist rejected", passed: malformedPlistThrew)

        _ = fixtureStep("bundle identifier mismatch fixture is written") {
            try writePlist(bundleID: "com.attacker.fakeapp", executable: "MoveBreak", version: "1.2.0")
        }
        var bundleIDMismatchThrew = false
        do {
            try BundleMetadataValidation.validateBundleMetadata(
                appURL: appBundleDir,
                expectedBundleID: "com.mike.movebreak",
                expectedExecutable: "MoveBreak",
                releaseTag: "v1.2.0"
            )
        } catch let err as BundleMetadataError {
            if case .bundleIdentifierMismatch = err { bundleIDMismatchThrew = true }
        } catch {}
        reporter.check("mismatched bundle identifier rejected", passed: bundleIDMismatchThrew)

        _ = fixtureStep("bundle executable mismatch fixture is written") {
            try writePlist(bundleID: "com.mike.movebreak", executable: "WrongExecutable", version: "1.2.0")
        }
        var executableMismatchThrew = false
        do {
            try BundleMetadataValidation.validateBundleMetadata(
                appURL: appBundleDir,
                expectedBundleID: "com.mike.movebreak",
                expectedExecutable: "MoveBreak",
                releaseTag: "v1.2.0"
            )
        } catch let err as BundleMetadataError {
            if case .executableNameMismatch = err { executableMismatchThrew = true }
        } catch {}
        reporter.check("mismatched executable name rejected", passed: executableMismatchThrew)

        _ = fixtureStep("bundle version mismatch fixture is written") {
            try writePlist(bundleID: "com.mike.movebreak", executable: "MoveBreak", version: "1.1.0")
        }
        var versionMismatchThrew = false
        do {
            try BundleMetadataValidation.validateBundleMetadata(
                appURL: appBundleDir,
                expectedBundleID: "com.mike.movebreak",
                expectedExecutable: "MoveBreak",
                releaseTag: "v1.2.0"
            )
        } catch let err as BundleMetadataError {
            if case .versionMismatch = err { versionMismatchThrew = true }
        } catch {}
        reporter.check("mismatched bundle version against release tag rejected", passed: versionMismatchThrew)

        // 9. Code Signing Policy & Leaf Certificate Verification
        let certBytesA = Data([0x30, 0x82, 0x01, 0x0A, 0x02, 0x01, 0x01])
        let certBytesB = Data([0x30, 0x82, 0x01, 0x0A, 0x02, 0x01, 0x02])

        let validRunningIdentity = CodeSigningIdentity(
            isAdHoc: false,
            bundleID: "com.mike.movebreak",
            leafCertificateData: certBytesA,
            leafCertificateSubject: "MoveBreak Signing"
        )
        let matchingCandidateIdentity = CodeSigningIdentity(
            isAdHoc: false,
            bundleID: "com.mike.movebreak",
            leafCertificateData: certBytesA,
            leafCertificateSubject: "MoveBreak Signing"
        )
        let differentCertCandidateIdentity = CodeSigningIdentity(
            isAdHoc: false,
            bundleID: "com.mike.movebreak",
            leafCertificateData: certBytesB,
            leafCertificateSubject: "Untrusted Developer Signing"
        )
        let adhocCandidateIdentity = CodeSigningIdentity(
            isAdHoc: true,
            bundleID: "com.mike.movebreak",
            leafCertificateData: nil,
            leafCertificateSubject: nil
        )
        let adhocRunningIdentity = CodeSigningIdentity(
            isAdHoc: true,
            bundleID: "com.mike.movebreak",
            leafCertificateData: nil,
            leafCertificateSubject: nil
        )

        var certMatchPassed = false
        do {
            try CodeSigningPolicy.verifySignerContinuity(running: validRunningIdentity, candidate: matchingCandidateIdentity)
            certMatchPassed = true
        } catch {}
        reporter.check("matching leaf signing certificate accepted", passed: certMatchPassed)

        var differentCertThrew = false
        do {
            try CodeSigningPolicy.verifySignerContinuity(running: validRunningIdentity, candidate: differentCertCandidateIdentity)
        } catch let err as SigningTrustError {
            if case .certificateMismatch = err { differentCertThrew = true }
        } catch {}
        reporter.check("differently signed candidate bundle rejected before swap", passed: differentCertThrew)

        var adhocCandidateThrew = false
        do {
            try CodeSigningPolicy.verifySignerContinuity(running: validRunningIdentity, candidate: adhocCandidateIdentity)
        } catch let err as SigningTrustError {
            if case .candidateAdHoc = err { adhocCandidateThrew = true }
        } catch {}
        reporter.check("ad-hoc candidate bundle rejected before swap", passed: adhocCandidateThrew)

        var adhocRunningThrew = false
        do {
            try CodeSigningPolicy.verifySignerContinuity(running: adhocRunningIdentity, candidate: matchingCandidateIdentity)
        } catch let err as SigningTrustError {
            if case .runningAppAdHoc = err { adhocRunningThrew = true }
        } catch {}
        reporter.check("ad-hoc running app disables automatic updates and fails closed", passed: adhocRunningThrew)

        // 10. Strict Code Signature Verification on Real Bundles
        var strictInvocation: (String, [String], TimeInterval)?
        var invalidSignatureThrew = false
        do {
            try CodeSigningPolicy.verifyStrictCodeSignature(at: appBundleDir) { executable, arguments, timeout in
                strictInvocation = (executable, arguments, timeout)
                return ProcessResult(exitCode: 1, timedOut: false, stdout: "", stderr: "invalid signature")
            }
        } catch let error as SigningTrustError {
            if case .candidateSignatureInvalid("invalid signature") = error {
                invalidSignatureThrew = true
            }
        } catch {}
        reporter.check(
            "strict code-signature failure rejects candidate",
            passed: invalidSignatureThrew
                && strictInvocation?.0 == "/usr/bin/codesign"
                && strictInvocation?.1 == ["--verify", "--deep", "--strict", appBundleDir.path]
                && strictInvocation?.2 == 30.0
        )

        var signatureTimeoutThrew = false
        do {
            try CodeSigningPolicy.verifyStrictCodeSignature(at: appBundleDir) { _, _, _ in
                ProcessResult(exitCode: ProcessResult.unavailableExitCode, timedOut: true, stdout: "", stderr: "")
            }
        } catch let error as SigningTrustError {
            if case .candidateSignatureInvalid(let message) = error,
               message == "codesign verification timed out after 30 seconds" {
                signatureTimeoutThrew = true
            }
        } catch {}
        reporter.check("strict code-signature timeout rejects candidate", passed: signatureTimeoutThrew)

        let workspaceAppURL = URL(fileURLWithPath: "MoveBreak.app")
        if FileManager.default.fileExists(atPath: workspaceAppURL.path) {
            let inspected = CodeSigningPolicy.inspect(at: workspaceAppURL)
            if case .success(let identity) = inspected {
                reporter.check("workspace MoveBreak.app inspected accurately as ad-hoc signed", passed: identity.isAdHoc)
            } else {
                reporter.check("workspace MoveBreak.app inspected", passed: false)
            }

            var strictVerifyPassed = false
            do {
                try CodeSigningPolicy.verifyStrictCodeSignature(at: workspaceAppURL)
                strictVerifyPassed = true
            } catch {}
            reporter.check("strict code signature verification succeeds on un-tampered bundle", passed: strictVerifyPassed)
        }

        do {
            try updateFixture.cleanup()
            reporter.check("update trust temporary fixture is removed", true)
        } catch {
            reporter.check("update trust temporary fixture is removed", false, detail: "\(error)")
        }

        return reporter.failureCount
    }


    static func run() -> Int {
        var failures = 0
        print("External command output, timeout, and pipe lifecycle")
        failures += runProcessRunnerCases()
        print("")
        print("Automatic update trust boundary, staging containment & code signature verification")
        failures += runUpdateTrustCases()
        return failures
    }
}
