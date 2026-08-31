import Foundation

public enum KimiOAuthError: LocalizedError, Sendable, Equatable {
    case invalidResponse(String)
    case http(status: Int, error: String, description: String?)
    case denied(String)
    case expired(String)
    case timedOut
    case missingCredentials

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let message): message
        case .http(let status, let error, let description):
            "Kimi OAuth failed (HTTP \(status)): \(description ?? error)"
        case .denied(let message): "Kimi sign-in was denied: \(message)"
        case .expired(let message): "Kimi sign-in code expired: \(message)"
        case .timedOut: "Kimi sign-in timed out."
        case .missingCredentials: "Kimi OAuth credentials are missing. Sign in again."
        }
    }
}

public struct KimiOAuthToken: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let deviceID: String
    public let refreshedAt: Date

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?, deviceID: String, refreshedAt: Date = Date()) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.deviceID = deviceID
        self.refreshedAt = refreshedAt
    }
}

public struct KimiDeviceAuthorization: Codable, Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: URL
    public let expiresIn: TimeInterval
    public let interval: TimeInterval

    public init(deviceCode: String, userCode: String, verificationURL: URL, expiresIn: TimeInterval, interval: TimeInterval) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.expiresIn = expiresIn
        self.interval = interval
    }
}

public protocol KimiOAuthSleeping: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemKimiOAuthSleeper: KimiOAuthSleeping {
    public init() {}
    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// RFC 8628 Kimi Code authentication shared by the settings UI and Runtime.
/// Token material is serialized only into the injected CredentialStore.
public actor KimiOAuthManager {
    public static let officialClientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    public static let deviceAuthorizationURL = URL(string: "https://auth.kimi.com/api/oauth/device_authorization")!
    public static let tokenURL = URL(string: "https://auth.kimi.com/api/oauth/token")!

    private let credentials: any CredentialStore
    private let transport: any ProviderHTTPTransport
    private let sleeper: any KimiOAuthSleeping
    private let clientID: String
    private let refreshBuffer: TimeInterval
    private var refreshTasks: [String: Task<KimiOAuthToken, Error>] = [:]

    public init(
        credentials: any CredentialStore = KeychainCredentialStore(),
        transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport(),
        sleeper: any KimiOAuthSleeping = SystemKimiOAuthSleeper(),
        clientID: String = KimiOAuthManager.officialClientID,
        refreshBuffer: TimeInterval = 300
    ) {
        self.credentials = credentials
        self.transport = transport
        self.sleeper = sleeper
        self.clientID = clientID
        self.refreshBuffer = refreshBuffer
    }

    public func requestDeviceAuthorization() async throws -> KimiDeviceAuthorization {
        guard !clientID.isEmpty else { throw KimiOAuthError.invalidResponse("Kimi OAuth client ID is not configured.") }
        let (json, status) = try await post(Self.deviceAuthorizationURL, parameters: ["client_id": clientID])
        guard (200..<300).contains(status) else { throw Self.httpError(status: status, json: json) }
        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let rawURL = (json["verification_uri_complete"] as? String)
                ?? (json["verification_url_complete"] as? String)
                ?? (json["verification_uri"] as? String)
                ?? (json["verification_url"] as? String),
              let verificationURL = URL(string: rawURL) else {
            throw KimiOAuthError.invalidResponse("Kimi device authorization response is incomplete.")
        }
        return KimiDeviceAuthorization(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verificationURL,
            expiresIn: Self.number(json["expires_in"]) ?? 900,
            interval: Self.number(json["interval"]) ?? 5
        )
    }

    @discardableResult
    public func completeDeviceAuthorization(_ authorization: KimiDeviceAuthorization, account: String) async throws -> KimiOAuthToken {
        var interval = authorization.interval
        var elapsed: TimeInterval = 0
        while elapsed < authorization.expiresIn {
            try await sleeper.sleep(seconds: interval)
            elapsed += interval
            let (json, status) = try await post(Self.tokenURL, parameters: [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": authorization.deviceCode,
                "client_id": clientID,
            ])
            if (200..<300).contains(status), let access = json["access_token"] as? String, !access.isEmpty {
                let token = Self.makeToken(json: json, accessToken: access, fallbackRefresh: nil, deviceID: UUID().uuidString)
                try await save(token, account: account)
                return token
            }
            let code = (json["error"] as? String)?.lowercased() ?? "unknown_error"
            let description = (json["error_description"] as? String) ?? code
            switch code {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "access_denied": throw KimiOAuthError.denied(description)
            case "expired_token": throw KimiOAuthError.expired(description)
            default: throw KimiOAuthError.http(status: status, error: code, description: description)
            }
        }
        throw KimiOAuthError.timedOut
    }

    public func validAccessToken(account: String, now: Date = Date()) async throws -> String {
        let current = try await load(account: account)
        guard !current.accessToken.isEmpty else { throw KimiOAuthError.missingCredentials }
        let needsRefresh = current.refreshToken != nil
            && (current.expiresAt.map { $0.timeIntervalSince(now) <= refreshBuffer } ?? false)
        guard needsRefresh else { return current.accessToken }
        return try await refreshSingleFlight(account: account, current: current).accessToken
    }

    public func isAuthenticated(account: String) async -> Bool {
        (try? await load(account: account))?.accessToken.isEmpty == false
    }

    public func signOut(account: String) async throws { try await credentials.delete(account: account) }

    private func refreshSingleFlight(account: String, current: KimiOAuthToken) async throws -> KimiOAuthToken {
        if let task = refreshTasks[account] { return try await task.value }
        let task = Task { try await self.refresh(account: account, current: current) }
        refreshTasks[account] = task
        defer { refreshTasks[account] = nil }
        return try await task.value
    }

    private func refresh(account: String, current: KimiOAuthToken) async throws -> KimiOAuthToken {
        guard let staleRefresh = current.refreshToken, !staleRefresh.isEmpty else { return current }
        do {
            let (json, status) = try await post(Self.tokenURL, parameters: [
                "grant_type": "refresh_token",
                "refresh_token": staleRefresh,
                "client_id": clientID,
            ])
            guard (200..<300).contains(status), let access = json["access_token"] as? String, !access.isEmpty else {
                throw Self.httpError(status: status, json: json)
            }
            let refreshed = Self.makeToken(json: json, accessToken: access, fallbackRefresh: staleRefresh, deviceID: current.deviceID)
            try await save(refreshed, account: account)
            return refreshed
        } catch {
            let latest = try? await load(account: account)
            if let latest, latest.refreshToken != staleRefresh { return latest }
            if Self.isFatalRefreshError(error) {
                try? await credentials.delete(account: account)
                throw KimiOAuthError.missingCredentials
            }
            if current.expiresAt.map({ $0 > Date() }) ?? true { return current }
            throw error
        }
    }

    private func load(account: String) async throws -> KimiOAuthToken {
        do {
            let encoded = try await credentials.load(account: account)
            guard let data = encoded.data(using: .utf8), let token = try? JSONDecoder().decode(KimiOAuthToken.self, from: data) else {
                throw KimiOAuthError.missingCredentials
            }
            return token
        } catch is CredentialStoreError { throw KimiOAuthError.missingCredentials }
    }

    private func save(_ token: KimiOAuthToken, account: String) async throws {
        let data = try JSONEncoder().encode(token)
        guard let encoded = String(data: data, encoding: .utf8) else { throw KimiOAuthError.invalidResponse("Could not encode Kimi credentials.") }
        try await credentials.save(encoded, account: account)
    }

    private func post(_ url: URL, parameters: [String: String]) async throws -> ([String: Any], Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(parameters)
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw KimiOAuthError.invalidResponse("Kimi OAuth returned an invalid HTTP response.") }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (json, http.statusCode)
    }

    static func formEncoded(_ parameters: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func makeToken(json: [String: Any], accessToken: String, fallbackRefresh: String?, deviceID: String) -> KimiOAuthToken {
        KimiOAuthToken(
            accessToken: accessToken,
            refreshToken: (json["refresh_token"] as? String) ?? fallbackRefresh,
            expiresAt: number(json["expires_in"]).map { Date().addingTimeInterval($0) },
            deviceID: deviceID
        )
    }

    private static func httpError(status: Int, json: [String: Any]) -> KimiOAuthError {
        KimiOAuthError.http(
            status: status,
            error: (json["error"] as? String) ?? "unknown_error",
            description: json["error_description"] as? String
        )
    }

    private static func isFatalRefreshError(_ error: Error) -> Bool {
        guard case .http(let status, let code, _) = error as? KimiOAuthError else { return false }
        return (400...403).contains(status)
            || ["invalid_grant", "invalid_token", "unauthorized_client", "refresh_token_reused"].contains(code.lowercased())
    }
}
