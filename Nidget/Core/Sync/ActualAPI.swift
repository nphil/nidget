import Foundation
import os

// MARK: - ActualAPIError

/// Failures from the Actual sync-server HTTP client (ARCHITECTURE §4: one error enum per
/// subsystem, all LocalizedError).
enum ActualAPIError: Error, LocalizedError, Equatable {
    /// No connectivity — mapped from `URLError.notConnectedToInternet` / `.timedOut`.
    case offline
    /// Non-2xx HTTP status whose body was NOT a parseable JSON error envelope.
    case http(status: Int)
    /// The server's JSON envelope reported `status != "ok"` (docs/PROTOCOL.md §1: every
    /// non-binary endpoint answers `{status: 'ok'|'error', data?, reason?}`).
    case server(reason: String)
    /// The response body wasn't in the documented shape.
    case invalidResponse
    /// Any other transport-level failure (DNS, TLS, connection reset, …).
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .offline:
            return "You appear to be offline. Changes are saved locally and will sync when you're back online."
        case .http(let status):
            return "The server responded with HTTP \(status)."
        case .server(let reason):
            return "The server reported an error: \(reason)."
        case .invalidResponse:
            return "The server sent an unexpected response."
        case .transport(let detail):
            return "Couldn't reach the server (\(detail))."
        }
    }
}

// MARK: - ActualAPI

/// URLSession client for the Actual sync server. Endpoints, headers, and content types follow
/// docs/PROTOCOL.md §1 exactly:
///
/// - `POST /account/login`            — JSON `{loginMethod: "password", password}` → `data.token`
/// - `GET  /account/validate`         — `X-ACTUAL-TOKEN` → `data.validated`
/// - `GET  /sync/list-user-files`     — `X-ACTUAL-TOKEN` → `data: [{fileId, groupId, …}]`
/// - `GET  /sync/download-user-file`  — `X-ACTUAL-TOKEN` + `X-ACTUAL-FILE-ID` → raw zip bytes
/// - `POST /sync/user-get-key`        — JSON `{token, fileId}` → `data: {id, salt, test}`
/// - `POST /sync/sync`                — `Content-Type: application/actual-sync`, raw protobuf
///   `SyncRequest` body → raw protobuf `SyncResponse` (PROTOCOL §2)
///
/// Timeouts: every request carries `timeoutInterval = 30`, which overrides the session's default
/// per-request timeout. `URLSessionConfiguration.default` (which backs `.shared`) already has
/// `waitsForConnectivity == false`, so a dead network fails fast with `URLError` instead of
/// hanging — exactly the offline-first behavior the engine wants.
actor ActualAPI {
    private static let log = Logger(subsystem: "app.nidget", category: "api")
    private static let requestTimeout: TimeInterval = 30

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Auth (PROTOCOL §1)

    /// `POST /account/login` with `{loginMethod: "password", password}`. Returns the session
    /// token from `data.token`. A wrong password surfaces as `.server(reason:)` (the server
    /// answers with an error envelope such as `invalid-password`).
    func login(password: String) async throws -> String {
        let body = try Self.jsonBody(["loginMethod": "password", "password": password])
        let request = makeRequest(["account", "login"], method: "POST",
                                  token: nil, contentType: "application/json", body: body)
        let (data, _) = try await perform(request)
        guard let dict = try Self.unwrapEnvelope(data) as? [String: Any],
              let token = dict["token"] as? String, !token.isEmpty else {
            throw ActualAPIError.invalidResponse
        }
        return token
    }

    /// `GET /account/validate` with `X-ACTUAL-TOKEN`. Returns false when the server rejects the
    /// token (error envelope or 401/403); other failures (offline, 5xx) still throw so callers
    /// can distinguish "bad token" from "can't tell right now".
    func validateToken(_ token: String) async throws -> Bool {
        do {
            let request = makeRequest(["account", "validate"], method: "GET", token: token)
            let (data, _) = try await perform(request)
            guard let dict = try Self.unwrapEnvelope(data) as? [String: Any] else {
                // Envelope said ok but data was missing — treat the ok status as validation.
                return true
            }
            if let validated = dict["validated"] as? NSNumber {
                return validated.boolValue
            }
            return true
        } catch let error as ActualAPIError {
            switch error {
            case .server(reason: _), .http(status: 401), .http(status: 403):
                return false
            default:
                throw error
            }
        }
    }

    // MARK: - Files (PROTOCOL §1, §8.3)

    /// `GET /sync/list-user-files`. Maps `data: [{deleted, fileId, groupId, name, encryptKeyId}]`
    /// into `RemoteFile`s. Entries without a `fileId` are dropped.
    func listFiles(token: String) async throws -> [RemoteFile] {
        let request = makeRequest(["sync", "list-user-files"], method: "GET", token: token)
        let (data, _) = try await perform(request)
        guard let array = try Self.unwrapEnvelope(data) as? [[String: Any]] else {
            throw ActualAPIError.invalidResponse
        }
        return array.compactMap { item in
            guard let fileID = item["fileId"] as? String, !fileID.isEmpty else { return nil }
            return RemoteFile(
                fileID: fileID,
                groupID: item["groupId"] as? String,
                name: (item["name"] as? String) ?? fileID,
                encryptKeyID: item["encryptKeyId"] as? String,
                deleted: (item["deleted"] as? NSNumber)?.boolValue ?? false
            )
        }
    }

    /// `GET /sync/download-user-file` with `X-ACTUAL-TOKEN` + `X-ACTUAL-FILE-ID` (PROTOCOL §8.3).
    /// Returns the raw bytes: a zip of `db.sqlite` + `metadata.json`, possibly AES-GCM-encrypted
    /// as one blob when the file has whole-file encryption.
    func downloadFile(token: String, fileID: String) async throws -> Data {
        var request = makeRequest(["sync", "download-user-file"], method: "GET", token: token)
        request.setValue(fileID, forHTTPHeaderField: "X-ACTUAL-FILE-ID")
        let (data, _) = try await perform(request)
        return data
    }

    /// `POST /sync/user-get-key` with JSON `{token, fileId}` (PROTOCOL §1 — the token rides in
    /// the body for this endpoint; the header is sent too, which the server also accepts).
    /// Returns nil when the file has no E2E key configured (`data.id`/`data.salt` absent).
    /// `data.test` is the key-validity ciphertext JSON (PROTOCOL §7.3) — passed through as a
    /// string for `E2EKey` password verification.
    func fetchKeyInfo(token: String, fileID: String) async throws -> KeyInfo? {
        let body = try Self.jsonBody(["token": token, "fileId": fileID])
        let request = makeRequest(["sync", "user-get-key"], method: "POST",
                                  token: token, contentType: "application/json", body: body)
        let (data, _) = try await perform(request)
        guard let dict = try Self.unwrapEnvelope(data) as? [String: Any],
              let keyID = dict["id"] as? String, !keyID.isEmpty,
              let salt = dict["salt"] as? String, !salt.isEmpty else {
            return nil
        }
        var testJSON: String?
        if let string = dict["test"] as? String {
            testJSON = string
        } else if let object = dict["test"],
                  JSONSerialization.isValidJSONObject(object),
                  let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            testJSON = String(data: encoded, encoding: .utf8)
        }
        return KeyInfo(keyID: keyID, saltBase64: salt, testContentJSON: testJSON)
    }

    // MARK: - Sync (PROTOCOL §1, §2)

    /// `POST /sync/sync`: raw protobuf `SyncRequest` body with
    /// `Content-Type: application/actual-sync` (the server's raw-body parser only accepts this
    /// exact type), `X-ACTUAL-TOKEN` header. The 2xx response body is a raw protobuf
    /// `SyncResponse` parsed by `SyncResponse(parsing:)`.
    func sync(token: String, request syncRequest: SyncRequest) async throws -> SyncResponse {
        let request = makeRequest(["sync", "sync"], method: "POST", token: token,
                                  contentType: "application/actual-sync",
                                  body: syncRequest.serialized())
        let (data, _) = try await perform(request)
        return try SyncResponse(parsing: data)
    }

    // MARK: - Internals

    private func makeRequest(_ pathComponents: [String], method: String, token: String?,
                             contentType: String? = nil, body: Data? = nil) -> URLRequest {
        var url = baseURL
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.requestTimeout
        if let token {
            request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        return request
    }

    /// Sends the request and enforces the task's error mapping:
    /// - `URLError.notConnectedToInternet` / `.timedOut` → `.offline`
    /// - other transport errors → `.transport`
    /// - non-2xx → `.server(reason:)` when the body is Actual's JSON error envelope (so a 400
    ///   `invalid-password` keeps its reason), else `.http(status:)`. The one documented non-JSON
    ///   error body (`'file-access-not-allowed'`, PROTOCOL §1 notes) falls through to `.http`.
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .notConnectedToInternet, .timedOut:
                throw ActualAPIError.offline
            default:
                Self.log.error("transport failure \(urlError.code.rawValue) for \(request.url?.path(percentEncoded: false) ?? "?", privacy: .public)")
                throw ActualAPIError.transport("URLError \(urlError.code.rawValue)")
            }
        } catch {
            throw ActualAPIError.transport(String(describing: type(of: error)))
        }
        guard let http = response as? HTTPURLResponse else {
            throw ActualAPIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            Self.log.error("HTTP \(http.statusCode) from \(request.url?.path(percentEncoded: false) ?? "?", privacy: .public)")
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = object["status"] as? String, status != "ok" {
                throw ActualAPIError.server(reason: (object["reason"] as? String) ?? "http-\(http.statusCode)")
            }
            throw ActualAPIError.http(status: http.statusCode)
        }
        return (data, http)
    }

    /// Parses the generic `{status, data?, reason?}` envelope (PROTOCOL §1) and returns `data`.
    /// Throws `.server(reason:)` when `status != "ok"`, `.invalidResponse` when the body isn't
    /// an envelope at all.
    private static func unwrapEnvelope(_ data: Data) throws -> Any? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String else {
            throw ActualAPIError.invalidResponse
        }
        guard status == "ok" else {
            throw ActualAPIError.server(reason: (object["reason"] as? String) ?? "server-error")
        }
        return object["data"]
    }

    private static func jsonBody(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            throw ActualAPIError.invalidResponse
        }
        return data
    }
}
