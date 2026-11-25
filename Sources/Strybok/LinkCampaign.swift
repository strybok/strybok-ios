import Foundation

/// Campaign values of a resolved link: the link's defaults, overridden per value by
/// the `utm_*` parameters of the URL that was tapped (`utm_source` is `source`, and
/// so on).
///
/// A value that is not set is `nil`. They are labels chosen by whoever created or
/// shared the link, so use them for attribution only and never to decide what the
/// user may see or do.
public struct LinkCampaign: Sendable, Hashable {
    /// `utm_source`: where the link was shared, for example `instagram`.
    public let source: String?

    /// `utm_medium`: the kind of channel, for example `social`.
    public let medium: String?

    /// `utm_campaign`: the name of the campaign.
    public let campaign: String?

    /// `utm_term`.
    public let term: String?

    /// `utm_content`.
    public let content: String?

    public init(
        source: String? = nil,
        medium: String? = nil,
        campaign: String? = nil,
        term: String? = nil,
        content: String? = nil
    ) {
        self.source = source
        self.medium = medium
        self.campaign = campaign
        self.term = term
        self.content = content
    }

    /// Whether no value is set.
    public var isEmpty: Bool { fields.isEmpty }

    /// Reads the `campaign` member of a resolve answer: keeps the string fields with
    /// the five known names and ignores everything else. Anything that is not a JSON
    /// object gives an empty value; this never fails.
    init(json: JSONValue?) {
        self.init(
            source: json?["source"]?.stringValue,
            medium: json?["medium"]?.stringValue,
            campaign: json?["campaign"]?.stringValue,
            term: json?["term"]?.stringValue,
            content: json?["content"]?.stringValue
        )
    }

    /// The values that are set, under their JSON names. This is what is reported with
    /// an app open.
    var fields: [String: String] {
        var fields: [String: String] = [:]
        fields["source"] = source
        fields["medium"] = medium
        fields["campaign"] = campaign
        fields["term"] = term
        fields["content"] = content
        return fields
    }
}

extension LinkCampaign: CustomStringConvertible {
    public var description: String {
        let values = fields.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        return "LinkCampaign(\(values.joined(separator: ", ")))"
    }
}

/// The SDK contract's "campaign query": what of a tapped URL's query string is sent
/// to the API.
enum CampaignQuery {
    /// The only query parameters ever sent, in the order they are sent.
    static let keys = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"]

    /// The part of `query` (the raw, still percent-encoded text after `?`) that is
    /// sent; empty when nothing is.
    ///
    /// Only the five `utm_*` keys are kept, compared exactly after decoding; of each
    /// the first occurrence counts, and it is dropped unless its decoded value is 1–64
    /// characters of `A-Z a-z 0-9 . _ ~ -`. The result is `key=value` pairs joined with
    /// `&` in a fixed order; such values never need encoding. Every other parameter
    /// may hold private data and is never returned.
    static func make(from query: String?) -> String {
        guard let query, !query.isEmpty else { return "" }
        // `.some(nil)` is a key whose value could not be decoded: still its first occurrence.
        var first: [String: String?] = [:]
        for part in query.split(separator: "&", omittingEmptySubsequences: true) {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = pieces.first, let key = decode(rawKey),
                keys.contains(key), first[key] == nil
            else { continue }
            first[key] = .some(pieces.count > 1 ? decode(pieces[1]) : "")
        }
        return keys.compactMap { key -> String? in
            guard let value = first[key] ?? nil, isValue(value) else { return nil }
            return "\(key)=\(value)"
        }.joined(separator: "&")
    }

    /// Percent-decodes as UTF-8 with `+` as a space. `nil` for a malformed escape or
    /// invalid UTF-8, which no key or value of ours can contain.
    private static func decode(_ text: Substring) -> String? {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    private static func isValue(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count) && value.utf8.allSatisfy(isValueByte)
    }

    private static func isValueByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "_"),
            UInt8(ascii: "~"), UInt8(ascii: "-"):
            return true
        default:
            return false
        }
    }
}
