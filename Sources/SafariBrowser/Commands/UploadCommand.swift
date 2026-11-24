import ArgumentParser
import Foundation

struct UploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload",
        abstract: "Upload a file via file input element"
    )

    @Argument(help: "CSS selector of the file input element")
    var selector: String

    @Argument(help: "Path to the file to upload")
    var filePath: String

    @Flag(name: .long, help: "Use JS DataTransfer injection instead of native file dialog (no Accessibility permission needed, but slow for large files)")
    var js = false

    @Flag(name: .long, help: "Use native file dialog (default behavior, kept for backward compatibility)")
    var native = false

    @Flag(name: .long, help: "Allow keyboard/mouse simulation (kept for backward compatibility)")
    var allowHid = false

    @Option(
        name: .long,
        help: """
            Seconds before the native file dialog subprocess is terminated (default: 60). \
            Default 60 accommodates the inner AppleScript's three 10-second maxWait loops \
            (dialog-open, Go-to-Folder-open, Go-to-Folder-close).
            """
    )
    var timeout: Double = 60.0

    @OptionGroup var target: TargetOptions

    /// #24 fix: `--js` path hard cap. Above this size, the base64 + JS
    /// DataTransfer approach is fundamentally unsafe (V8 memory pressure,
    /// osascript roundtrip count) even with the R1 Array.push fix. Users
    /// MUST use `--native` for large files — it mimics human upload and
    /// is the canonical path.
    private static let jsHardCapBytes = 10 * 1_048_576   // 10 MB

    /// The stderr warning emitted before the native path takes the keyboard.
    ///
    /// Extracted from the call site and pinned by a test (#104) because of what
    /// it is load-bearing for. The `non-interference` spec normally requires an
    /// explicit opt-in flag before any interference; `upload` is the one command
    /// allowed to substitute a macOS Accessibility grant for that flag, and the
    /// exception holds only while this warning is still emitted. Soften it or
    /// drop it and the exception becomes what the spec exists to forbid —
    /// interference the user was never told about.
    ///
    /// The spec asks the warning to say two things: which kind of interference,
    /// and that the user's input is unavailable meanwhile. Both are asserted.
    static let keyboardControlWarning =
        "⚠️  Controlling keyboard for file dialog (~1s). Do not type in Safari until complete.\n"

    /// Whether a run takes the native file-dialog path (keystrokes) or the JS
    /// DataTransfer path (no interference).
    ///
    /// The probe is a parameter rather than a `Bool` for two reasons. It keeps
    /// the routing testable without a TCC grant, and it makes the short-circuit
    /// *observable*: an explicit flag decides on its own, so the permission API
    /// is never consulted in that case. Passing a pre-computed `Bool` would have
    /// hidden an eager probe behind an identical truth table.
    ///
    /// Note the direction, which surprises people: holding the grant moves you
    /// *onto* the interfering path, not off it. A caller without it gets the JS
    /// path — which is the only reason the spec's `upload` exemption is
    /// defensible, and the reason it stops being defensible above the 10 MB cap.
    static func resolveNativeRouting(
        native: Bool, allowHid: Bool, accessibilityProbe: () -> Bool
    ) -> Bool {
        if native || allowHid { return true }
        return accessibilityProbe()
    }
    private static let jsSoftWarnBytes = 5 * 1_048_576   // 5 MB

    func validate() throws {
        // Mirror runProcessWithTimeout's bounds so invalid CLI input surfaces
        // with a user-friendly ArgumentParser usage error before reaching the
        // library layer (#19 R2-F1').
        guard timeout.isFinite, timeout >= 0.001, timeout <= 86_400 else {
            throw ValidationError("--timeout must be a finite number between 0.001 and 86400 seconds, got \(timeout)")
        }

        // #26: --native / --allow-hid no longer rejects --url / --tab /
        // --document. The native-path resolver (SafariBridge.resolveNativeTarget)
        // maps those targeting flags to a concrete (window, tab) pair at
        // runtime and performs tab-switch + raise before keystroke dispatch.
        // The previous #23 R5 reject was removed here; see proposal #26.

        // #24: hard cap --js at 10 MB. The cap fires for explicit --js
        // (where the user has definitely chosen the JS path) and for the
        // fallback JS path in run() when Accessibility permission is
        // absent. Smart-default routing with targeting flags can no
        // longer be assumed to force JS at validate time — under #26,
        // smart default with targeting routes through native when AX is
        // available. The runtime fallback check in run() handles the
        // no-AX-perm case; see checkJsSizeCapIfNeeded().
        if js {
            try checkJsSizeCap()
        }
    }

    /// Enforce the 10 MB hard cap on the JS DataTransfer path. Called
    /// from validate() for explicit `--js` and from run() when falling
    /// back to JS without Accessibility permission.
    internal func checkJsSizeCap() throws {
        let expandedPath = (filePath as NSString).expandingTildeInPath
        // Missing file is a separate error thrown in run(); don't double-error.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: expandedPath),
              let size = attrs[.size] as? Int else {
            return
        }
        if size > UploadCommand.jsHardCapBytes {
            let sizeMB = Double(size) / 1_048_576
            throw ValidationError("""
                --js mode is capped at 10 MB (file is \(String(format: "%.1f", sizeMB)) MB).
                Reason: --js uses JavaScript DataTransfer + base64 chunking which is fundamentally \
                memory-heavy and does not mimic human upload behavior. Previous attempts with large \
                files crashed Safari even on machines with 128 GB RAM (see #24).

                For larger files use --native (which now accepts --url / --tab / --document via the \
                native-path resolver, #26):
                  safari-browser upload --native "\(selector)" "\(filePath)" --url <pattern>

                --native requires Accessibility permission but is the canonical large-file path
                (mimics human "choose file" dialog exactly). Small files (<10 MB) can still use --js.
                """)
        }
        if size > UploadCommand.jsSoftWarnBytes {
            let sizeMB = Double(size) / 1_048_576
            FileHandle.standardError.write(Data(
                "⚠️  File is \(String(format: "%.1f", sizeMB)) MB — --js is slow for files >5 MB. Consider --native.\n".utf8
            ))
        }
    }

    func run() async throws {
        try await run(accessibilityProbe: SafariBridge.isAccessibilityPermitted)
    }

    /// `accessibilityProbe` is a seam: without permission and without `--native` the command
    /// falls back to the JS path, which a test cannot otherwise reach (#231).
    func run(accessibilityProbe: () -> Bool) async throws {
        let expandedPath = (filePath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw SafariBrowserError.fileNotFound(filePath)
        }

        // --js explicitly selects JS DataTransfer path. Size cap already
        // enforced at validate() time.
        if js {
            // #51: scope to --profile via a concrete target (10 MB JS path); #231: and honour
            // --first-match, once, instead of once per chunk.
            // #354: the JavaScript path resolves --window N to the window's id once. The native paths do the same
            // in `nativeUploadPlan` (#353).
            let scoped = try await target.pinWindowAtStart().resolveFirstMatchOnce()
            try await uploadViaJSDataTransfer(selector: selector, path: expandedPath, target: scoped, firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter)
            return
        }

        // Decide whether to go native. Conditions:
        //   - Explicit --native / --allow-hid (user chose)
        //   - OR Accessibility permission is granted (smart default)
        // In both cases, #26 routes through the resolver so --url /
        // --tab / --document all land on a concrete (window, tab) pair
        // before keystroke dispatch.
        let wantNative = UploadCommand.resolveNativeRouting(
            native: native,
            allowHid: allowHid,
            accessibilityProbe: accessibilityProbe)
        if wantNative {
            try await runNativeWithResolver(expandedPath: expandedPath)
            return
        }

        // No AX permission and no explicit --native → fall back to JS
        // with an informational stderr note. The size cap must be
        // enforced here because the validate-time check only fires for
        // explicit --js (we don't know at validate time which path the
        // runtime will pick).
        try checkJsSizeCap()
        FileHandle.standardError.write(Data("""
            ℹ️  Using JS DataTransfer (slower for large files).
                Grant Accessibility permission in System Settings → Privacy & Security → Accessibility
                to enable fast native file dialog upload.\n
            """.utf8))
        // #354: as for --js above.
        let scoped = try await target.pinWindowAtStart().resolveFirstMatchOnce()
        try await uploadViaJSDataTransfer(selector: selector, path: expandedPath, target: scoped, firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter)
    }

    /// What a native upload is about to do once its target is resolved and, when needed, switched to.
    struct NativeUploadPlan {
        /// How the dialog script names the window.
        let window: SafariBridge.ActingWindow
        /// The document the existence read and the file-input click address. For a named tab it is that tab
        /// only while it is still its window's current tab (`SafariBridge.clickTarget`).
        let jsTarget: SafariBridge.TargetDocument
        /// The target a miss is worded for.
        let missTarget: SafariBridge.TargetDocument
        let profile: String?
        let effects: [NativeUploadEffect]
    }

    /// Everything a native upload does before System Events is involved (#353): `--window N` becomes the
    /// window's id once (#354), the target is resolved, a tab the resolution named is checked and made current
    /// when it is not, and the read that checks the target exists runs. Every step after the resolution names
    /// the window by its id.
    ///
    /// This is the #26 path that lets `--url` / `--tab` / `--document` reach the native dialog. It is separate
    /// from the part that runs the effects so a test can drive it against a fake Safari: the dialog script goes
    /// straight to `osascript`.
    ///
    /// `notice` receives the tab-switch addendum, before the switch (the keyboard warning is the plan's first
    /// effect). The preflight read comes before any warning, so a bad `--window 99` surfaces
    /// `documentNotFound` with the listing before the user is told the keyboard is being taken over (#23).
    func nativeUploadPlan(
        expandedPath: String,
        notice: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) async throws -> NativeUploadPlan {
        let target = try await self.target.pinWindowAtStart()
        let profile = target.resolveProfile()
        let named = target.resolve()
        let resolved = try await SafariBridge.resolveWindowLevelTarget(
            named: named, firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter, profile: profile)
        let window = SafariBridge.actingWindow(for: resolved, named: named, profile: profile)
        let jsTarget = SafariBridge.clickTarget(for: resolved, named: named, profile: profile)
        let missTarget = SafariBridge.actedTarget(for: resolved, named: named, profile: profile)

        // Tab switch is a passively interfering side effect transitively
        // authorized by --native / --allow-hid. The keyboard warning is the
        // plan's first effect; this addendum says what extra interaction is
        // about to happen.
        if resolved.tabIndexInWindow != nil {
            notice("ℹ️  Target tab will be brought to the front of its window before upload.\n")
        }
        try await SafariBridge.bringResolvedTabForward(resolved, named: named, profile: profile)

        // The read that checks the target exists. Its answer is compared with the flag: a tab found by its
        // URL that has navigated since the tab script checked it stops the upload here (verify r1).
        let shown = try await SafariBridge.translatingWindowLevelMarkers(
            target: missTarget, profile: profile, translateNotFound: true, stage: .afterTabSwitch
        ) {
            try await SafariBridge.getCurrentURL(target: jsTarget)
        }
        if case .urlMatch(let matcher) = named, !matcher.matches(shown) {
            throw SafariBrowserError.targetChangedBeforeActing(
                expected: SafariBridge.targetDescription(missTarget), stage: .afterTabSwitch)
        }

        // The dialog script checks a named tab once more, in its first Safari block, when it acts by id.
        let dialogTab = window.windowID == nil ? nil : resolved.anchorTabIndex
        return NativeUploadPlan(
            window: window,
            jsTarget: jsTarget,
            missTarget: missTarget,
            profile: profile,
            effects: UploadCommand.nativeUploadEffects(
                selector: selector, path: expandedPath, window: window, tab: dialogTab,
                guardClause: dialogTab == nil ? nil
                    : SafariBridge.tabGuardClause(named: named, matchedURL: resolved.matchedURL)))
    }

    private func runNativeWithResolver(expandedPath: String) async throws {
        let plan = try await nativeUploadPlan(expandedPath: expandedPath)
        do {
            try await runNativeUpload(plan)
        } catch {
            // #67: the native file dialog can enter a stale state after a
            // prior aborted attempt (focus race / expired user gesture) where
            // it's visible but no longer accepts keystrokes — the Cmd+Shift+G
            // "Go to Folder" panel never appears, and bare retries loop. Rewrap
            // that opaque AppleScript timeout with actionable recovery guidance.
            if let guidance = Self.staleDialogGuidance(forErrorText: "\(error)") {
                throw SafariBrowserError.appleScriptFailed("\(error)\n\n\(guidance)")
            }
            throw error
        }
    }

    /// #67: detect the stale-file-dialog signature (the native dialog is
    /// visible but rejecting keystrokes, typically after a prior aborted
    /// attempt) and return actionable recovery guidance. Returns nil for
    /// unrelated errors so they propagate unchanged. Pure — unit-tested.
    static func staleDialogGuidance(forErrorText text: String) -> String? {
        let signatures = [
            "Go to Folder panel did not appear",
            "File dialog did not appear",
            "Go to Folder did not close",
        ]
        guard signatures.contains(where: { text.contains($0) }) else { return nil }
        return """
        The native file dialog opened but stopped accepting keystrokes — most likely a prior
        aborted attempt left it in a non-interactive state (focus race / expired user gesture, #67).
        Recover by either:
          • Dismiss any open file dialog (press Esc), then retry from a clean state.
          • Complete it manually: drag-and-drop the file into the upload area, OR switch to an
            English input source, press Cmd+Shift+G, and paste the path.
        Note: --js (DataTransfer) is capped at 10 MB (#24), so it is not a fallback for large files.
        """
    }

    // MARK: - Native file dialog

    /// Click file input to open dialog, then navigate via a single combined osascript.
    /// Merges activate + wait + keystroke navigation into one osascript invocation
    /// to prevent focus-stealing race conditions between separate calls (fixes #15).
    ///
    /// The three things that reach outside the process are parameters (the System Events probe, the dialog
    /// script's runner, stderr), so a test runs this function, wiring included, against a fake Safari: which
    /// document gets the click and how a failed check is translated are decided here (#353 verify r1).
    func runNativeUpload(
        _ plan: NativeUploadPlan,
        ensureLive: () async throws -> Void = { try await SafariBridge.ensureSystemEventsLive() },
        runDialogScript: (String, TimeInterval) async throws -> Void = { script, timeout in
            try await SafariBridge.runFileDialogScript(script, timeout: timeout)
        },
        warn: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) async throws {
        // #20: probe System Events before sending any keystrokes. A silent hang
        // inside the combined osascript is the single worst failure mode of this
        // command, and System Events being down is by far the most common cause.
        try await ensureLive()

        let timeout = self.timeout
        try await UploadCommand.runNativeUploadEffects(
            plan.effects,
            jsTarget: plan.jsTarget,
            warn: warn,
            // The click. A tab that stopped being current since the read fails its check here; by then the
            // command may already have made that tab current.
            runJS: { js, target in
                try await SafariBridge.translatingWindowLevelMarkers(
                    target: plan.missTarget, profile: plan.profile, translateNotFound: true, stage: .afterTabSwitch
                ) {
                    try await SafariBridge.doJavaScript(js, target: target)
                }
            },
            // Subprocess-level timeout (#19) bounds the whole invocation in case
            // System Events or Safari's Apple Event dispatcher is blocked and
            // the inner `maxWait to 10` loops never progress. A check that fails in this
            // script's first Safari block comes after the click: a file dialog may be open.
            runScript: { script in
                try await SafariBridge.translatingWindowLevelMarkers(
                    target: plan.missTarget, profile: plan.profile, stage: .afterFileDialog
                ) {
                    try await runDialogScript(script, timeout)
                }
            })
    }

    /// Executes the native path's effects in order.
    ///
    /// #104 round 2. The previous cut described the sequence as data and tested
    /// the description — which could not see the interpreter drifting away from
    /// it. An interpreter that skipped the warning, ran it after the chooser, or
    /// ignored the plan entirely would have left every test green. Injecting the
    /// three side effects lets a test run *this* function and watch what it
    /// actually does.
    ///
    /// The wiring that binds `warn` to stderr and the runners to `SafariBridge`
    /// is `runNativeUpload`, whose outside dependencies are parameters, so a
    /// test runs it too.
    static func runNativeUploadEffects(
        _ effects: [NativeUploadEffect],
        jsTarget: SafariBridge.TargetDocument,
        warn: (String) -> Void,
        runJS: (String, SafariBridge.TargetDocument) async throws -> String,
        runScript: (String) async throws -> Void
    ) async throws {
        for effect in effects {
            switch effect {
            case .warnOnStderr(let text):
                warn(text)

            case .openDialogByClickingFileInput(let sel, let js):
                if try await runJS(js, jsTarget) == "NOT_FOUND" {
                    throw SafariBrowserError.elementNotFound(sel)
                }

            case .runCombinedScript(let script):
                try await runScript(script)
            }
        }
    }

    /// What the native path does, in order, as data.
    ///
    /// #104. The spec's `upload` exemption rests on the user being warned
    /// *before* the interference starts — and interference here begins when the
    /// file chooser opens, not when the first keystroke lands. A test that only
    /// asserts on the warning's wording cannot see whether it is emitted at all,
    /// or when. Describing the sequence as a value puts both under test and
    /// leaves only a mechanical interpreter above.
    enum NativeUploadEffect: Equatable {
        /// Text that MUST go to stderr — never stdout — before anything below.
        case warnOnStderr(String)
        /// Opening the chooser. Interference in its own right, per the spec's
        /// "Display system dialogs, file choosers, or modal windows".
        case openDialogByClickingFileInput(selector: String, js: String)
        /// The one combined osascript. Must stay one (#15).
        case runCombinedScript(String)
    }

    static func nativeUploadEffects(
        selector: String, path: String, window: SafariBridge.ActingWindow?,
        tab: Int? = nil, guardClause: String? = nil
    ) -> [NativeUploadEffect] {
        [
            .warnOnStderr(keyboardControlWarning),
            .openDialogByClickingFileInput(
                selector: selector,
                js: "(function(){ var el = \(selector.resolveRefJS); "
                    + "if (!el) return 'NOT_FOUND'; el.click(); return 'OK'; })()"),
            .runCombinedScript(nativeDialogScript(path: path, window: window, tab: tab, guardClause: guardClause)),
        ]
    }

    /// The single combined script the native path runs. Pure, so both its
    /// atomicity and its use of the shared navigation fragment are testable
    /// without a Safari or a file dialog (#105).
    ///
    /// `window` raises that window first: keystrokes only ever reach the front
    /// window, so an explicit target has to be brought forward before the
    /// activate (#23).
    ///
    /// #353: by window id the script also checks who it is typing into. Its first Safari block ends the script
    /// with `SB_WINDOW_GONE` when the window is gone and, when the resolution named a tab (`tab`), with
    /// `SB_TAB_GONE` when that tab is gone and with `SB_TARGET_CHANGED` when it no longer passes the URL check
    /// (`guardClause`, for a tab found by its URL) or is no longer the window's current tab; all of that
    /// before anything is raised. It then reads the URL of the page the file dialog belongs to. Before every
    /// keystroke, in every wait and before the confirming click `verifyUploadOwner` stops the script unless
    /// that window is still open and is Safari's front window, the front window still shows that URL, and
    /// Safari is the frontmost application: System Events types into whichever application is frontmost, and
    /// Safari's own window order says nothing about that. By position, and with no window at all, the script
    /// is the one sent before #353.
    static func nativeDialogScript(
        path: String, window: SafariBridge.ActingWindow?, tab: Int? = nil, guardClause: String? = nil
    ) -> String {
        let ownerID = window?.windowID
        let dismiss = "If a file dialog is still open, dismiss it (Esc) before retrying."
        let ownerHandler = ownerID.map { _ in
            """
            on verifyUploadOwner(expectedID, expectedURL)
                tell application "Safari"
                    if not (exists window id expectedID) then error "Upload target window is no longer open; no further keystroke was sent. \(dismiss)"
                    if id of front window is not expectedID then error "Upload target window is not Safari's front window; no further keystroke was sent. \(dismiss)"
                    considering case
                        if URL of current tab of front window is not expectedURL then error "Upload target page changed; no further keystroke was sent. \(dismiss)"
                    end considering
                end tell
                tell application "System Events" to tell process "Safari"
                    if not frontmost then error "Safari is no longer the frontmost application; no further keystroke was sent. \(dismiss)"
                end tell
            end verifyUploadOwner


            """
        } ?? ""
        let ownerGuard = ownerID.map { "my verifyUploadOwner(\($0), uploadPageURL)" } ?? ""
        let raisePrelude: String
        switch window {
        case .id(let id)?:
            let reference = "window id \(id)"
            var lines = ["tell application \"Safari\"", SafariBridge.windowGoneCheck(windowID: id)]
            if let tab {
                lines.append(SafariBridge.tabGoneCheck(windowReference: reference, tab: tab))
                lines.append("set _t to tab \(tab) of \(reference)")
                if let guardClause { lines.append(guardClause) }
                lines.append(
                    "if (index of current tab of \(reference)) is not \(tab) then error \"SB_TARGET_CHANGED\" number \(SafariBridge.WindowLevelMarker.targetChanged)")
            }
            lines += [
                "set uploadPageURL to URL of current tab of \(reference)",
                "set index of \(reference) to 1",
                "end tell",
            ]
            raisePrelude = lines.joined(separator: "\n") + "\n"
        case .position(let index)?:
            raisePrelude = "tell application \"Safari\" to set index of window \(index) to 1\n"
        case nil:
            raisePrelude = ""
        }
        let afterDialogAppeared = ownerGuard.isEmpty ? "" : "\n        \(ownerGuard)\n"

        return """
            \(ownerHandler)\(raisePrelude)tell application "Safari" to activate
            tell application "System Events"
                tell process "Safari"
                    -- Verify Safari is frontmost before sending any keystrokes
                    if not frontmost then
                        error "Safari lost focus after activate — aborting to avoid sending keystrokes to wrong application"
                    end if

                    -- Wait for file dialog sheet to appear
                    set maxWait to 10
                    set waited to 0
                    repeat until exists sheet 1 of front window
                        delay 0.3
                        set waited to waited + 0.3
                        if waited >= maxWait then
                            error "File dialog did not appear within " & maxWait & " seconds"
                        end if
                    end repeat
            \(afterDialogAppeared)
            \(SafariBridge.fileDialogNavigationScript(path: path, ownerGuard: ownerGuard))
                end tell
            end tell
            """
    }

    // MARK: - JS DataTransfer (--js flag)

    /// Upload via JS base64 chunking + DataTransfer injection. Bounded by
    /// a 10 MB hard cap (`validate()`) because the base64 + JS roundtrip
    /// path is fundamentally memory-heavy and **not** a "mimic human"
    /// upload path — it's an accessibility-free fallback only.
    ///
    /// #24 fix: chunking uses `Array.push` + `Array.join` instead of
    /// `String +=`. V8's `string += string` is O(n²) cumulative — for
    /// a 131 MB file (175 MB base64) with 200 KB chunks, the old
    /// pattern allocated ~83 GB of transient garbage strings and
    /// crashed Safari even on machines with 128 GB RAM. Array push is
    /// O(1) amortized and the final join is a single allocation.
    ///
    /// `target` selects which Safari document the upload lands in;
    /// defaults to `.frontWindow` for backward compatibility (#23).
    private func uploadViaJSDataTransfer(
        selector: String,
        path: String,
        target: SafariBridge.TargetDocument = .frontWindow,
        firstMatch: Bool = false,
        warnWriter: ((String) -> Void)? = nil
    ) async throws {
        let fileData = try Data(contentsOf: URL(fileURLWithPath: path))
        let base64 = fileData.base64EncodedString()
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        let mimeType = guessMimeType(for: fileName)

        // Record initial URL (strip fragment) to detect page navigation during chunking
        let initialURL = try await SafariBridge.doJavaScript(
            "window.location.href.split('#')[0]",
            target: target, firstMatch: firstMatch, warnWriter: warnWriter
        )

        // #24: Transfer base64 in 200KB chunks via Array.push (NOT String +=).
        // String += triggers V8 O(n²) string concatenation which allocated
        // ~83 GB of transient garbage strings for a 131 MB file and crashed
        // Safari even on 128 GB RAM. Array.push is O(1) amortized; final
        // join is a single contiguous allocation.
        _ = try await SafariBridge.doJavaScript("window.__sbUploadChunks = []", target: target, firstMatch: firstMatch, warnWriter: warnWriter)
        let chunkSize = 200_000
        var offset = base64.startIndex
        var chunkCount = 0
        let totalChunks = (base64.count + chunkSize - 1) / chunkSize
        while offset < base64.endIndex {
            let end = base64.index(offset, offsetBy: chunkSize, limitedBy: base64.endIndex) ?? base64.endIndex
            let chunk = String(base64[offset..<end])
            _ = try await SafariBridge.doJavaScript("window.__sbUploadChunks.push('\(chunk.escapedForJS)')", target: target, firstMatch: firstMatch, warnWriter: warnWriter)
            offset = end
            chunkCount += 1

            // Check URL every 10 chunks (strip fragment for comparison)
            if chunkCount % 10 == 0 {
                let currentURL = try await SafariBridge.doJavaScript(
                    "window.location.href.split('#')[0]",
                    target: target, firstMatch: firstMatch, warnWriter: warnWriter
                )
                if currentURL != initialURL {
                    _ = try? await SafariBridge.doJavaScript("delete window.__sbUploadChunks", target: target, firstMatch: firstMatch, warnWriter: warnWriter)
                    throw SafariBrowserError.appleScriptFailed(
                        Self.navigatedAwayMessage(initialURL: initialURL, currentURL: currentURL)
                    )
                }
            }

            // Progress indicator for large files
            if totalChunks > 10 && chunkCount % 10 == 0 {
                FileHandle.standardError.write(Data("  uploading: \(chunkCount)/\(totalChunks) chunks\n".utf8))
            }
        }

        // Inject file via DataTransfer — join chunks once, then decode + wrap.
        let jsResult = try await SafariBridge.doJavaScript("""
            (function(){
                var el = \(selector.resolveRefJS);
                if (!el) return 'NOT_FOUND';
                try {
                    var full = window.__sbUploadChunks.join('');
                    delete window.__sbUploadChunks;
                    var bin = atob(full);
                    full = null;
                    var bytes = new Uint8Array(bin.length);
                    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
                    bin = null;
                    var blob = new Blob([bytes], {type: '\(mimeType)'});
                    var file = new File([blob], '\(fileName.escapedForJS)', {type: '\(mimeType)'});
                    var dt = new DataTransfer();
                    dt.items.add(file);
                    el.files = dt.files;
                    el.dispatchEvent(new Event('change', {bubbles: true}));
                    return 'OK';
                } catch(e) {
                    return 'JS_FAILED:' + e.message;
                }
            })()
            """, target: target, firstMatch: firstMatch, warnWriter: warnWriter)

        if jsResult == "NOT_FOUND" {
            _ = try? await SafariBridge.doJavaScript("delete window.__sbUploadChunks", target: target, firstMatch: firstMatch, warnWriter: warnWriter)
            throw SafariBrowserError.elementNotFound(selector)
        }

        if jsResult != "OK" {
            _ = try? await SafariBridge.doJavaScript("delete window.__sbUploadChunks", target: target, firstMatch: firstMatch, warnWriter: warnWriter)
            throw SafariBrowserError.appleScriptFailed("JS file injection failed: \(jsResult)")
        }
    }

    /// #227: the two URLs are shown without their queries, so a page that only changed its query
    /// (or something else that is not shown) would print the same text twice. Say so, instead of
    /// leaving a message that reads as if nothing changed.
    static func navigatedAwayMessage(initialURL: String, currentURL: String) -> String {
        let was = URLText.redactURL(initialURL)
        let now = URLText.redactURL(currentURL)
        let unseen = was == now ? " — they differ in a part that is not shown here" : ""
        return "Page navigated away during upload (was: \(was), now: \(now)\(unseen)). Upload aborted."
    }

    private func guessMimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "mp3": return "audio/mpeg"
        case "mp4": return "video/mp4"
        case "wav": return "audio/wav"
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "doc", "docx": return "application/msword"
        case "txt": return "text/plain"
        case "csv": return "text/csv"
        default: return "application/octet-stream"
        }
    }
}
