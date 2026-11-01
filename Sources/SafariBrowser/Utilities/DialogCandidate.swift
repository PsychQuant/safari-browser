import Foundation

/// #328: what the entry probe (`BoundedDialogProbe`) counts as a dialog and as
/// window chrome. The global scanner (`DialogTreeScanner`, behind `dialog
/// list`, `dismiss`, `is dialog` and the dialog state in `documents` / `tabs`)
/// keeps its own copy of the dialog test and walks the whole window, chrome
/// and window root included; changing that is left to #326 (maintainer's scope
/// decision on #328, 2026-11-01).
enum DialogCandidate {
    /// A native dialog or sheet, matched by role or subrole — the same test the
    /// scanner makes. The probe applies it only below its target window and
    /// outside window chrome.
    static func isDialog(role: String, subrole: String?) -> Bool {
        role == "AXSheet" || role == "AXDialog" || subrole == "AXDialog" || subrole == "AXSystemDialog"
    }

    /// Window chrome the entry probe does not enter: the toolbar, the tab bar and a
    /// tab button. On Safari 27.2 JavaScript dialogs appear inside the tab
    /// content (window → split group → tab group → dialog, the depth-3 case) and
    /// sheets as window children, never under these. A node the probe skips here is
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
    /// `AXRadioButton` / `AXTabButton`. The node behind the zh-Hant false
    /// positive (#328) was not reproduced; this list is one of the shapes the
    /// fix covers, not a named cause.
    static func isWindowChrome(role: String, subrole: String?) -> Bool {
        isChromeRole(role) || chromeBySubrole.contains { $0.role == role && $0.subrole == subrole }
    }

    /// The tab bar and a tab: chrome only with exactly this subrole. One list,
    /// read by both `isWindowChrome` and `needsSubroleForChrome`.
    private static let chromeBySubrole: [(role: String, subrole: String)] = [
        ("AXOpaqueProviderGroup", "AXOpaqueProviderList"),
        ("AXRadioButton", "AXTabButton"),
    ]

    /// The part of the chrome test that needs no subrole: the toolbar. The
    /// probe asks this right after reading the role, so a subrole read that
    /// fails on a toolbar cannot make the walk incomplete.
    static func isChromeRole(_ role: String) -> Bool {
        role == "AXToolbar"
    }

    /// Roles that are chrome only with a particular subrole (the tab bar and a
    /// tab). Reading a found dialog's text, the probe leaves such a node out
    /// when its subrole cannot be read; one with no subrole is not chrome.
    static func needsSubroleForChrome(_ role: String) -> Bool {
        chromeBySubrole.contains { $0.role == role }
    }

    /// One path element for debug output: the role, and the subrole when
    /// there is one. Never a title or a value.
    static func pathLabel(role: String, subrole: String?) -> String {
        guard let subrole, !subrole.isEmpty else { return role }
        return "\(role)/\(subrole)"
    }
}
