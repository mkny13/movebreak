import Foundation

/// One-time credential setup for session logging, run from the terminal:
///
///     MoveBreak --configure-notion
///
/// The integration token goes to the Keychain; the database ID isn't a secret and goes to
/// UserDefaults via Preferences, alongside the app's other tunables.
enum NotionSetup {

    static func run() -> Never {
        print("MoveBreak — Notion session logging setup")
        print("Create an internal integration at notion.so/my-integrations, share your")
        print("\"MoveBreak Sessions\" database with it, then paste its details below.\n")

        print("Integration token (starts with \"secret_\" or \"ntn_\"): ", terminator: "")
        guard let token = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            FileHandle.standardError.write(Data("error: no token entered\n".utf8))
            exit(1)
        }

        print("Database ID: ", terminator: "")
        guard let databaseID = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !databaseID.isEmpty else {
            FileHandle.standardError.write(Data("error: no database ID entered\n".utf8))
            exit(1)
        }

        Keychain.set(token, forAccount: NotionClient.tokenAccount)
        Preferences.notionDatabaseID = databaseID

        print("\nSaved. Completed routines will now log to Notion.")
        exit(0)
    }
}
