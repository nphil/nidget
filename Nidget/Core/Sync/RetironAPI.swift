import Foundation
import os

// MARK: - RetironAPIError

/// Failures from the Retiron HTTP client (ARCHITECTURE §4: one error enum per subsystem, all
/// LocalizedError). Same shape and same mapping rules as `ActualAPIError`.
enum RetironAPIError: Error, LocalizedError, Equatable {
    /// No connectivity — mapped from `URLError.notConnectedToInternet` / `.timedOut`.
    case offline
    /// Non-2xx HTTP status whose body carried no readable reason, and every 401/403.
    case http(status: Int)
    /// The server explained itself (FastAPI answers `{"detail": "..."}`).
    case server(reason: String)
    /// The response body wasn't in the documented shape.
    case invalidResponse
    /// Any other transport-level failure (DNS, TLS, connection reset, …).
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .offline:
            return "Retiron isn't reachable right now. Your plan stays on this phone and syncs when it's back."
        case .http(let status):
            if status == 401 || status == 403 {
                return "Retiron didn't accept that token. Copy it again from the Retiron page and paste it in."
            }
            return "Retiron answered with HTTP \(status)."
        case .server(let reason):
            return "Retiron reported an error: \(reason)."
        case .invalidResponse:
            return "Retiron sent back something unexpected."
        case .transport(let detail):
            return "Couldn't reach Retiron (\(detail))."
        }
    }
}

// MARK: - RetironAPI

/// URLSession client for Retiron, the household planner this app syncs with. Retiron serves its
/// own web page and puts every API route under `/api`:
///
/// - `GET  /api/health`            — liveness, used by the Test button
/// - `GET  /api/nidget/token`      — `{token}`, so setup can grab the token without typing it
/// - `GET  /api/profiles`          — `{profiles: [{id, name, updated}], active}`
/// - `GET  /api/profiles/{name}`   — `{name, data, updated}`
/// - `POST /api/profiles`          — `{name, data}` upserts by name
/// - `GET  /api/active`            — the active scenario, `name` null when there isn't one
/// - `POST /api/active`            — `{name}` switches the active scenario
/// - `POST /api/nidget/snapshot`   — real balances and spending, `Authorization: Bearer <token>`
///
/// Only the snapshot push is authenticated; the rest of Retiron is LAN and tailnet trusted, which
/// is why the token endpoint is open at all. The token is sent on the push and nowhere else, and
/// it is never logged: only paths and status codes are.
///
/// Timeouts: every request carries `timeoutInterval = 30`, overriding the session default, and
/// `URLSessionConfiguration.default` doesn't wait for connectivity, so a dead network fails fast.
actor RetironAPI {
    private static let log = Logger(subsystem: "app.nidget", category: "retiron")
    private static let requestTimeout: TimeInterval = 30

    private let baseURL: URL
    private let token: String
    private let session: URLSession

    init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    // MARK: - Health and setup

    /// `GET /api/health`. Throws on anything that isn't a 2xx, so a successful return means the
    /// address points at a live Retiron.
    func health() async throws {
        let request = makeRequest(["api", "health"], method: "GET")
        _ = try await perform(request)
    }

    /// `GET /api/nidget/token`. Open by design so the phone can pick the token up during setup
    /// on a trusted network; the owner can still paste it by hand.
    func fetchToken() async throws -> String {
        let request = makeRequest(["api", "nidget", "token"], method: "GET")
        let (data, _) = try await perform(request)
        guard let body = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !body.token.isEmpty else {
            throw RetironAPIError.invalidResponse
        }
        return body.token
    }

    // MARK: - Profiles

    /// `GET /api/profiles`. Every saved scenario plus the name of the active one.
    func profiles() async throws -> RetironProfileList {
        let request = makeRequest(["api", "profiles"], method: "GET")
        let (data, _) = try await perform(request)
        guard let body = try? JSONDecoder().decode(ProfileListResponse.self, from: data) else {
            throw RetironAPIError.invalidResponse
        }
        let summaries = body.profiles.map {
            RetironProfileSummary(name: $0.name, updated: $0.updated)
        }
        let active: String? = (body.active?.isEmpty ?? true) ? nil : body.active
        return RetironProfileList(profiles: summaries, active: active)
    }

    /// `GET /api/profiles/{name}`. A missing scenario comes back as a 404, which maps to
    /// `.http(status: 404)`.
    func profile(named name: String) async throws -> RetironProfile {
        let request = makeRequest(["api", "profiles", name], method: "GET")
        let (data, _) = try await perform(request)
        guard let body = try? JSONDecoder().decode(ProfileResponse.self, from: data) else {
            throw RetironAPIError.invalidResponse
        }
        return RetironProfile(name: body.name.isEmpty ? name : body.name,
                              data: body.data, updated: body.updated)
    }

    /// `POST /api/profiles` with `{name, data}`. Upserts by name. Send a profile that was read
    /// from Retiron and edited (see `RetironProfileMapper`) so nothing this app doesn't model
    /// gets dropped.
    func saveProfile(_ name: String, data: RetironProfileData) async throws {
        let body = try encode(SaveProfileBody(name: name, data: data))
        let request = makeRequest(["api", "profiles"], method: "POST",
                                  contentType: "application/json", body: body)
        _ = try await perform(request)
    }

    /// `GET /api/active`. Returns nil when Retiron has no active scenario yet.
    func activeProfile() async throws -> RetironProfile? {
        let request = makeRequest(["api", "active"], method: "GET")
        let (data, _) = try await perform(request)
        guard let body = try? JSONDecoder().decode(ProfileResponse.self, from: data) else {
            throw RetironAPIError.invalidResponse
        }
        guard !body.name.isEmpty else { return nil }
        return RetironProfile(name: body.name, data: body.data, updated: body.updated)
    }

    /// `POST /api/active` with `{name}`. A name Retiron doesn't know comes back as a 404.
    func setActive(_ name: String) async throws {
        let body = try encode(ActiveBody(name: name))
        let request = makeRequest(["api", "active"], method: "POST",
                                  contentType: "application/json", body: body)
        _ = try await perform(request)
    }

    // MARK: - Snapshot push

    /// `POST /api/nidget/snapshot` with `Authorization: Bearer <token>`. Retiron keeps one
    /// snapshot, so every push replaces the last one.
    func pushSnapshot(_ snapshot: RetironSnapshotPush) async throws {
        let body = try encode(snapshot)
        let request = makeRequest(["api", "nidget", "snapshot"], method: "POST",
                                  contentType: "application/json", body: body, authorized: true)
        _ = try await perform(request)
    }

    // MARK: - Internals

    private func makeRequest(_ pathComponents: [String], method: String,
                             contentType: String? = nil, body: Data? = nil,
                             authorized: Bool = false) -> URLRequest {
        var url = baseURL
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.requestTimeout
        if authorized {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        return request
    }

    /// Sends the request with the house error mapping:
    /// - `URLError.notConnectedToInternet` / `.timedOut` → `.offline`
    /// - other transport errors → `.transport`
    /// - 401/403 → `.http(status:)` so the token copy wins over the server's wording
    /// - other non-2xx → `.server(reason:)` when the body explains itself (FastAPI's `detail`),
    ///   else `.http(status:)`
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .notConnectedToInternet, .timedOut:
                throw RetironAPIError.offline
            default:
                Self.log.error("transport failure \(urlError.code.rawValue) for \(request.url?.path(percentEncoded: false) ?? "?", privacy: .public)")
                throw RetironAPIError.transport("URLError \(urlError.code.rawValue)")
            }
        } catch {
            throw RetironAPIError.transport(String(describing: type(of: error)))
        }
        guard let http = response as? HTTPURLResponse else {
            throw RetironAPIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            Self.log.error("HTTP \(http.statusCode) from \(request.url?.path(percentEncoded: false) ?? "?", privacy: .public)")
            // Auth failures keep the token copy: Retiron answers 401 with
            // `{"detail": "Bad or missing token"}`, which doesn't tell the owner what to do.
            if http.statusCode == 401 || http.statusCode == 403 {
                throw RetironAPIError.http(status: http.statusCode)
            }
            if let reason = Self.reason(from: data), !reason.isEmpty {
                throw RetironAPIError.server(reason: reason)
            }
            throw RetironAPIError.http(status: http.statusCode)
        }
        return (data, http)
    }

    /// FastAPI answers errors with `{"detail": "..."}`; validation failures put a list there
    /// instead, which is no use to a person, so those fall through to `.http(status:)`.
    private static func reason(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let detail = object["detail"] as? String { return detail }
        if let reason = object["reason"] as? String { return reason }
        if let error = object["error"] as? String { return error }
        return nil
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw RetironAPIError.invalidResponse
        }
    }

    // MARK: - Wire shapes

    private struct TokenResponse: Decodable {
        var token: String
    }

    private struct ProfileListResponse: Decodable {
        struct Row: Decodable {
            var name: String
            var updated: String?

            enum CodingKeys: String, CodingKey {
                case name, updated
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = (try? container.decode(String.self, forKey: .name)) ?? ""
                updated = try? container.decode(String.self, forKey: .updated)
            }
        }

        var profiles: [Row]
        var active: String?

        enum CodingKeys: String, CodingKey {
            case profiles, active
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rows = (try? container.decode([Row].self, forKey: .profiles)) ?? []
            profiles = rows.filter { !$0.name.isEmpty }
            active = try? container.decode(String.self, forKey: .active)
        }
    }

    private struct ProfileResponse: Decodable {
        var name: String
        var data: RetironProfileData
        var updated: String?

        enum CodingKeys: String, CodingKey {
            case name, data, updated
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? container.decode(String.self, forKey: .name)) ?? ""
            data = (try? container.decode(RetironProfileData.self, forKey: .data))
                ?? RetironProfileData()
            updated = try? container.decode(String.self, forKey: .updated)
        }
    }

    private struct SaveProfileBody: Encodable {
        var name: String
        var data: RetironProfileData
    }

    private struct ActiveBody: Encodable {
        var name: String
    }
}
