import Foundation

protocol GroundworkRequestCancellation {
    func cancel()
}

protocol GroundworkTransport {
    @discardableResult
    func send(
        _ request: URLRequest,
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) -> GroundworkRequestCancellation
}

private struct GroundworkTaskCancellation: GroundworkRequestCancellation {
    let task: URLSessionTask
    func cancel() { task.cancel() }
}

final class GroundworkURLSessionTransport: NSObject, GroundworkTransport, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    @discardableResult
    func send(
        _ request: URLRequest,
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) -> GroundworkRequestCancellation {
        let task = session.dataTask(with: request, completionHandler: completion)
        task.resume()
        return GroundworkTaskCancellation(task: task)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.redirectedRequest(from: task.originalRequest, proposed: request))
    }

    static func redirectedRequest(from original: URLRequest?, proposed: URLRequest) -> URLRequest? {
        guard let originalURL = original?.url,
              let redirectedURL = proposed.url,
              GroundworkOrigin(url: originalURL) == GroundworkOrigin(url: redirectedURL),
              !(originalURL.scheme == "https" && redirectedURL.scheme != "https") else { return nil }
        return proposed
    }
}

struct GroundworkOrigin: Codable, Equatable, Hashable {
    let scheme: String
    let host: String
    let port: Int

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = url.port ?? (scheme == "https" ? 443 : 80)
    }

    var string: String { "\(scheme)://\(host):\(port)" }
}

enum GroundworkClientError: Error, Equatable {
    case invalidConfiguration(String)
    case authentication
    case retryable(status: Int?, retryAfter: TimeInterval? = nil)
    case permanent(status: Int)
    case malformedResponse
    case unsupportedSchema(Int)
    case timedOut
    case cancelled
}

final class GroundworkClient {
    static let tokenService = "com.mike.MoveBreak.groundwork"
    static let routinePath = "api/integrations/movebreak/routine"
    static let sessionPath = "api/integrations/movebreak/session"

    let baseURL: URL
    let token: String
    let timeout: TimeInterval
    private let transport: GroundworkTransport

    init(
        baseURL: URL,
        token: String,
        timeout: TimeInterval = 10,
        transport: GroundworkTransport = GroundworkURLSessionTransport()
    ) throws {
        guard GroundworkSetup.validateBaseURL(baseURL) != nil else {
            throw GroundworkClientError.invalidConfiguration("invalid Groundwork base URL")
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw GroundworkClientError.invalidConfiguration("missing Groundwork token")
        }
        self.baseURL = baseURL
        self.token = trimmedToken
        self.timeout = min(max(timeout, 1), 30)
        self.transport = transport
    }

    static func configured(transport: GroundworkTransport = GroundworkURLSessionTransport()) throws -> GroundworkClient? {
        guard let baseURL = Preferences.groundworkBaseURL,
              let origin = GroundworkOrigin(url: baseURL) else { return nil }
        guard let token = try Keychain.get(forAccount: origin.string, service: tokenService) else { return nil }
        return try GroundworkClient(baseURL: baseURL, token: token, transport: transport)
    }

    @discardableResult
    func fetchRoutine(
        locationID: String,
        durationMinutes: Int,
        completion: @escaping (Result<GroundworkRoutineResponse, GroundworkClientError>) -> Void
    ) -> GroundworkRequestCancellation? {
        guard !locationID.isEmpty, (1...30).contains(durationMinutes),
              var components = URLComponents(url: endpoint(Self.routinePath), resolvingAgainstBaseURL: false) else {
            completion(.failure(.invalidConfiguration("invalid routine request")))
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "locationId", value: locationID),
            URLQueryItem(name: "durationMinutes", value: String(durationMinutes)),
        ]
        guard let url = components.url else {
            completion(.failure(.invalidConfiguration("invalid routine URL")))
            return nil
        }
        var request = authorizedRequest(url: url)
        request.httpMethod = "GET"
        return transport.send(request) { data, response, error in
            completion(Self.decode(data: data, response: response, error: error, as: GroundworkRoutineResponse.self) { value in
                try value.validate()
            })
        }
    }

    @discardableResult
    func postCompletion(
        _ payload: GroundworkCompletionRequest,
        completion: @escaping (Result<GroundworkCompletionReceipt, GroundworkClientError>) -> Void
    ) -> GroundworkRequestCancellation? {
        do { try payload.validate() } catch let error as GroundworkModelError {
            completion(.failure(Self.clientError(for: error)))
            return nil
        } catch {
            completion(.failure(.malformedResponse))
            return nil
        }
        var request = authorizedRequest(url: endpoint(Self.sessionPath))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try GroundworkCoding.encoder().encode(payload)
        } catch {
            completion(.failure(.malformedResponse))
            return nil
        }
        return transport.send(request) { data, response, error in
            completion(Self.decode(data: data, response: response, error: error, as: GroundworkCompletionReceipt.self) { receipt in
                guard receipt.schemaVersion == GroundworkSchema.version,
                      receipt.clientSessionID == payload.clientSessionID else {
                    throw GroundworkModelError.invalid("completion receipt mismatch")
                }
            })
        }
    }

    private func endpoint(_ path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MoveBreak/1", forHTTPHeaderField: "User-Agent")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private static func decode<T: Decodable>(
        data: Data?, response: URLResponse?, error: Error?, as type: T.Type,
        validate: (T) throws -> Void
    ) -> Result<T, GroundworkClientError> {
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return .failure(.cancelled) }
            if urlError.code == .timedOut { return .failure(.timedOut) }
            return .failure(.retryable(status: nil, retryAfter: nil))
        }
        if error != nil { return .failure(.retryable(status: nil, retryAfter: nil)) }
        guard let http = response as? HTTPURLResponse else { return .failure(.malformedResponse) }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: return .failure(.authentication)
        case 408, 425, 429, 500...599:
            return .failure(.retryable(
                status: http.statusCode,
                retryAfter: retryAfter(from: http.value(forHTTPHeaderField: "Retry-After"))
            ))
        default: return .failure(.permanent(status: http.statusCode))
        }
        guard let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
              contentType.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) == "application/json",
              let data else { return .failure(.malformedResponse) }
        do {
            let value = try GroundworkCoding.decoder().decode(T.self, from: data)
            try validate(value)
            return .success(value)
        } catch let error as GroundworkModelError {
            return .failure(clientError(for: error))
        } catch {
            return .failure(.malformedResponse)
        }
    }

    private static func clientError(for error: GroundworkModelError) -> GroundworkClientError {
        if case .unsupportedSchema(let version) = error { return .unsupportedSchema(version) }
        return .malformedResponse
    }

    private static func retryAfter(from value: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(value), seconds >= 0 { return min(seconds, 86_400) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, min(date.timeIntervalSinceNow, 86_400))
    }
}
