import Foundation

/// Hardcoded marker constants for `tab-ownership-marker`. Single source of
/// truth — every wrap / unwrap / detection site references these constants
/// rather than inlining `\u{200B}` literals, so the marker can never be
/// silently customised by code edits without spec amendment per
/// Requirement: Marker content is hardcoded, no caller input.
///
/// The marker is a zero-width-space pair (`U+200B`) bracketing the original
/// tab title:
///
///     prefix + <original-title> + suffix
///
/// Both code points are invisible to humans; AX / Spotlight / Stage Manager
/// all preserve them in returned strings but render nothing visible. The
/// design choice trades off the original "user-visible indicator" goal in
/// exchange for eliminating the cross-process side-channel surface — see
/// the `tab-ownership-marker` capability spec Non-Goals.
enum MarkerConstants {
    /// Marker prefix code point: zero-width space (`U+200B`).
    static let prefix = "\u{200B}"

    /// Marker suffix code point: zero-width space (`U+200B`).
    static let suffix = "\u{200B}"

    /// Wraps the original title with the marker pair. Idempotent —
    /// re-wrapping an already-marked title returns the input unchanged so
    /// daemon-spanning multi-step requests cannot accidentally produce
    /// nested markers.
    static func wrap(title: String) -> String {
        if hasMarker(title: title) { return title }
        return prefix + title + suffix
    }

    /// Returns the original title when the input carries the marker pair,
    /// or nil when the input is unmarked or only partially marked. The
    /// nil return is the signal cleanup uses to detect a title-race per
    /// Requirement: Best-effort title-restore on race.
    static func unwrap(title: String) -> String? {
        guard hasMarker(title: title) else { return nil }
        // Both prefix and suffix are exactly one Unicode scalar (1 char in
        // Swift String semantics). dropFirst()/dropLast() at .count level
        // is safe and unambiguous.
        var working = title
        working.removeFirst(prefix.count)
        working.removeLast(suffix.count)
        return working
    }

    /// True when the title is wrapped with both prefix and suffix.
    /// Partial marker presence (one but not the other) returns false.
    static func hasMarker(title: String) -> Bool {
        title.hasPrefix(prefix) && title.hasSuffix(suffix)
            && title.count >= prefix.count + suffix.count
    }
}
