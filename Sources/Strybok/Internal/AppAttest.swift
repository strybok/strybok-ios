import Foundation

#if canImport(DeviceCheck) && (os(iOS) || os(macOS))
    import DeviceCheck
#endif
#if canImport(Security)
    import Security
#endif

/// The attestor used by apps: Apple's App Attest where the platform has it, otherwise
/// one that reports "not supported".
func defaultAppAttestor() -> any AppAttestor {
    #if canImport(DeviceCheck) && (os(iOS) || os(macOS))
        if #available(iOS 14.0, macOS 11.0, *) { return DeviceCheckAttestor() }
    #endif
    return UnsupportedAttestor()
}

func defaultAttestationKeyStore() -> any AttestationKeyStore {
    #if canImport(Security)
        return KeychainAttestationKeyStore()
    #else
        return MemoryAttestationKeyStore()
    #endif
}

/// For platforms and OS versions without App Attest.
struct UnsupportedAttestor: AppAttestor {
    var isSupported: Bool { false }
    func generateKey() async throws -> String { throw AppAttestorError.failed }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        throw AppAttestorError.failed
    }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        throw AppAttestorError.failed
    }
}

#if canImport(DeviceCheck) && (os(iOS) || os(macOS))
    /// ``AppAttestor`` backed by `DCAppAttestService.shared`.
    @available(iOS 14.0, macOS 11.0, *)
    struct DeviceCheckAttestor: AppAttestor {
        var isSupported: Bool { DCAppAttestService.shared.isSupported }

        func generateKey() async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                DCAppAttestService.shared.generateKey { keyId, error in
                    continuation.resume(with: Self.result(keyId, error))
                }
            }
        }

        func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash) {
                    attestation, error in
                    continuation.resume(with: Self.result(attestation, error))
                }
            }
        }

        func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash) {
                    assertion, error in
                    continuation.resume(with: Self.result(assertion, error))
                }
            }
        }

        private static func result<Value>(
            _ value: Value?, _ error: (any Error)?
        ) -> Result<Value, AppAttestorError> {
            if let value { return .success(value) }
            switch (error as? DCError)?.code {
            case .invalidKey: return .failure(.invalidKey)
            case .serverUnavailable: return .failure(.serverUnavailable)
            default: return .failure(.failed)
            }
        }
    }
#endif

/// Keeps key identifiers for the life of the process only.
final class MemoryAttestationKeyStore: AttestationKeyStore {
    private let values = Locked<[String: String]>([:])

    func keyId(scope: String) -> String? {
        values.withLock { $0[scope] }
    }

    func setKeyId(_ keyId: String?, scope: String) {
        values.withLock { $0[scope] = keyId }
    }
}

#if canImport(Security)
    /// Keeps key identifiers in the Keychain, one generic-password item per scope, on
    /// this device only (never synchronised, not part of a backup restored elsewhere).
    /// The identifier is not a secret; it only has to survive restarts. When the Keychain
    /// refuses to store it, it is kept in memory so the running app still works.
    final class KeychainAttestationKeyStore: AttestationKeyStore {
        static let service = "com.strybok.sdk.attestation"

        private let fallback = MemoryAttestationKeyStore()

        private func query(_ scope: String) -> [CFString: Any] {
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: Self.service,
                kSecAttrAccount: scope,
            ]
        }

        func keyId(scope: String) -> String? {
            var query = query(scope)
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                let data = item as? Data, let keyId = String(data: data, encoding: .utf8),
                !keyId.isEmpty
            {
                return keyId
            }
            return fallback.keyId(scope: scope)
        }

        func setKeyId(_ keyId: String?, scope: String) {
            SecItemDelete(query(scope) as CFDictionary)
            fallback.setKeyId(nil, scope: scope)
            guard let keyId else { return }
            var item = query(scope)
            item[kSecValueData] = Data(keyId.utf8)
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            if SecItemAdd(item as CFDictionary, nil) != errSecSuccess {
                fallback.setKeyId(keyId, scope: scope)
            }
        }
    }
#endif
