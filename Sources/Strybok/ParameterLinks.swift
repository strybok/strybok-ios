import Foundation

/// Links without an API call: the `parameterLinks` option of ``StrybokConfiguration``.
///
/// The owner of an application can let addresses of its link hosts open a route of the app
/// without creating a link first: **path links** such as
/// `https://my-app.strybok.link/product/42?id=7` and **Firebase long links**
/// `https://my-app.strybok.link/?link=…&apn=…&ibi=…`. With this option the SDK recognises
/// those URLs as well and asks the service about them; the service decides whether the route
/// is allowed and answers with the route and payload it read, which is what the app receives
/// (``ResolvedLink/routePath`` and ``ResolvedLink/payload``, never the tapped path). Without
/// the option the SDK accepts single-slug links only and sends exactly what 0.4.0 sent.
///
/// `payloadKeys` are the query keys whose values travel with such a link, in the owner's
/// order: copy `parameterLinks.payloadKeys` from the integration guide of the application
/// (`GET /v1/apps/:appId/integration`, shown on the dashboard's setup screen). That value is
/// `null` while both kinds are switched off; then do not set the option. The keys are compiled
/// into the app: a key the owner adds later reaches users with the next app release, and the
/// service ignores keys it no longer allows.
///
/// Of a tapped URL the SDK then sends its path as received, the first value of each of these
/// keys and the five `utm_*` values — for a long link the deep link's scheme, host and path
/// with its values of these keys, and `apn` and `ibi`. Nothing else of the query, and never
/// the fragment. Do not configure keys that carry personal data.
public struct ParameterLinks: Sendable, Hashable {
    /// Query keys sent with a path link (and with the deep link of a long link), in this order.
    /// Empty is allowed: path links then carry no payload.
    public let payloadKeys: [String]

    /// Most keys the option may name.
    static let maxPayloadKeys = 20

    /// Keys Strybok reads itself, compared exactly (`ST` is an ordinary key).
    static let reservedKeys: Set<String> = ["st", "sd", "si", "strybok_click"]

    /// Checks the keys and keeps them.
    ///
    /// - Throws: ``StrybokConfigurationError`` when there are more than 20 keys, a key appears
    ///   twice, or a key is not 1–40 characters of `A–Z a–z 0–9 _ . -`, starts with `utm_` in
    ///   any case, or is `st`, `sd`, `si` or `strybok_click`. The keys of the integration guide
    ///   always pass, so `try!` is fine for keys copied from there.
    public init(payloadKeys: [String]) throws(StrybokConfigurationError) {
        if let problem = Self.problem(with: payloadKeys) {
            throw StrybokConfigurationError(message: "parameterLinks: \(problem)")
        }
        self.payloadKeys = payloadKeys
    }

    /// What is wrong with `keys`, or `nil` when they are valid.
    private static func problem(with keys: [String]) -> String? {
        if keys.count > maxPayloadKeys {
            return "payloadKeys has \(keys.count) keys, at most \(maxPayloadKeys) are allowed"
        }
        var seen = Set<String>()
        for key in keys {
            guard (1...40).contains(key.utf8.count), key.utf8.allSatisfy(isKeyByte) else {
                return "the payload key \"\(key)\" is not 1–40 letters, digits, \"_\", \".\" or \"-\""
            }
            if key.lowercased().hasPrefix("utm_") || reservedKeys.contains(key) {
                return "the payload key \"\(key)\" is read by Strybok itself"
                    + " (utm_*, st, sd, si, strybok_click)"
            }
            guard seen.insert(key).inserted else {
                return "the payload key \"\(key)\" appears twice"
            }
        }
        return nil
    }

    private static func isKeyByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "."),
            UInt8(ascii: "-"):
            return true
        default:
            return false
        }
    }
}

/// A value for ``StrybokConfiguration`` that the SDK does not accept, such as
/// ``ParameterLinks`` with a key that is not allowed.
///
/// It is thrown when the value is created, so a running SDK never sees it. It reports a
/// mistake in the app's code: fix the value rather than handle the error at run time.
public struct StrybokConfigurationError: Error, Sendable, Hashable {
    /// What is wrong, in English, for the developer.
    public let message: String

    init(message: String) {
        self.message = message
    }
}

extension StrybokConfigurationError: LocalizedError {
    public var errorDescription: String? { message }
}

extension StrybokConfigurationError: CustomStringConvertible {
    public var description: String { message }
}
