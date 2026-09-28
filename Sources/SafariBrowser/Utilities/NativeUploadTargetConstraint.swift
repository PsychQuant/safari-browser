import Foundation

/// The original selection policy carried across native target resolution.
/// Only fixed matcher data crosses the worker boundary; matching performs no I/O.
struct NativeUploadTargetConstraint: Codable, Sendable, Equatable {
    let matcher: SafariBridge.UrlMatcher?
    let profile: String?

    private static let allowedRegexOptions: NSRegularExpression.Options = [
        .caseInsensitive, .allowCommentsAndWhitespace, .ignoreMetacharacters,
        .dotMatchesLineSeparators, .anchorsMatchLines, .useUnixLineSeparators,
        .useUnicodeWordBoundaries,
    ]

    private enum InvalidConstraint: Error { case invalid }

    private init(matcher: SafariBridge.UrlMatcher?, profile: String?) throws {
        guard matcher != nil || profile != nil else { throw InvalidConstraint.invalid }
        if let profile {
            guard !profile.isEmpty, profile.utf8.count <= 4_096,
                  !profile.contains("\0") else { throw InvalidConstraint.invalid }
        }
        if let matcher {
            let pattern: String
            switch matcher {
            case .contains(let value), .exact(let value), .endsWith(let value):
                pattern = value
            case .regex(let expression):
                pattern = expression.pattern
                guard expression.options.rawValue & ~Self.allowedRegexOptions.rawValue == 0 else {
                    throw InvalidConstraint.invalid
                }
            }
            guard pattern.utf8.count <= 65_536, !pattern.contains("\0") else {
                throw InvalidConstraint.invalid
            }
        }
        self.matcher = matcher
        self.profile = profile
    }

    static func from(_ target: SafariBridge.TargetDocument) throws -> Self? {
        switch target {
        case .urlMatch(let matcher):
            return try Self(matcher: matcher, profile: nil)
        case .resolvedTab(_, _, let matcher, let profile):
            guard matcher != nil || profile != nil else { return nil }
            return try Self(matcher: matcher, profile: profile)
        case .frontWindow, .windowIndex, .documentIndex, .windowTab:
            return nil
        }
    }

    func matches(url: String, windowName: String) -> Bool {
        if let matcher, !matcher.matches(url) { return false }
        if let profile,
           SafariBridge.UrlMatcher.parseProfile(fromWindowName: windowName).profile != profile {
            return false
        }
        return true
    }

    /// Dynamic keys are deliberate: ordinary CodingKeys silently discard unknown fields.
    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        guard Set(values.allKeys.map(\.stringValue)).isSubset(of: ["matcher", "profile"]) else {
            throw Self.decodingError(decoder)
        }
        // A present null is invalid; absence alone represents an optional constraint.
        let profile = try values.contains(Key("profile"))
            ? values.decode(String.self, forKey: Key("profile")) : nil
        let matcher: SafariBridge.UrlMatcher?
        if values.contains(Key("matcher")) {
            let fields = try values.nestedContainer(keyedBy: Key.self, forKey: Key("matcher"))
            let keys = Set(fields.allKeys.map(\.stringValue))
            let kind = try fields.decode(String.self, forKey: Key("kind"))
            let expected: Set<String> = kind == "regex"
                ? ["kind", "pattern", "options"] : ["kind", "pattern"]
            guard keys == expected else { throw Self.decodingError(decoder) }
            let pattern = try fields.decode(String.self, forKey: Key("pattern"))
            // Check the bound before asking the regex compiler to process this input.
            guard pattern.utf8.count <= 65_536, !pattern.contains("\0") else {
                throw Self.decodingError(decoder)
            }
            switch kind {
            case "contains": matcher = .contains(pattern)
            case "exact": matcher = .exact(pattern)
            case "endsWith": matcher = .endsWith(pattern)
            case "regex":
                let options = try fields.decode(UInt.self, forKey: Key("options"))
                guard options & ~Self.allowedRegexOptions.rawValue == 0 else {
                    throw Self.decodingError(decoder)
                }
                do {
                    // Keep this compiled expression for every subsequent callback.
                    matcher = .regex(try NSRegularExpression(
                        pattern: pattern, options: .init(rawValue: options)
                    ))
                } catch { throw Self.decodingError(decoder) }
            default: throw Self.decodingError(decoder)
            }
        } else {
            matcher = nil
        }
        do {
            try self.init(matcher: matcher, profile: profile)
        } catch { throw Self.decodingError(decoder) }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Key.self)
        if let profile { try values.encode(profile, forKey: Key("profile")) }
        if let matcher {
            var fields = values.nestedContainer(keyedBy: Key.self, forKey: Key("matcher"))
            let kind: String
            let pattern: String
            switch matcher {
            case .contains(let value): (kind, pattern) = ("contains", value)
            case .exact(let value): (kind, pattern) = ("exact", value)
            case .endsWith(let value): (kind, pattern) = ("endsWith", value)
            case .regex(let expression):
                (kind, pattern) = ("regex", expression.pattern)
                try fields.encode(expression.options.rawValue, forKey: Key("options"))
            }
            try fields.encode(kind, forKey: Key("kind"))
            try fields.encode(pattern, forKey: Key("pattern"))
        }
    }

    private static func decodingError(_ decoder: Decoder) -> DecodingError {
        .dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Invalid native upload target constraint"
        ))
    }
}
