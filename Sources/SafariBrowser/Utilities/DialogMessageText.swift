import Foundation

/// Native dialog prose is distinct from an editable prompt answer. Safari
/// exposes alert bodies as a read-only AXTextArea under an AXScrollArea (#127).
/// Do not also read the dialog group's AXValue: Safari mirrors the same body
/// there, which would duplicate it and change the dismissal fingerprint.
enum DialogMessageText {
    static func read<P: DialogProbeProvider>(
        _ node: P.Node, role: String, provider: P,
        remainingTimeout: () throws -> Float
    ) throws -> String? {
        switch role {
        case "AXStaticText": break
        case "AXTextArea":
            guard let editable = try provider.valueIsSettable(node, timeout: remainingTimeout()) else {
                throw DialogProbeReadError.unavailable
            }
            guard !editable else { return nil }
        default: return nil
        }
        return try provider.text(node, timeout: remainingTimeout())
    }
}
