import Foundation

/// The SDK contract's "Which URLs are ours" for the path and the query of a URL, and the
/// `lookup` sent to resolve (sections "Resolving" and "Links without an API call").
///
/// Everything here works on the path and the query exactly as received: they are never
/// decoded or normalised as a whole, so a dot segment, a `//` or a malformed escape is seen
/// as the tapped URL has it. Only single query values are decoded, and re-encoded strictly.
enum LinkLookup {
    /// `lookup` for a URL whose scheme, host, user info and port were already accepted, or
    /// `nil` when its path makes it not ours.
    ///
    /// - Parameters:
    ///   - host: the host, lower-cased.
    ///   - path: the path as received (`percentEncodedPath`), possibly empty.
    ///   - query: the query as received, without `?` and the fragment; `nil` when there is none.
    ///   - options: `nil` applies the slug rule alone and sends the campaign query only,
    ///     exactly as 0.4.0 did; deferred-link answers and pasted links are always read so.
    static func make(host: String, path: String, query: String?, options: ParameterLinks?) -> String? {
        let campaign = CampaignQuery.make(from: query)
        if isSlug(path) {
            let payload = options.map { payloadQuery(keys: $0.payloadKeys, in: query) } ?? ""
            return "https://\(host)\(path)" + joined(payload, campaign)
        }
        guard let options else { return nil }
        let path = path.isEmpty ? "/" : path
        if path == "/", let link = firstValue(of: "link", in: query) {
            // A Firebase long link: ours only when `link` is a deep link.
            guard let pairs = longLinkQuery(link: link, query: query, keys: options.payloadKeys)
            else { return nil }
            return "https://\(host)/" + joined(pairs, campaign)
        }
        guard isRoutePath(path) else { return nil }
        let payload = payloadQuery(keys: options.payloadKeys, in: query)
        return "https://\(host)\(path)" + joined(payload, campaign)
    }

    /// `^/[A-Za-z0-9_-]{1,64}$`
    static func isSlug(_ path: String) -> Bool {
        guard path.utf8.first == UInt8(ascii: "/") else { return false }
        let slug = path.utf8.dropFirst()
        return (1...64).contains(slug.count) && slug.allSatisfy(isSlugByte)
    }

    /// A route path, checked as received: 1–512 characters starting with `/`, only URL path
    /// characters with complete escapes, no `//`, no `.` or `..` segment (also as `%2e`), and
    /// nothing browsers and crawlers ask for on their own.
    static func isRoutePath(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard (1...512).contains(bytes.count), bytes[0] == UInt8(ascii: "/") else { return false }
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%") {
                guard index + 2 < bytes.count, hexValue(bytes[index + 1]) != nil,
                    hexValue(bytes[index + 2]) != nil
                else { return false }
                index += 3
            } else {
                guard isPathByte(bytes[index]) else { return false }
                index += 1
            }
        }
        if path.contains("//") { return false }
        for segment in path.split(separator: "/", omittingEmptySubsequences: false) {
            let dots = segment.replacingOccurrences(of: "%2e", with: ".")
                .replacingOccurrences(of: "%2E", with: ".")
            if dots == "." || dots == ".." { return false }
        }
        for prefix in reservedPrefixes where path == prefix || path.hasPrefix(prefix + "/") {
            return false
        }
        return !reservedFiles.contains(path)
    }

    static let reservedPrefixes = ["/.well-known", "/_strybok"]

    static let reservedFiles: Set<String> = [
        "/favicon.ico", "/robots.txt", "/apple-touch-icon.png", "/apple-touch-icon-precomposed.png",
        "/sitemap.xml", "/ads.txt", "/app-ads.txt", "/security.txt", "/humans.txt",
        "/manifest.json", "/site.webmanifest", "/browserconfig.xml",
    ]

    /// The payload query: for each key, in the order given, its first occurrence in `query`
    /// when the value decodes and is 1–256 UTF-16 code units without control characters, as
    /// `key=value` with the value re-encoded; joined with `&`. A first occurrence that fails
    /// drops the key: a later one never counts.
    static func payloadQuery(keys: [String], in query: String?) -> String {
        keys.compactMap { key -> String? in
            guard let raw = firstValue(of: key, in: query), let value = decode(raw),
                isPayloadValue(value)
            else { return nil }
            return "\(key)=\(encode(value))"
        }.joined(separator: "&")
    }

    /// `link=…` with the rebuilt deep link, then `apn=…` and `ibi=…` when the tapped URL has
    /// them (sent as they are, even empty); `nil` when the URL is not ours.
    static func longLinkQuery(link: Substring, query: String?, keys: [String]) -> String? {
        guard let value = decode(link), let deep = deepLink(value, keys: keys) else { return nil }
        var pairs = ["link=\(encode(deep))"]
        for name in ["apn", "ibi"] {
            guard let raw = firstValue(of: name, in: query) else { continue }
            guard let value = decode(raw) else { return nil }
            pairs.append("\(name)=\(encode(value))")
        }
        return pairs.joined(separator: "&")
    }

    /// The deep link of a long link rebuilt as `{scheme}://{host}{path}` (both lower-cased,
    /// `/` for an empty path) with the payload query of its own query and without its
    /// fragment; `nil` when `value` is not an `http(s)` URL with a plain host name, or holds a
    /// character at or below U+0020, U+007F or `\`.
    static func deepLink(_ value: String, keys: [String]) -> String? {
        guard
            !value.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F || $0 == "\\" })
        else { return nil }
        let bytes = Array(value.utf8)
        guard let colon = bytes.firstIndex(of: UInt8(ascii: ":")) else { return nil }
        let scheme = asciiLowercased(bytes[..<colon])
        guard scheme == "http" || scheme == "https", bytes.count >= colon + 3,
            bytes[colon + 1] == UInt8(ascii: "/"), bytes[colon + 2] == UInt8(ascii: "/")
        else { return nil }
        let hostStart = colon + 3
        let hostEnd = bytes[hostStart...].firstIndex { $0 == slash || $0 == question || $0 == hash }
            ?? bytes.endIndex
        let host = bytes[hostStart..<hostEnd]
        guard !host.isEmpty, host.allSatisfy(isHostByte) else { return nil }
        let pathEnd = bytes[hostEnd...].firstIndex { $0 == question || $0 == hash } ?? bytes.endIndex
        let path = String(decoding: bytes[hostEnd..<pathEnd], as: UTF8.self)
        var query: String?
        if pathEnd < bytes.endIndex, bytes[pathEnd] == question {
            let queryEnd = bytes[(pathEnd + 1)...].firstIndex(of: hash) ?? bytes.endIndex
            query = String(decoding: bytes[(pathEnd + 1)..<queryEnd], as: UTF8.self)
        }
        let payload = payloadQuery(keys: keys, in: query)
        return "\(scheme)://\(asciiLowercased(host))\(path.isEmpty ? "/" : path)"
            + (payload.isEmpty ? "" : "?\(payload)")
    }

    /// The raw value of the first part of `query` whose key decodes to `name` (`""` when that
    /// part has no `=`), or `nil` when no key does. Parts are split on `&`, each on its first `=`.
    static func firstValue(of name: String, in query: String?) -> Substring? {
        guard let query else { return nil }
        for part in query.split(separator: "&", omittingEmptySubsequences: true) {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = pieces.first, decode(key) == name else { continue }
            return pieces.count > 1 ? pieces[1] : ""
        }
        return nil
    }

    /// Percent-decodes `text` as UTF-8 with `+` as a space. `nil` for a `%` without two
    /// hexadecimal digits, or bytes that are not UTF-8.
    static func decode(_ text: Substring) -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        var iterator = text.utf8.makeIterator()
        while let byte = iterator.next() {
            switch byte {
            case UInt8(ascii: "+"):
                bytes.append(UInt8(ascii: " "))
            case UInt8(ascii: "%"):
                guard let high = iterator.next().flatMap(hexValue),
                    let low = iterator.next().flatMap(hexValue)
                else { return nil }
                bytes.append(high << 4 | low)
            default:
                bytes.append(byte)
            }
        }
        var codec = UTF8()
        var input = bytes.makeIterator()
        var scalars = String.UnicodeScalarView()
        while true {
            switch codec.decode(&input) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput: return String(scalars)
            case .error: return nil
            }
        }
    }

    /// Every UTF-8 byte outside `A–Z a–z 0–9 - . _ ~` as `%XX` with upper-case digits.
    static func encode(_ value: String) -> String {
        var encoded = ""
        encoded.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if isUnreservedByte(byte) {
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                encoded += "%"
                encoded.unicodeScalars.append(Unicode.Scalar(hexDigits[Int(byte >> 4)]))
                encoded.unicodeScalars.append(Unicode.Scalar(hexDigits[Int(byte & 0x0F)]))
            }
        }
        return encoded
    }

    // MARK: - Helpers

    private static let slash = UInt8(ascii: "/")
    private static let question = UInt8(ascii: "?")
    private static let hash = UInt8(ascii: "#")
    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    /// `?` and the non-empty parts joined with `&`; empty when every part is.
    private static func joined(_ parts: String...) -> String {
        let pairs = parts.filter { !$0.isEmpty }
        return pairs.isEmpty ? "" : "?" + pairs.joined(separator: "&")
    }

    private static func isPayloadValue(_ value: String) -> Bool {
        (1...256).contains(value.utf16.count)
            && !value.unicodeScalars.contains { $0.value <= 0x1F || (0x7F...0x9F).contains($0.value) }
    }

    private static func asciiLowercased(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"):
            return true
        default:
            return false
        }
    }

    private static func isSlugByte(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
    }

    private static func isUnreservedByte(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || "-._~".utf8.contains(byte)
    }

    /// The host of a deep link: `A–Z a–z 0–9 . - _`.
    private static func isHostByte(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || ".-_".utf8.contains(byte)
    }

    /// `A–Z a–z 0–9 - . _ ~ ! $ & ' ( ) * + , ; = : @` and `/`; `%` is checked separately.
    private static func isPathByte(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || "-._~!$&'()*+,;=:@/".utf8.contains(byte)
    }
}
