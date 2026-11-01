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
    /// The toolbar is chrome whatever subrole it reports; the tab bar and a tab
    /// are chrome only with exactly these subroles, so one that reported a
    /// dialog subrole would still be tested as a dialog.
    ///
    /// A closed list of three, matched exactly. Measured on Safari 27.2
    /// (2026-11-01): `AXToolbar` holds the address field and its buttons, the
    /// tab bar is `AXOpaqueProviderGroup` / `AXOpaqueProviderList`, each tab is
    /// `AXRadioButton` / `AXTabButton`. A false positive on a zh-Hant interface
    /// may have come from a node in that chrome, or from the window itself
    /// (see `BoundedDialogProbe`); the node was not reproduced.
    static func isWindowChrome(role: String, subrole: String?) -> Bool {
        if isChromeRole(role) { return true }
        switch (role, subrole) {
        case ("AXOpaqueProviderGroup", "AXOpaqueProviderList"): return true
        case ("AXRadioButton", "AXTabButton"): return true
        default: return false
        }
    }

    /// The part of the chrome test that needs no subrole: the toolbar. The
    /// walkers ask this right after reading the role, so a subrole read that
    /// fails on a toolbar cannot make the walk incomplete.
    static func isChromeRole(_ role: String) -> Bool {
        role == "AXToolbar"
    }

    /// One path element for debug output: the role, and the subrole when
    /// there is one. Never a title or a value.
    static func pathLabel(role: String, subrole: String?) -> String {
        guard let subrole, !subrole.isEmpty else { return role }
        return "\(role)/\(subrole)"
    }
}
