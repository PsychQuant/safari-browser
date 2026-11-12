import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #362 item 2: a failed enumeration in the miss translation says it failed and claims nothing about what is open.
final class EnumerationFailureNoteTests: XCTestCase, @unchecked Sendable {
    private func flat(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    // MARK: item 2 and the notes-only listing

    /// No entry has coordinates, so the hint does not say each one does. An empty listing has no entry at all
    /// (verify F5/F7): `tabs --window 1` with no Safari window reaches it.
    func testANotesOnlyListingDoesNotClaimCoordinates() {
        for listing in [["(no window of profile \"Work\" is open)"], ["(no such window)"], []] {
            for pattern in ["window 5", "document 3"] {
                let message = flat(SafariBrowserError.documentNotFound(pattern: pattern, availableDocuments: listing).localizedDescription)
                XCTAssertFalse(message.contains("each entry above"), "\(listing): \(message)")
                XCTAssertTrue(message.contains("no tab is listed above"), "\(listing): \(message)")
            }
        }
    }

    func testAFailedEnumerationSaysItFailedAndClaimsNothingAboutWhatIsOpen() async throws {
        let targets: [SafariBridge.TargetDocument] = [
            .resolvedTab(windowID: 202, tabInWindow: 1, rematch: nil, profile: "Work"),
            .resolvedTab(windowID: 202, tabInWindow: 1, rematch: nil, profile: nil),
            .windowIndex(5),
        ]
        for target in targets {
            let fake = FakeSafari(windows: FakeSafari.workIsTwoAndThree)
            fake.listingError = SafariBrowserError.appleScriptFailed(
                "execution error: Can’t get https://secret.example/p?token=SECRET. (-1712)")
            do {
                _ = try await fake.drive { try await SafariBridge.getCurrentTitle(target: target) }
                XCTFail("\(target) must miss")
            } catch SafariBrowserError.documentNotFound(_, let entries) {
                XCTAssertEqual(entries.count, 1, "\(target): \(entries)")
                let note = try XCTUnwrap(entries.first)
                XCTAssertTrue(note.hasPrefix("(the open tabs could not be listed"), "\(target): \(note)")
                XCTAssertTrue(note.contains("-1712"), note)
                let message = SafariBrowserError.documentNotFound(pattern: "x", availableDocuments: entries).localizedDescription
                for claim in ["no Safari documents are currently open", "no window of profile", "secret.example",
                              "SECRET", "each entry above shows its own coordinates"] {
                    XCTAssertFalse(message.contains(claim), "\(target): \(message)")
                }
                let positional = SafariBrowserError.documentNotFound(pattern: "window 5", availableDocuments: entries).localizedDescription
                XCTAssertFalse(positional.contains("each entry above shows its own coordinates"), positional)
            }
            XCTAssertEqual(fake.listings, 1, "\(target)")
        }
    }

    func testTheFailureNoteNamesTheKindOfFailureOnly() async throws {
        let cases: [(Error, String)] = [
            (SafariBrowserError.windowEnumerationCorrupt(reason: "window 2 has 3 URLs and 4 titles"), "malformed"),
            (SafariBrowserError.processTimedOut(command: "osascript", seconds: 7), "timed out"),
            (SafariBrowserError.appleScriptFailed("execution error: no code here"), "AppleScript error"),
        ]
        for (error, kind) in cases {
            let fake = FakeSafari(windows: FakeSafari.workIsTwoAndThree)
            fake.listingError = error
            do {
                _ = try await fake.drive {
                    try await SafariBridge.getCurrentTitle(target: .resolvedTab(windowID: 202, tabInWindow: 1, rematch: nil, profile: "Work"))
                }
                XCTFail("must miss")
            } catch SafariBrowserError.documentNotFound(_, let entries) {
                XCTAssertEqual(entries.count, 1, "\(entries)")
                XCTAssertTrue(entries[0].hasPrefix("(the open tabs could not be listed"), entries[0])
                XCTAssertTrue(entries[0].contains(kind), entries[0])
                XCTAssertFalse(entries[0].contains("no code here") || entries[0].contains("4 titles"), entries[0])
            }
        }
    }

    /// #362 verify r2 F (finding 16): a URL target whose tab disappeared, and whose follow-up enumeration failed, gets
    /// the failure hint, not the URL hint's advice about entries and coordinates.
    func testAURLTargetWhoseEnumerationFailsGetsTheFailureHint() async throws {
        let fake = FakeSafari(windows: FakeSafari.workIsTwoAndThree)
        fake.closesAfterListing = (404, 1)
        fake.listingError = SafariBrowserError.processTimedOut(command: "osascript", seconds: 9)
        fake.listingErrorFrom = 2
        do {
            var command = try GetTitle.parse(["--url", "b1"])
            try await fake.drive { try await command.run() }
            XCTFail("the tab closed")
        } catch let error as SafariBrowserError {
            guard case .documentNotFound(let pattern, let entries) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(pattern, "b1")
            XCTAssertEqual(entries.count, 1, "\(entries)")
            let message = flat(error.localizedDescription)
            XCTAssertTrue(message.contains("the open tabs could not be listed afterwards"), message)
            XCTAssertFalse(message.contains("coordinates are shown per entry"), message)
            XCTAssertFalse(message.contains("Refine it against the URLs above"), message)
        }
        XCTAssertEqual(fake.listings, 2)
    }

    func testACancelledEnumerationIsNotReportedAsAMiss() async throws {
        let fake = FakeSafari(windows: FakeSafari.workIsTwoAndThree)
        fake.listingError = CancellationError()
        do {
            _ = try await fake.drive {
                try await SafariBridge.getCurrentTitle(target: .resolvedTab(windowID: 202, tabInWindow: 1, rematch: nil, profile: "Work"))
            }
            XCTFail("must fail")
        } catch is CancellationError {}
    }
}
