import Darwin
import Foundation

enum GroundworkSetup {
    typealias LineReader = () -> String?

    static func run() -> Never {
        exit(execute())
    }

    @discardableResult
    static func execute(
        baseURLReader: LineReader? = nil,
        locationReader: LineReader? = nil,
        durationReader: LineReader? = nil,
        secretReader: ((String?) -> String?)? = nil
    ) -> Int32 {
        print("MoveBreak — Groundwork setup")
        print("Enter the HTTPS deployment URL, an existing Groundwork location ID, and")
        print("a default break duration. The dedicated token is stored only in Keychain.\n")

        print("Groundwork base URL: ", terminator: "")
        fflush(stdout)
        let readBaseURL = baseURLReader ?? { readLine() }
        guard let rawURL = readBaseURL()?.trimmingCharacters(in: .whitespacesAndNewlines),
              let parsedURL = URL(string: rawURL),
              let baseURL = validateBaseURL(parsedURL),
              let origin = GroundworkOrigin(url: baseURL) else {
            writeError("base URL must be HTTPS (HTTP is limited to an explicit loopback host)")
            return 1
        }

        print("Existing location ID: ", terminator: "")
        fflush(stdout)
        let readLocation = locationReader ?? { readLine() }
        guard let location = readLocation()?.trimmingCharacters(in: .whitespacesAndNewlines),
              validateLocationID(location) else {
            writeError("location ID must be 1–128 URL-safe characters")
            return 1
        }

        print("Default duration in minutes (1–30): ", terminator: "")
        fflush(stdout)
        let readDuration = durationReader ?? { readLine() }
        guard let rawDuration = readDuration()?.trimmingCharacters(in: .whitespacesAndNewlines),
              let duration = Int(rawDuration), (1...30).contains(duration) else {
            writeError("duration must be a whole number from 1 through 30")
            return 1
        }

        let readToken = secretReader ?? { SecretInput.readSecret(prompt: $0) }
        guard let token = readToken("Dedicated MoveBreak bearer token: ")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            writeError("no token entered")
            return 1
        }

        do {
            try Keychain.set(token, forAccount: origin.string, service: GroundworkClient.tokenService)
        } catch {
            writeError("failed to store token in Keychain: \(error.localizedDescription)")
            return 1
        }

        // Persist non-secret settings only after the Keychain write succeeds.
        Preferences.groundworkBaseURL = baseURL
        Preferences.groundworkLocationID = location
        Preferences.groundworkDurationMinutes = duration
        print("\nSaved. Groundwork is configured for \(origin.string).")
        return 0
    }

    static func validateBaseURL(_ url: URL) -> URL? {
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              url.path.isEmpty || url.path == "/" else { return nil }
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = scheme
        components?.host = host
        components?.path = "/"
        return components?.url
    }

    static func validateLocationID(_ value: String) -> Bool {
        guard (1...128).contains(value.count) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    }
}
