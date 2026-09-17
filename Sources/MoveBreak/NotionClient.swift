import Foundation

/// Pushes completed sessions to a Notion database. The app's only network client — there's
/// nothing else to reuse.
enum NotionClient {
    private static let apiVersion = "2022-06-28"
    static let tokenAccount = "integrationToken"

    enum ClientError: Error {
        case missingCredentials
        case badResponse(Int, String)
    }

    static func createSessionPage(
        _ record: SessionRecord,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let token = try? Keychain.get(forAccount: tokenAccount),
              let databaseID = Preferences.notionDatabaseID else {
            completion(.failure(ClientError.missingCredentials))
            return
        }

        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/pages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body(for: record, databaseID: databaseID))

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(ClientError.badResponse(-1, "no response")))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(.failure(ClientError.badResponse(http.statusCode, message)))
                return
            }
            completion(.success(()))
        }.resume()
    }

    private static func body(for record: SessionRecord, databaseID: String) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        let entryTitle = "\(record.routineTitle) — \(dateFormatter.string(from: record.date))"

        return [
            "parent": ["database_id": databaseID],
            "properties": [
                "Entry": ["title": [["text": ["content": entryTitle]]]],
                "Date": ["date": ["start": formatter.string(from: record.date)]],
                "Routine": ["select": ["name": record.routineTitle]],
                "Exercises Completed": [
                    "rich_text": [["text": ["content": record.exercisesCompleted.joined(separator: "\n")]]]
                ],
                "Completed": ["number": record.completedCount],
                "Total": ["number": record.totalCount],
                "Est. Duration (min)": ["number": record.estimatedMinutes],
            ],
        ]
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()
}
