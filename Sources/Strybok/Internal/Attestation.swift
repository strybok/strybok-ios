import CryptoKit
import Foundation

// MARK: - Seams

/// The part of Apple's App Attest (`DCAppAttestService`) the SDK uses. Behind a protocol
/// so the whole flow can be tested without a device.
protocol AppAttestor: Sendable {
    /// `false` in the simulator, below iOS 14, in most extensions and on some Macs.
    var isSupported: Bool { get }

    /// Creates a key in the Secure Enclave and returns its identifier (standard base64).
    func generateKey() async throws -> String

    /// Asks Apple to attest the key. Contacts Apple's servers.
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data

    /// Signs `clientDataHash` with an attested key.
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

/// What an ``AppAttestor`` reports when a call fails. Any other thrown error is treated
/// like ``failed``.
enum AppAttestorError: Error, Sendable {
    /// The key no longer exists on this device (reinstall, restore): register a new one.
    case invalidKey
    /// Apple could not be reached: the same key may be attested again later.
    case serverUnavailable
    /// Anything else.
    case failed
}

/// Where the App Attest key identifier is kept between launches. `scope` separates
/// client keys and API hosts, so another application or environment never reuses it.
protocol AttestationKeyStore: Sendable {
    func keyId(scope: String) -> String?
    /// Stores `keyId`, or removes the entry when it is `nil`.
    func setKeyId(_ keyId: String?, scope: String)
}

// MARK: - Session

/// Result of asking for an attestation session token.
enum AttestationOutcome: Sendable, Equatable {
    /// Send it as `X-Strybok-Attestation`.
    case token(String)
    /// This device, build or moment cannot attest: send the request without a token.
    case unavailable
    /// The service refused the client key (401) on an attestation endpoint.
    case unauthorized
    /// The calling task was cancelled while waiting.
    case cancelled
}

/// Optional proof for `createLink` that the request comes from a genuine build of the
/// app on a genuine device ("Attestation" in the SDK contract):
///
///     challenge -> App Attest proof bound to the challenge -> session token
///
/// Nothing happens until ``token()`` is called, which only `createLink` does. The token
/// lives in memory only; the key identifier is the only thing persisted.
final class AttestationSession: Sendable {
    /// A token is not used during its last seconds.
    static let expiryMargin: TimeInterval = 60
    /// After an attempt that could not attest, the next one waits this long, so a device
    /// that cannot attest does not pay for a failed attempt on every share.
    static let unavailableCooldown: TimeInterval = 60

    private struct State {
        var token: (value: String, expiresAt: Date)?
        var inFlight: Task<AttestationOutcome, Never>?
        var unavailableUntil: Date?
        /// A generated key Apple could not attest yet because it was unreachable.
        var pendingKeyId: String?
    }

    private let clientKey: String
    private let attestor: any AppAttestor
    private let keyStore: any AttestationKeyStore
    private let transport: any StrybokTransport
    private let timeout: TimeInterval
    private let attestorTimeout: TimeInterval
    private let now: @Sendable () -> Date
    private let endpoint: @Sendable (String) -> URL
    private let scope: String
    private let state = Locked(State())

    init(
        clientKey: String,
        configuration: StrybokConfiguration,
        endpoint: @escaping @Sendable (String) -> URL
    ) {
        self.clientKey = clientKey
        self.attestor = configuration.attestor ?? defaultAppAttestor()
        self.keyStore = configuration.attestationKeyStore ?? defaultAttestationKeyStore()
        self.transport = configuration.transport
        self.timeout = configuration.timeout
        self.attestorTimeout = configuration.attestorTimeout
        self.now = configuration.now
        self.endpoint = endpoint
        self.scope = Self.scope(clientKey: clientKey, apiBaseURL: configuration.apiBaseURL)
    }

    /// Name under which the key identifier is stored: a digest of the API address and
    /// the client key, so the key itself is not written to the store.
    static func scope(clientKey: String, apiBaseURL: URL) -> String {
        let components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)
        var path = components?.percentEncodedPath ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        let api = [
            components?.scheme?.lowercased() ?? "",
            "://",
            components?.host?.lowercased() ?? "",
            components?.port.map { ":\($0)" } ?? "",
            path,
        ].joined()
        let digest = SHA256.hash(data: Data("\(api)\n\(clientKey)".utf8))
        return "v1." + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The cached token, or the result of one attestation shared by every concurrent
    /// caller. Never throws and never blocks longer than the bounded requests it makes.
    func token() async -> AttestationOutcome {
        enum Step {
            case done(AttestationOutcome)
            case wait(Task<AttestationOutcome, Never>)
        }
        let step = state.withLock { state -> Step in
            let now = now()
            if let token = state.token {
                if now < token.expiresAt.addingTimeInterval(-Self.expiryMargin) {
                    return .done(.token(token.value))
                }
                state.token = nil
            }
            if let running = state.inFlight { return .wait(running) }
            if let until = state.unavailableUntil {
                if now < until { return .done(.unavailable) }
                state.unavailableUntil = nil
            }
            let task = Task { [self] in await attestAndRecord() }
            state.inFlight = task
            return .wait(task)
        }
        switch step {
        case .done(let outcome):
            return outcome
        case .wait(let task):
            // Leave when the caller is cancelled; the shared attestation goes on for the
            // other callers. The ceiling is far above what the bounded steps can take.
            let ceiling = 4 * (timeout + attestorTimeout) + 60
            switch await withDeadline(ceiling, { await task.value }) {
            case .success(let outcome): return outcome
            case .cancelled: return .cancelled
            case .failure, .timedOut: return .unavailable
            }
        }
    }

    /// Forgets `token` after the service refused it. A newer token stays.
    func invalidate(_ token: String) {
        state.withLock { state in
            if state.token?.value == token { state.token = nil }
        }
    }

    // MARK: - One attestation

    private func attestAndRecord() async -> AttestationOutcome {
        let result = await attest()
        return state.withLock { state -> AttestationOutcome in
            state.inFlight = nil
            switch result {
            case .granted(let token, let expiresAt):
                state.token = (token, expiresAt)
                return .token(token)
            case .unavailable:
                state.unavailableUntil = now().addingTimeInterval(Self.unavailableCooldown)
                return .unavailable
            case .unauthorized:
                return .unauthorized
            }
        }
    }

    private enum Attempt {
        case granted(token: String, expiresAt: Date)
        case unavailable
        case unauthorized
    }

    private enum Answer {
        case granted(token: String, expiresAt: Date)
        case unauthorized
        /// `403 ATTESTATION_FAILED` with this `details.reason`.
        case refused(reason: String?)
        case unavailable
    }

    private func attest() async -> Attempt {
        guard attestor.isSupported else { return .unavailable }
        var startedOver = false
        while true {
            // Every proof attempt needs its own challenge: the service spends it.
            let challenge: String
            switch await post("/v1/public/attest/challenge", body: nil) {
            case .some(let response) where response.statusCode == 200:
                guard
                    let text = (try? JSONDecoder().decode(ChallengeResponse.self, from: response.body))?
                        .challenge, !text.isEmpty
                else { return .unavailable }
                challenge = text
            case .some(let response) where response.statusCode == 401:
                return .unauthorized
            default:
                return .unavailable
            }
            // SHA-256 of the UTF-8 bytes of the challenge string, as the service computes it.
            let hash = Data(SHA256.hash(data: Data(challenge.utf8)))

            let answer: Answer
            if let keyId = keyStore.keyId(scope: scope) {
                let assertion: Data
                do {
                    assertion = try await platform { [attestor] in
                        try await attestor.generateAssertion(keyId, clientDataHash: hash)
                    }
                } catch AppAttestorError.invalidKey {
                    // The key is gone (reinstall, restore): register a new one, once.
                    keyStore.setKeyId(nil, scope: scope)
                    if startedOver { return .unavailable }
                    startedOver = true
                    continue
                } catch {
                    return .unavailable
                }
                answer = await exchange(
                    "/v1/public/attest/ios/assert",
                    ["keyId": keyId, "assertion": assertion.base64EncodedString(), "challenge": challenge])
                if case .refused("unknown_key") = answer {
                    // The service does not know this key (any more): start over, once.
                    keyStore.setKeyId(nil, scope: scope)
                    if startedOver { return .unavailable }
                    startedOver = true
                    continue
                }
            } else {
                let keyId: String
                let attestation: Data
                do {
                    if let pending = state.withLock({ $0.pendingKeyId }) {
                        keyId = pending
                    } else {
                        keyId = try await platform { [attestor] in try await attestor.generateKey() }
                    }
                    do {
                        attestation = try await platform { [attestor] in
                            try await attestor.attestKey(keyId, clientDataHash: hash)
                        }
                    } catch AppAttestorError.serverUnavailable {
                        // Apple was unreachable: the same key is tried again next time.
                        state.withLock { $0.pendingKeyId = keyId }
                        return .unavailable
                    }
                } catch {
                    state.withLock { $0.pendingKeyId = nil }
                    return .unavailable
                }
                state.withLock { $0.pendingKeyId = nil }
                answer = await exchange(
                    "/v1/public/attest/ios/register",
                    [
                        "keyId": keyId, "attestation": attestation.base64EncodedString(),
                        "challenge": challenge,
                    ])
                if case .granted = answer {
                    // Only a key the service accepted is worth keeping.
                    keyStore.setKeyId(keyId, scope: scope)
                } else if case .refused("key_exists") = answer {
                    // The service already has this key: it can only be asserted, and the
                    // SDK cannot tell whether that would work. A fresh key, once.
                    if startedOver { return .unavailable }
                    startedOver = true
                    continue
                }
            }

            switch answer {
            case .granted(let token, let expiresAt): return .granted(token: token, expiresAt: expiresAt)
            case .unauthorized: return .unauthorized
            case .refused, .unavailable: return .unavailable
            }
        }
    }

    /// Sends a proof and reads the answer of a session-token endpoint.
    private func exchange(_ path: String, _ fields: [String: String]) async -> Answer {
        guard let body = try? JSONEncoder().encode(fields),
            let response = await post(path, body: body)
        else { return .unavailable }
        switch response.statusCode {
        case 200:
            guard let grant = try? JSONDecoder().decode(GrantResponse.self, from: response.body),
                Self.isHeaderValue(grant.token),
                let expiresAt = Self.date(grant.expiresAt)
            else { return .unavailable }
            return .granted(token: grant.token, expiresAt: expiresAt)
        case 401:
            return .unauthorized
        case 403:
            let error = ServiceError(response.body)
            guard error.code == "ATTESTATION_FAILED" else { return .unavailable }
            return .refused(reason: error.reason)
        default:
            return .unavailable
        }
    }

    /// One attempt, never retried: every attempt spends a challenge. `nil` when there
    /// was no answer in time.
    private func post(_ path: String, body: Data?) async -> StrybokHTTPResponse? {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientKey, forHTTPHeaderField: "X-Strybok-Key")
        request.httpBody = body
        request.timeoutInterval = max(timeout, 0.001)
        let transport = transport
        guard case .success(let response) = await withDeadline(timeout, { [request] in
            try await transport.send(request)
        }) else { return nil }
        return response
    }

    /// Runs an App Attest call with a time limit, so a call that never comes back cannot
    /// hold `createLink` forever.
    private func platform<Value: Sendable>(
        _ call: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        switch await withDeadline(attestorTimeout, call) {
        case .success(let value): return value
        case .failure(let error): throw error
        case .timedOut, .cancelled: throw AppAttestorError.failed
        }
    }

    private struct ChallengeResponse: Decodable {
        var challenge: String
    }

    private struct GrantResponse: Decodable {
        var token: String
        var expiresAt: String
    }

    /// Whether `text` can be sent as a header value: visible ASCII, not empty.
    private static func isHeaderValue(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 4096
            && text.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }

    /// An ISO-8601 UTC instant, with or without fractional seconds.
    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// `error.code` and `error.details.reason` of an error answer of the service.
struct ServiceError {
    var code: String?
    var reason: String?

    init(_ body: Data) {
        struct Envelope: Decodable {
            struct Body: Decodable {
                var code: JSONValue?
                var details: JSONValue?
            }
            var error: Body
        }
        let error = (try? JSONDecoder().decode(Envelope.self, from: body))?.error
        code = error?.code?.stringValue
        // Reasons are short identifiers (`expired`, `unknown_key`, …). Anything else is
        // dropped rather than passed on into an error an app may log.
        if let text = error?.details?["reason"]?.stringValue, (1...64).contains(text.utf8.count),
            text.utf8.allSatisfy({
                (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
                    || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || $0 == UInt8(ascii: "_")
            })
        {
            reason = text
        }
    }
}
