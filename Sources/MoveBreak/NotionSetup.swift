import Foundation

/// One-time credential setup for session logging, run from the terminal:
///
///     MoveBreak --configure-notion
///
/// The integration token goes to the Keychain; the database ID isn't a secret and goes to
/// UserDefaults via Preferences, alongside the app's other tunables.
enum NotionSetup {

    static func run() -> Never {
        let code = execute()
        exit(code)
    }

    /// Executes the setup workflow. Returns process exit code (0 for success, 1 for failure).
    /// Accepts optional reader overrides for deterministic automated testing.
    @discardableResult
    static func execute(
        secretReader: ((String?) -> String?)? = nil,
        databaseIDReader: (() -> String?)? = nil
    ) -> Int32 {
        print("MoveBreak — Notion session logging setup")
        print("Create an internal integration at notion.so/my-integrations, share your")
        print("\"MoveBreak Sessions\" database with it, then paste its details below.\n")

        let tokenPrompt = "Integration token (starts with \"secret_\" or \"ntn_\"): "
        let readToken = secretReader ?? { prompt in SecretInput.readSecret(prompt: prompt) }
        guard let token = readToken(tokenPrompt)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            FileHandle.standardError.write(Data("error: no token entered\n".utf8))
            return 1
        }

        print("Database ID: ", terminator: "")
        fflush(stdout)
        let readDatabaseID = databaseIDReader ?? { readLine() }
        guard let databaseID = readDatabaseID()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !databaseID.isEmpty else {
            FileHandle.standardError.write(Data("error: no database ID entered\n".utf8))
            return 1
        }

        do {
            try Keychain.set(token, forAccount: NotionClient.tokenAccount)
        } catch {
            // Keychain failure prevents partial setup: do not persist databaseID or report success
            FileHandle.standardError.write(Data("error: failed to store token in Keychain: \(error.localizedDescription)\n".utf8))
            return 1
        }

        Preferences.notionDatabaseID = databaseID
        print("\nSaved. Completed routines will now log to Notion.")
        return 0
    }
}
