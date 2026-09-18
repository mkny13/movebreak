import Foundation

enum GroundworkSelfTests {
    private final class Cancellation: GroundworkRequestCancellation {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    private final class Transport: GroundworkTransport {
        var request: URLRequest?
        var sendCount = 0
        let cancellation = Cancellation()
        var responseData: Data?
        var status = 200
        var error: Error?

        func send(
            _ request: URLRequest,
            completion: @escaping (Data?, URLResponse?, Error?) -> Void
        ) -> GroundworkRequestCancellation {
            self.request = request
            sendCount += 1
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json; charset=utf-8"]
            )
            completion(responseData, response, error)
            return cancellation
        }
    }

    private final class KeychainBackend: KeychainStorageBackend {
        var values: [String: Data] = [:]
        var writeError: Error?
        func get(account: String, service: String) throws -> Data? { values["\(service)|\(account)"] }
        func set(data: Data, account: String, service: String) throws {
            if let writeError { throw writeError }
            values["\(service)|\(account)"] = data
        }
        func delete(account: String, service: String) throws { values.removeValue(forKey: "\(service)|\(account)") }
    }

    private static let responseJSON = """
    {
      "schemaVersion": 1,
      "generatedAt": "2026-09-17T14:30:00.000Z",
      "routine": {
        "id": "routine-42",
        "title": "Desk reset",
        "durationMinutes": 5,
        "locationId": "office",
        "posture": "standing",
        "items": [{
          "id": "item-1",
          "exerciseId": "exercise-calf",
          "prescriptionId": "rx-7",
          "name": "Calf Raise",
          "cues": ["Rise slowly", "Keep pressure even"],
          "plannedDose": {"sets": 2, "reps": 8, "holdSeconds": null, "side": "bilateral"},
          "inclusionReasons": ["desk break", "current day load"],
          "treadmillSafety": "pause_belt",
          "warnings": [{
            "ruleId": "rule-achilles",
            "message": "Stop if pain increases",
            "rationale": "Protect irritated tissue",
            "source": "active clinical gate"
          }]
        }],
        "warnings": []
      }
    }
    """

    private static func response() throws -> GroundworkRoutineResponse {
        try GroundworkCoding.decoder().decode(GroundworkRoutineResponse.self, from: Data(responseJSON.utf8))
    }

    private static func client(transport: Transport) throws -> GroundworkClient {
        try GroundworkClient(
            baseURL: URL(string: "https://groundwork.example/")!,
            token: "SENTINEL_GROUNDWORK_TOKEN",
            transport: transport
        )
    }

    private static func runContractAndTransportCases() -> Int {
        let reporter = SelfTestReporter()
        do {
            let decoded = try response()
            try decoded.validate()
            reporter.check("v1 routine fixture preserves canonical IDs", decoded.routine?.items.first?.exerciseID == "exercise-calf" && decoded.routine?.items.first?.prescriptionID == "rx-7")
            reporter.check("v1 routine fixture preserves dose, warnings and authored order", decoded.routine?.items.first?.plannedDose.reps == 8 && decoded.routine?.items.first?.warnings.first?.ruleID == "rule-achilles")
        } catch {
            reporter.check("v1 routine fixture decodes and validates", false, detail: "\(error)")
        }

        let transport = Transport()
        transport.responseData = Data(responseJSON.utf8)
        do {
            let api = try client(transport: transport)
            let bounded = try GroundworkClient(
                baseURL: URL(string: "https://groundwork.example")!,
                token: "token",
                timeout: 500,
                transport: transport
            )
            reporter.check("request timeout is bounded", bounded.timeout == 30)
            var result: Result<GroundworkRoutineResponse, GroundworkClientError>?
            let cancellation = api.fetchRoutine(locationID: "office", durationMinutes: 5) { result = $0 }
            let components = transport.request?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            reporter.check("GET uses documented path and query", transport.request?.url?.path == "/api/integrations/movebreak/routine" && components?.queryItems?.contains(URLQueryItem(name: "durationMinutes", value: "5")) == true)
            reporter.check("GET sends bearer credential only in header", transport.request?.value(forHTTPHeaderField: "Authorization") == "Bearer SENTINEL_GROUNDWORK_TOKEN" && transport.request?.url?.absoluteString.contains("SENTINEL") == false)
            if case .success(let value) = result {
                reporter.check("GET returns validated routine", value.routine?.id == "routine-42")
            } else { reporter.check("GET returns validated routine", false) }
            cancellation?.cancel()
            reporter.check("request cancellation reaches injected transport", transport.cancellation.cancelled)
        } catch {
            reporter.check("Groundwork client initializes", false, detail: "\(error)")
        }

        let cases: [(Int, Error?, GroundworkClientError)] = [
            (401, nil, .authentication),
            (429, nil, .retryable(status: 429)),
            (503, nil, .retryable(status: 503)),
            (200, URLError(.timedOut), .timedOut),
            (200, URLError(.cancelled), .cancelled),
        ]
        for (status, error, expected) in cases {
            let mock = Transport()
            mock.status = status
            mock.error = error
            mock.responseData = Data(responseJSON.utf8)
            var actual: GroundworkClientError?
            if let api = try? client(transport: mock) {
                _ = api.fetchRoutine(locationID: "office", durationMinutes: 5) {
                    if case .failure(let failure) = $0 { actual = failure }
                }
            }
            reporter.check("typed transport failure \(expected)", expected: expected, actual: actual)
        }

        for (name, json, expected): (String, String, GroundworkClientError) in [
            ("malformed JSON", "{bad", .malformedResponse),
            ("unsupported schema", responseJSON.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2"), .unsupportedSchema(2)),
        ] {
            let mock = Transport()
            mock.responseData = Data(json.utf8)
            var actual: GroundworkClientError?
            if let api = try? client(transport: mock) {
                _ = api.fetchRoutine(locationID: "office", durationMinutes: 5) {
                    if case .failure(let failure) = $0 { actual = failure }
                }
            }
            reporter.check(name, expected: expected, actual: actual)
        }

        let empty = responseJSON.replacingOccurrences(
            of: responseJSON[responseJSON.range(of: "\"routine\":")!.upperBound...].dropLast(2),
            with: " null\n"
        )
        do {
            let decoded = try GroundworkCoding.decoder().decode(GroundworkRoutineResponse.self, from: Data(empty.utf8))
            try decoded.validate()
            reporter.check("valid empty response remains distinguishable", decoded.routine == nil)
        } catch {
            reporter.check("valid empty response remains distinguishable", false, detail: "\(error)")
        }

        let original = URLRequest(url: URL(string: "https://groundwork.example/start")!)
        var crossOrigin = URLRequest(url: URL(string: "https://attacker.example/steal")!)
        crossOrigin.setValue("Bearer sentinel", forHTTPHeaderField: "Authorization")
        let downgrade = URLRequest(url: URL(string: "http://groundwork.example/steal")!)
        let sameOrigin = URLRequest(url: URL(string: "https://groundwork.example/next")!)
        reporter.check("cross-origin redirect is rejected before credential forwarding", GroundworkURLSessionTransport.redirectedRequest(from: original, proposed: crossOrigin) == nil)
        reporter.check("HTTPS downgrade redirect is rejected", GroundworkURLSessionTransport.redirectedRequest(from: original, proposed: downgrade) == nil)
        reporter.check("same-origin HTTPS redirect is allowed", GroundworkURLSessionTransport.redirectedRequest(from: original, proposed: sameOrigin) != nil)
        return reporter.failureCount
    }

    private static func runCompletionCases() -> Int {
        let reporter = SelfTestReporter()
        do {
            let routine = try response().routine!
            let sessionID = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
            let started = Date(timeIntervalSince1970: 1_700_000_000)
            let payload = GroundworkCompletionRequest(
                schemaVersion: 1,
                clientSessionID: sessionID,
                startedAt: started,
                finishedAt: started.addingTimeInterval(300),
                provenance: .cached,
                routineSnapshot: GroundworkRoutineSnapshot(routine: routine),
                checkedItemIDs: ["item-1"],
                completedItems: [GroundworkCompletedItem(
                    itemID: "item-1",
                    actualDose: GroundworkActualDose(sets: 2, reps: 7, holdSeconds: nil, side: "bilateral")
                )],
                warningOverrides: [GroundworkWarningOverride(ruleID: "rule-achilles", reason: "Cleared by PT")]
            )
            let receipt = "{\"schemaVersion\":1,\"clientSessionId\":\"\(sessionID.uuidString)\",\"acceptedAt\":\"2026-09-17T15:00:00.000Z\",\"duplicate\":false}"
            let mock = Transport()
            mock.responseData = Data(receipt.utf8)
            var succeeded = false
            _ = try client(transport: mock).postCompletion(payload) {
                if case .success = $0 { succeeded = true }
            }
            let body = mock.request?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            reporter.check("completion POST uses session endpoint", mock.request?.httpMethod == "POST" && mock.request?.url?.path == "/api/integrations/movebreak/session")
            reporter.check("completion body preserves session UUID and provenance", body?["clientSessionId"] as? String == sessionID.uuidString && body?["provenance"] as? String == "cached")
            let actualDose = (body?["completedItems"] as? [[String: Any]])?.first?["actualDose"] as? [String: Any]
            reporter.check("completion body preserves confirmed actual dose and explicit null observations", actualDose?["reps"] as? Int == 7 && actualDose?["holdSeconds"] is NSNull && (body?["warningOverrides"] as? [[String: Any]])?.first?["reason"] as? String == "Cleared by PT")
            reporter.check("matching completion receipt succeeds", succeeded)

            let localSnapshot = GroundworkRoutineSnapshot(
                routineID: nil,
                title: "Local stretch",
                durationMinutes: 3,
                locationID: nil,
                posture: nil,
                items: [GroundworkRoutineSnapshotItem(
                    itemID: "local-neck-roll",
                    exerciseID: nil,
                    prescriptionID: nil,
                    name: "Neck Roll",
                    cues: [],
                    plannedDose: nil,
                    warnings: []
                )],
                warnings: []
            )
            let localPayload = GroundworkCompletionRequest(
                schemaVersion: 1,
                clientSessionID: UUID(),
                startedAt: started,
                finishedAt: started.addingTimeInterval(60),
                provenance: .local,
                routineSnapshot: localSnapshot,
                checkedItemIDs: ["local-neck-roll"],
                completedItems: [GroundworkCompletedItem(
                    itemID: "local-neck-roll",
                    actualDose: GroundworkActualDose(sets: nil, reps: nil, holdSeconds: nil, side: nil)
                )],
                warningOverrides: []
            )
            try localPayload.validate()
            let localBody = try GroundworkCoding.encoder().encode(localPayload)
            let localJSON = try JSONSerialization.jsonObject(with: localBody) as? [String: Any]
            let localRoutine = localJSON?["routineSnapshot"] as? [String: Any]
            let localItem = (localRoutine?["items"] as? [[String: Any]])?.first
            reporter.check(
                "local fallback snapshot remains unmapped without fabricated dose",
                localJSON?["provenance"] as? String == "local"
                    && localItem?["exerciseId"] == nil
                    && localItem?["prescriptionId"] == nil
                    && localItem?["plannedDose"] == nil
            )
        } catch {
            reporter.check("completion request construction", false, detail: "\(error)")
        }
        return reporter.failureCount
    }

    private static func runCacheCases() -> Int {
        let reporter = SelfTestReporter()
        let fixture = SelfTestTemporaryDirectory(prefix: "movebreak-groundwork-cache")
        do {
            try fixture.create()
            let cacheURL = fixture.url.appendingPathComponent("cache")
            let origin = GroundworkOrigin(url: URL(string: "https://groundwork.example")!)!
            let otherOrigin = GroundworkOrigin(url: URL(string: "https://other.example")!)!
            let generated = try response()
            let cachedAt = Date(timeIntervalSince1970: 1_700_000_000)
            try GroundworkRoutineCache(directoryURL: cacheURL).store(
                generated, origin: origin, locationID: "office", durationMinutes: 5, cachedAt: cachedAt
            )
            let restarted = GroundworkRoutineCache(directoryURL: cacheURL)
            if case .found(let cached) = restarted.load(origin: origin, locationID: "office", durationMinutes: 5) {
                reporter.check("routine cache survives restart with explicit offline provenance", cached.response.routine?.id == "routine-42" && cached.cachedAt == cachedAt && cached.label.contains("not revalidated"))
            } else { reporter.check("routine cache survives restart with explicit offline provenance", false) }
            reporter.check("cache key isolates origins", restarted.load(origin: otherOrigin, locationID: "office", durationMinutes: 5) == .missing)

            if case .unavailable(let cached) = restarted.resolve(
                result: .failure(.retryable(status: 503)),
                origin: origin,
                locationID: "office",
                durationMinutes: 5,
                localRoutines: []
            ) {
                reporter.check("transport outage offers timestamped not-revalidated cache", cached?.label.contains("not revalidated") == true)
            } else { reporter.check("transport outage offers timestamped not-revalidated cache", false) }

            if case .authFailed = restarted.resolve(
                result: .failure(.authentication),
                origin: origin,
                locationID: "office",
                durationMinutes: 5,
                localRoutines: []
            ) {
                reporter.check("authentication failure remains distinct from outage fallback", true)
            } else { reporter.check("authentication failure remains distinct from outage fallback", false) }

            if let file = try FileManager.default.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: nil).first {
                try Data("corrupt".utf8).write(to: file)
                reporter.check("corrupt cache is reported separately", restarted.load(origin: origin, locationID: "office", durationMinutes: 5) == .corrupt)
            } else { reporter.check("cache file exists", false) }

            let local: [Routine] = []
            if case .unconfigured(_, let label) = restarted.resolve(result: nil, origin: nil, locationID: "office", durationMinutes: 5, localRoutines: local) {
                reporter.check("unconfigured startup uses labeled local fallback without polling", label.contains("not clinically revalidated"))
            } else { reporter.check("unconfigured startup uses labeled local fallback without polling", false) }

            let emptyJSON = "{\"schemaVersion\":1,\"generatedAt\":\"2026-09-17T14:30:00.000Z\",\"routine\":null}"
            let empty = try GroundworkCoding.decoder().decode(GroundworkRoutineResponse.self, from: Data(emptyJSON.utf8))
            if case .validEmpty = restarted.resolve(result: .success(empty), origin: origin, locationID: "office", durationMinutes: 5, localRoutines: local) {
                reporter.check("valid empty live result is not replaced by fallback", true)
            } else { reporter.check("valid empty live result is not replaced by fallback", false) }
            try fixture.cleanup()
        } catch {
            reporter.check("routine cache fixtures complete", false, detail: "\(error)")
            try? fixture.cleanup()
        }
        return reporter.failureCount
    }

    private static func runSetupCases() -> Int {
        let reporter = SelfTestReporter()
        reporter.check("production HTTP base URL is rejected", GroundworkSetup.validateBaseURL(URL(string: "http://groundwork.example")!) == nil)
        reporter.check("explicit loopback HTTP base URL is allowed", GroundworkSetup.validateBaseURL(URL(string: "http://127.0.0.1:3000")!) != nil)
        reporter.check("HTTPS URL with credentials is rejected", GroundworkSetup.validateBaseURL(URL(string: "https://user:pass@groundwork.example")!) == nil)

        let suiteName = "com.mike.movebreak.tests.groundwork.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            reporter.check("Groundwork setup defaults fixture", false)
            return reporter.failureCount
        }
        defaults.removePersistentDomain(forName: suiteName)
        let backend = KeychainBackend()
        Preferences.withDefaults(defaults) {
            Keychain.withBackend(backend) {
                backend.writeError = KeychainError.addFailed(status: -1)
                var failedExitCode: Int32 = -1
                let failedOutput = try? SelfTestSupport.captureOutput {
                    failedExitCode = GroundworkSetup.execute(
                        baseURLReader: { "https://groundwork.example" },
                        locationReader: { "office" },
                        durationReader: { "7" },
                        secretReader: { _ in "SENTINEL_SETUP_SECRET" }
                    )
                }
                reporter.check(
                    "Keychain write failure prevents partial Groundwork setup",
                    failedExitCode == 1
                        && Preferences.groundworkBaseURL == nil
                        && Preferences.groundworkLocationID == nil
                )
                reporter.check(
                    "Groundwork setup surfaces Keychain failure without leaking token",
                    failedOutput?.stderr.contains("failed to store token in Keychain") == true
                        && failedOutput?.stderr.contains("SENTINEL_SETUP_SECRET") == false
                        && failedOutput?.stdout.contains("SENTINEL_SETUP_SECRET") == false
                )

                backend.writeError = nil
                var exitCode: Int32 = -1
                let output = try? SelfTestSupport.captureOutput {
                    exitCode = GroundworkSetup.execute(
                        baseURLReader: { "https://groundwork.example" },
                        locationReader: { "office" },
                        durationReader: { "7" },
                        secretReader: { _ in "SENTINEL_SETUP_SECRET" }
                    )
                }
                let origin = GroundworkOrigin(url: URL(string: "https://groundwork.example")!)!
                let saved = try? Keychain.get(forAccount: origin.string, service: GroundworkClient.tokenService)
                reporter.check("setup stores token in distinct origin-bound Keychain item", exitCode == 0 && saved == "SENTINEL_SETUP_SECRET")
                reporter.check("setup persists only non-secret preferences", Preferences.groundworkLocationID == "office" && Preferences.groundworkDurationMinutes == 7 && !String(describing: defaults.persistentDomain(forName: suiteName)).contains("SENTINEL_SETUP_SECRET") && output?.stdout.contains("SENTINEL_SETUP_SECRET") == false && output?.stderr.contains("SENTINEL_SETUP_SECRET") == false)
                let other = try? Keychain.get(forAccount: "https://other.example:443", service: GroundworkClient.tokenService)
                reporter.check("credential cannot leak across origins", other == nil)
            }
        }
        defaults.removePersistentDomain(forName: suiteName)
        return reporter.failureCount
    }

    static func run() -> Int {
        var failures = 0
        print("Groundwork v1 contract, transport failures & redirect boundary")
        failures += runContractAndTransportCases()
        print("")
        print("Groundwork completion request encoding")
        failures += runCompletionCases()
        print("")
        print("Groundwork durable cache & fallback provenance")
        failures += runCacheCases()
        print("")
        print("Groundwork setup, URL policy & Keychain origin isolation")
        failures += runSetupCases()
        return failures
    }
}
