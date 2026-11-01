import Foundation

/// #328: the one answer both dialog walkers use (`BoundedDialogProbe` for the
/// entry gate, `DialogTreeScanner` for `dialog list` / `dismiss`), so the two
/// cannot drift apart.
enum DialogCandidate {
    /// A native dialog or sheet. Matched by role or subrole, at any depth the
    /// walkers reach outside window chrome.
    static func isDialog(role: String, subrole: String?) -> Bool {
        role == "AXSheet" || role == "AXDialog" || subrole == "AXDialog" || subrole == "AXSystemDialog"
    }

    /// Window chrome the walkers do not enter: the toolbar, the tab bar and a
    /// tab button. Safari shows JavaScript dialogs inside the tab content
    /// (window → split group → tab group → dialog, the depth-3 case) and sheets
    /// as window children, never under these. A node the walker skips here is
    /// excluded on purpose, not a truncated branch, so it does not make the
    /// walk incomplete.
    ///
    /// A closed list of three, matched exactly. Measured on Safari 27.2
    /// (2026-11-01): `AXToolbar` holds the address field and its buttons, the
    /// tab bar is `AXOpaqueProviderGroup` / `AXOpaqueProviderList`, each tab is
    /// `AXRadioButton` / `AXTabButton`. A false positive came from somewhere in
    /// that chrome on a zh-Hant interface; the exact node was not reproduced.
    static func isWindowChrome(role: String, subrole: String?) -> Bool {
        switch (role, subrole) {
        case ("AXToolbar", _): return true
        case ("AXOpaqueProviderGroup", "AXOpaqueProviderList"): return true
        case ("AXRadioButton", "AXTabButton"): return true
        default: return false
        }
    }

    /// One path element for debug output: the role, and the subrole when
    /// there is one. Never a title or a value.
    static func pathLabel(role: String, subrole: String?) -> String {
        subrole.map { "\(role)/\($0)" } ?? role
    }
}
