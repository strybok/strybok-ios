import CryptoKit
import Foundation

#if canImport(UIKit) && os(iOS)
    import UIKit
#endif

// MARK: - Seams

/// Where the two values of deferred links are kept, per installation: `attempts` (used
/// by probabilistic matching only) and `done`. `scope` separates API hosts and apps.
///
/// It must be storage that is removed with the app (so a reinstall starts again), which
/// is why it is not the Keychain. Nothing else is ever stored: not the pasted string,
/// not the click id, nothing from an answer.
protocol DeferredLinkStore: Sendable {
    func attempts(scope: String) -> Int
    func setAttempts(_ attempts: Int, scope: String)
    func isDone(scope: String) -> Bool
    func setDone(scope: String)
}

/// What probabilistic matching and the redeem request need to know about the app.
protocol DeferredLinkEnvironment: Sendable {
    /// `Bundle.main.bundleIdentifier`.
    var bundleId: String? { get }
    /// `Locale.preferredLanguages.first`.
    var preferredLanguage: String? { get }
    /// `iphone`, `ipad` or `ipod`; `nil` for every other kind of device.
    func deviceFamily() async -> String?
}

/// Asks the system whether the pasteboard probably holds a web address, **without
/// reading it**. The only pasteboard access the SDK has.
protocol PasteboardProbe: Sendable {
    func mayContainWebURL() async -> Bool
}

// MARK: - Defaults

/// Keeps the values in `UserDefaults.standard`: private to the app, gone when the app
/// is deleted.
struct UserDefaultsDeferredLinkStore: DeferredLinkStore {
    static let prefix = "com.strybok.sdk.deferred."

    private func key(_ name: String, _ scope: String) -> String {
        "\(Self.prefix)\(scope).\(name)"
    }

    func attempts(scope: String) -> Int {
        UserDefaults.standard.integer(forKey: key("attempts", scope))
    }

    func setAttempts(_ attempts: Int, scope: String) {
        UserDefaults.standard.set(attempts, forKey: key("attempts", scope))
    }

    func isDone(scope: String) -> Bool {
        UserDefaults.standard.bool(forKey: key("done", scope))
    }

    func setDone(scope: String) {
        UserDefaults.standard.set(true, forKey: key("done", scope))
    }
}

/// Keeps the values for the life of the process only.
final class MemoryDeferredLinkStore: DeferredLinkStore {
    private let values = Locked<(attempts: [String: Int], done: Set<String>)>(([:], []))

    func attempts(scope: String) -> Int {
        values.withLock { $0.attempts[scope] ?? 0 }
    }

    func setAttempts(_ attempts: Int, scope: String) {
        values.withLock { $0.attempts[scope] = attempts }
    }

    func isDone(scope: String) -> Bool {
        values.withLock { $0.done.contains(scope) }
    }

    func setDone(scope: String) {
        values.withLock { _ = $0.done.insert(scope) }
    }
}

struct SystemDeferredLinkEnvironment: DeferredLinkEnvironment {
    var bundleId: String? { Bundle.main.bundleIdentifier }

    var preferredLanguage: String? { Locale.preferredLanguages.first }

    func deviceFamily() async -> String? {
        #if canImport(UIKit) && os(iOS)
            // The interface idiom only; the model string is looked at for nothing but
            // telling an iPod touch from an iPhone, and is never sent.
            return await MainActor.run { () -> String? in
                switch UIDevice.current.userInterfaceIdiom {
                case .phone: return UIDevice.current.model.hasPrefix("iPod") ? "ipod" : "iphone"
                case .pad: return "ipad"
                default: return nil
                }
            }
        #else
            return nil
        #endif
    }
}

/// For platforms and OS versions without pattern detection: there is never anything to
/// wait for.
struct UnsupportedPasteboardProbe: PasteboardProbe {
    func mayContainWebURL() async -> Bool { false }
}

#if canImport(UIKit) && os(iOS)
    /// Pattern detection, which Apple documents as determining whether the pasteboard
    /// matches "without notifying the user": no content is returned, no banner and no
    /// "Allow Paste" alert appear. No other pasteboard API may be used in this package
    /// (a test scans the sources for it).
    @available(iOS 15.0, *)
    struct SystemPasteboardProbe: PasteboardProbe {
        func mayContainWebURL() async -> Bool {
            let found = try? await UIPasteboard.general.detectedPatterns(for: [\.probableWebURL])
            return found?.contains(\.probableWebURL) ?? false
        }
    }

    /// The same question on iOS 14, whose form of the call was replaced in iOS 15.
    @available(iOS 14.0, *)
    struct LegacyPasteboardProbe: PasteboardProbe {
        // Marked deprecated like the call it makes, so building for a newer iOS does not
        // warn; it is only reached through the protocol, on iOS 14.
        @available(iOS, introduced: 14.0, deprecated: 15.0)
        func mayContainWebURL() async -> Bool {
            await withCheckedContinuation { continuation in
                UIPasteboard.general.detectPatterns(for: [.probableWebURL]) { result in
                    let found = (try? result.get())?.contains(.probableWebURL) ?? false
                    continuation.resume(returning: found)
                }
            }
        }
    }
#endif

func defaultPasteboardProbe() -> any PasteboardProbe {
    #if canImport(UIKit) && os(iOS)
        if #available(iOS 15.0, *) { return SystemPasteboardProbe() }
        if #available(iOS 14.0, *) { return LegacyPasteboardProbe() }
    #endif
    return UnsupportedPasteboardProbe()
}

// MARK: - Context

/// The seams of one ``Strybok`` instance plus the name its values are stored under.
/// Creating it does no work: nothing is read or written until a flow runs.
struct DeferredLinkContext: Sendable {
    /// `attempts` reaches this and matching gives up for good.
    static let maxAttempts = 3

    let store: any DeferredLinkStore
    let environment: any DeferredLinkEnvironment
    let probe: any PasteboardProbe
    private let apiBaseURL: URL

    init(_ configuration: StrybokConfiguration) {
        store = configuration.deferredLinkStore ?? UserDefaultsDeferredLinkStore()
        environment = configuration.deferredLinkEnvironment ?? SystemDeferredLinkEnvironment()
        probe = configuration.pasteboardProbe ?? defaultPasteboardProbe()
        apiBaseURL = configuration.apiBaseURL
    }

    /// Name under which the values are stored: a digest of the API address and the
    /// bundle identifier, like the scope of the attestation key identifier, so another
    /// environment or app sharing the storage never sees them.
    var scope: String {
        Self.scope(apiBaseURL: apiBaseURL, bundleId: environment.bundleId)
    }

    static func scope(apiBaseURL: URL, bundleId: String?) -> String {
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
        let digest = SHA256.hash(data: Data("\(api)\n\(bundleId ?? "")".utf8))
        return "v1." + digest.map { String(format: "%02x", $0) }.joined()
    }

    var isDone: Bool { store.isDone(scope: scope) }
    func setDone() { store.setDone(scope: scope) }
    var attempts: Int { store.attempts(scope: scope) }
    func setAttempts(_ attempts: Int) { store.setAttempts(attempts, scope: scope) }
}

// MARK: - Parsing

enum DeferredLinkFormat {
    /// Query parameter that carries the click id in a copied link.
    static let clickKey = "strybok_click"

    /// Longest pasted text that is looked at. A link of ours is far shorter.
    static let maxPastedLength = 2048

    /// The click id of a copied link: the **first** `strybok_click` parameter of `query`
    /// (the raw text after `?`), which must be `dc_` followed by 32 letters or digits.
    /// `nil` when there is no such parameter or the first one is anything else.
    static func clickId(inQuery query: String?) -> String? {
        guard let query else { return nil }
        for part in query.split(separator: "&", omittingEmptySubsequences: true) {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = pieces.first, decode(rawKey) == clickKey else { continue }
            guard pieces.count > 1, let value = decode(pieces[1]), isClickId(value) else {
                return nil
            }
            return value
        }
        return nil
    }

    /// `^dc_[0-9A-Za-z]{32}$`
    static func isClickId(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 35, bytes.starts(with: Array("dc_".utf8)) else { return false }
        return bytes.dropFirst(3).allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                UInt8(ascii: "a")...UInt8(ascii: "z"):
                return true
            default:
                return false
            }
        }
    }

    /// What the service accepts as `locale`: a language tag such as `en`, `en-GB` or
    /// `zh-Hans-CN` (`^[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{1,8}){0,4}$`).
    static func isLocale(_ value: String) -> Bool {
        let parts = value.split(
            omittingEmptySubsequences: false, whereSeparator: { $0 == "-" || $0 == "_" })
        guard let language = parts.first, (1...5).contains(parts.count),
            (2...3).contains(language.utf8.count), language.utf8.allSatisfy(isLetter)
        else { return false }
        return parts.dropFirst().allSatisfy { part in
            (1...8).contains(part.utf8.count)
                && part.utf8.allSatisfy { isLetter($0) || isDigit($0) }
        }
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func decode(_ text: Substring) -> String? {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}
