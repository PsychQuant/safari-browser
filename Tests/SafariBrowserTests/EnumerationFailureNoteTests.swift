import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #362 item 2: a failed enumeration in the miss translation says it failed and claims nothing about what is open.
final class EnumerationFailureNoteTests: XCTestCase, @unchecked Sendable {
    private func flat(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    // MARK: item 2 and the notes-only listing

    /// No entry has coordinates, so the hint does not say each one does.
    func testANotesOnlyListingDoesNotClaimCoordinates() {
        for listing in [["(no window of profile \"Work\" is open)"], ["(no such window)"]] {
            let message = flat(SafariBrowserError.documentNotFound(pattern: "window 5", availableDocuments: listing).localizedDescription)
            XCTAssertFalse(message.contains("each entry above shows its own coordinates"), message)
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
                XCTAssertFalse(entries[0].contains("no code here"), entries[0])
            }
        }
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
