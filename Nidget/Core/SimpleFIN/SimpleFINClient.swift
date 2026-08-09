import Foundation
import os

// MARK: - SimpleFIN client
//
// Implements the SimpleFIN protocol per docs/PROTOCOL.md §9. Protocol v1 is the primary target
// (we pass `version=1` explicitly, as §9.4 recommends for clients that want the v1 shape), but the
// parser is defensive: a v2.0.0-draft response (top-level `connections` array + `Account.conn_id`
// instead of a per-account `org` object) is handled as long as it carries an `accounts` array.
//
// Privacy: the access URL embeds long-lived Basic Auth credentials. It is never logged, never left
// in a request URL (credentials move to an explicit Authorization header), and never persisted here
// — `claim(setupToken:)` returns it for the caller to store in the Keychain.

// MARK: - Errors

enum SimpleFINError: LocalizedError {
    /// The setup token is not valid base64 / not an https claim URL, or the stored access URL is
    /// malformed / its credentials have been revoked (HTTP 403 on `/accounts`).
    case invalidToken
    /// The claim POST returned a non-200 status. 403 usually means the setup token was already
    /// used — per the spec this should be treated as a possible compromise signal.
    case claimFailed(Int)
    /// `/accounts` returned an unexpected HTTP status (e.g. 402 Payment Required).
    case http(Int)
    /// The response body could not be understood.
    case parse
    /// The request never reached the server (no connectivity, DNS/TLS/transport failure).
    case offline

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "The SimpleFIN token isn't valid or its access has been revoked. Claim a fresh setup token from your SimpleFIN provider."
        case .claimFailed(let status):
            if status == 403 {
                return "This SimpleFIN setup token was already used or revoked. Generate a new one — and if you didn't use it, consider revoking access with your provider."
            }
            return "Claiming the SimpleFIN token failed (HTTP \(status))."
        case .http(let status):
            if status == 402 {
                return "The SimpleFIN server reported a billing problem (HTTP 402). Check your SimpleFIN subscription."
            }
            return "The SimpleFIN request failed (HTTP \(status))."
        case .parse:
            return "Couldn't read the SimpleFIN server's response."
        case .offline:
            return "Couldn't reach the SimpleFIN server. Check your connection and try again."
        }
    }
}

// MARK: - Wire models

/// One bank account as reported by SimpleFIN `/accounts`.
struct SFAccount: Sendable {
    var id: String
    var name: String
    /// Institution display name — v1 `org.name`/`org.domain`, or the joined v2 connection name.
    var org: String
    /// ISO 4217 code (or, per spec, a custom-currency URL — passed through untouched).
    var currency: String
    var balance: Money
    var balanceDate: Date
    var transactions: [SFTransaction]
}

/// One bank transaction as reported by SimpleFIN. Sign convention matches Actual:
/// negative = outflow, positive = inflow.
struct SFTransaction: Sendable {
    var id: String
    var posted: Date
    var amount: Money
    /// Non-standard field some servers (e.g. SimpleFIN Bridge) emit alongside `description`.
    var payee: String?
    var description: String
    /// Non-standard field some servers emit; nil when absent.
    var memo: String?
    var pending: Bool
}

// MARK: - Client

actor SimpleFINClient {
    private static let log = Logger(subsystem: "app.nidget", category: "simplefin")

    private let accessURL: String
    private let session: URLSession

    init(accessURL: String) {
        self.accessURL = accessURL
        self.session = .shared
    }

    // MARK: Claim (setup token → access URL)

    /// Exchanges a one-time SimpleFIN setup token (base64 of a claim URL) for the long-lived
    /// access URL. POSTs an empty body; the 200 response body *is* the access URL, with Basic
    /// Auth credentials embedded. Nothing is stored here — the caller persists the returned
    /// URL to the Keychain (`simplefin.accessURL`).
    static func claim(setupToken: String) async throws -> String {
        // Setup tokens are copy/pasted by hand — strip stray whitespace and fix missing padding.
        var base64 = setupToken.filter { !$0.isWhitespace }
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard !base64.isEmpty,
              let decoded = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let claimString = String(data: decoded, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let claimURL = URL(string: claimString),
              claimURL.scheme?.lowercased() == "https"
        else {
            throw SimpleFINError.invalidToken
        }

        var request = URLRequest(url: claimURL)
        request.httpMethod = "POST"
        request.httpBody = Data()   // explicit empty body → Content-Length: 0 per the dev guide

        let (data, response) = try await perform(request, session: .shared)
        guard let http = response as? HTTPURLResponse else { throw SimpleFINError.parse }
        guard http.statusCode == 200 else {
            log.error("SimpleFIN claim failed: HTTP \(http.statusCode)")
            throw SimpleFINError.claimFailed(http.statusCode)
        }
        guard let body = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty,
              let components = URLComponents(string: body),
              components.scheme?.lowercased() == "https",
              components.user != nil
        else {
            throw SimpleFINError.parse
        }
        log.info("SimpleFIN claim succeeded")
        return body
    }

    // MARK: Accounts

    /// Fetches `{access}/accounts`. `startDate` becomes the `start-date` query parameter (unix
    /// seconds); `includePending` adds `pending=1`. Credentials embedded in the access URL are
    /// extracted into an explicit `Authorization: Basic` header and stripped from the request URL.
    func accounts(startDate: Date?, includePending: Bool) async throws -> [SFAccount] {
        guard var components = URLComponents(string: accessURL),
              components.scheme?.lowercased() == "https",
              let user = components.user
        else {
            throw SimpleFINError.invalidToken
        }
        let password = components.password ?? ""

        // Never rely on userinfo-in-URL: strip it and send an explicit header instead.
        components.user = nil
        components.password = nil

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/accounts"

        var query: [URLQueryItem] = []
        if let startDate {
            query.append(URLQueryItem(name: "start-date",
                                      value: String(Int(startDate.timeIntervalSince1970))))
        }
        if includePending {
            query.append(URLQueryItem(name: "pending", value: "1"))
        }
        // We build against the v1 response shape; v2-capable servers honor this, v1 servers
        // ignore the unknown parameter (PROTOCOL §9.2/§9.4). Parsing still tolerates v2.
        query.append(URLQueryItem(name: "version", value: "1"))
        components.queryItems = query

        guard let url = components.url else { throw SimpleFINError.invalidToken }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let credentials = Data("\(user):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await Self.perform(request, session: session)
        guard let http = response as? HTTPURLResponse else { throw SimpleFINError.parse }
        switch http.statusCode {
        case 200:
            break
        case 403:
            Self.log.error("SimpleFIN /accounts returned 403 — credentials revoked or invalid")
            throw SimpleFINError.invalidToken
        default:
            Self.log.error("SimpleFIN /accounts failed: HTTP \(http.statusCode)")
            throw SimpleFINError.http(http.statusCode)
        }

        let accounts = try Self.parseAccountSet(data)
        Self.log.info("SimpleFIN /accounts parsed \(accounts.count) account(s)")
        return accounts
    }

    // MARK: Transport

    /// The fixed error enum has no dedicated transport case, so every failure that prevented an
    /// HTTP response (no connectivity, DNS, TLS, timeout) surfaces as `.offline`; HTTP-status
    /// failures use `.claimFailed`/`.http`/`.invalidToken` above.
    private static func perform(_ request: URLRequest,
                                session: URLSession) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.notice("SimpleFIN request failed at the transport layer")
            throw SimpleFINError.offline
        }
    }

    // MARK: Parsing (JSONSerialization — tolerant of v1 and v2 shapes)

    private static func parseAccountSet(_ data: Data) throws -> [SFAccount] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawAccounts = root["accounts"] as? [[String: Any]]
        else {
            throw SimpleFINError.parse
        }

        // v2 draft: institution info lives in a sibling `connections` array keyed by conn_id.
        var connectionNames: [String: String] = [:]
        if let connections = root["connections"] as? [[String: Any]] {
            for connection in connections {
                guard let connID = connection["conn_id"] as? String else { continue }
                connectionNames[connID] = (connection["name"] as? String)
                    ?? (connection["org_url"] as? String)
                    ?? ""
            }
        }

        var accounts: [SFAccount] = []
        accounts.reserveCapacity(rawAccounts.count)
        for raw in rawAccounts {
            guard let id = raw["id"] as? String, !id.isEmpty else { continue }

            let org: String
            if let orgObject = raw["org"] as? [String: Any] {
                // v1: per-account Organization object (name and/or domain).
                org = (orgObject["name"] as? String) ?? (orgObject["domain"] as? String) ?? ""
            } else if let connID = raw["conn_id"] as? String {
                // v2 draft: join to the connections array.
                org = connectionNames[connID] ?? ""
            } else {
                org = ""
            }

            var transactions: [SFTransaction] = []
            if let rawTransactions = raw["transactions"] as? [[String: Any]] {
                transactions.reserveCapacity(rawTransactions.count)
                for rawTransaction in rawTransactions {
                    if let transaction = parseTransaction(rawTransaction) {
                        transactions.append(transaction)
                    }
                }
            }

            accounts.append(SFAccount(
                id: id,
                name: (raw["name"] as? String) ?? "",
                org: org,
                currency: (raw["currency"] as? String) ?? "",
                balance: money(raw["balance"]) ?? .zero,
                balanceDate: epochDate(raw["balance-date"]) ?? Date(),
                transactions: transactions
            ))
        }
        return accounts
    }

    private static func parseTransaction(_ raw: [String: Any]) -> SFTransaction? {
        guard let id = raw["id"] as? String, !id.isEmpty,
              let amount = money(raw["amount"])
        else { return nil }
        // `posted` may be 0 while a transaction is still pending — fall back to `transacted_at`;
        // a transaction we cannot date at all is dropped rather than imported into 1970.
        guard let posted = epochDate(raw["posted"]) ?? epochDate(raw["transacted_at"]) else {
            return nil
        }
        return SFTransaction(
            id: id,
            posted: posted,
            amount: amount,
            payee: raw["payee"] as? String,
            description: (raw["description"] as? String) ?? "",
            memo: raw["memo"] as? String,
            pending: (raw["pending"] as? Bool) ?? false
        )
    }

    /// Amounts are numeric strings per spec ("-33293.43"); tolerate sloppy servers sending
    /// JSON numbers. SimpleFIN's sign convention (negative = outflow) matches Actual — kept as-is.
    private static func money(_ value: Any?) -> Money? {
        if let string = value as? String { return Money(decimalString: string) }
        if let number = value as? NSNumber { return Money(decimalString: number.stringValue) }
        return nil
    }

    /// SimpleFIN timestamps are unix epoch **seconds** (PROTOCOL §9 / caution 10).
    private static func epochDate(_ value: Any?) -> Date? {
        let seconds: Double
        if let number = value as? NSNumber {
            seconds = number.doubleValue
        } else if let string = value as? String, let parsed = Double(string) {
            seconds = parsed
        } else {
            return nil
        }
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
