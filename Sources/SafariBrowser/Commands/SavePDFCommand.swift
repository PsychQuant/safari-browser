import ArgumentParser
import Foundation

/// `save-pdf <path>` (#338): the PDF a tab displays, from the bytes WebKit already holds.
///
/// Non-interfering: it evaluates JavaScript in the targeted tab and writes the file it was told to, with no
/// request, no input events, no tab switch. It is separate from `pdf-cache` on purpose: that command's contract
/// is that it never touches Safari, and this one has to read from inside the tab.
struct SavePDFCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "save-pdf",
        abstract: "Save the PDF a tab displays, from the bytes WebKit already holds, without requesting it",
        discussion: """
            Name the tab explicitly: --url, --url-exact, --url-endswith, --url-regex, --window [--tab-in-window], \
            --window-id [--tab-in-window], --document or --tab. The tab must display the PDF itself; a PDF embedded in an HTML page is not covered. \
            The read uses fetch with cache 'only-if-cached', which cannot reach the network: when WebKit no longer \
            holds the document the command fails and the document is not requested. A page controlled by a service worker is refused.
            """
    )

    @Argument(help: "Where to write the PDF (the folder must exist)")
    var path: String

    @Flag(name: .long, help: "Replace the destination if it exists")
    var force = false

    @Flag(name: .long, help: "Output as JSON object")
    var json = false

    @OptionGroup var target: TargetOptions

    func validate() throws {
        guard !path.isEmpty else { throw ValidationError("The destination path must not be empty.") }
        guard target.hasExplicitTarget else {
            throw ValidationError(
                "save-pdf needs an explicit tab: --url, --url-exact, --url-endswith, --url-regex, --window [--tab-in-window], --window-id [--tab-in-window], --document or --tab. It never reads the front tab by default.")
        }
    }

    func run() async throws {
        // Before the transfer: a refusal after moving 50 MB through `do JavaScript` helps nobody.
        // `copyVerified` still makes the final decision.
        try PDFCacheOutput.refuseExistingDestination(path, force: force)
        let original = target.resolve()
        let anchored = try await SafariBridge.resolveToAnchoredTarget(
            original, firstMatch: target.firstMatch,
            warnWriter: TargetOptions.stderrWarnWriter, profile: target.profile)
        let read: TabPDFReader.Read
        do {
            read = try await TabPDFReader.read(target: anchored, firstMatch: target.firstMatch)
        } catch let error as SafariBrowserError {
            // A tab that vanished names the target; the untranslated error lists every profile's tabs.
            throw JSCommand.anchoredFailure(error, original: original, anchored: anchored)
        }
        let result = try TabPDFReader.publish(read, to: path, force: force)
        let url = URLText.redactURL(read.url)
        if json {
            print(String(decoding: try PDFCacheFormat.tabSavedJSON(result, url: url), as: UTF8.self))
        } else {
            print(PDFCacheFormat.tabSavedRow(result, url: url))
        }
    }
}
