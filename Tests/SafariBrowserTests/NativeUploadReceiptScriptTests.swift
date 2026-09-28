import Foundation
import XCTest
@testable import SafariBrowser

final class NativeUploadReceiptScriptTests: XCTestCase {
    func testNativeReceiptComparisonAcceptsOnlyExactSecret() async throws {
        let token = "SB_UPLOAD_RECEIPT:AbC-PRIVATE"
        for (raw, expected) in [(token, "OK"), (token.lowercased(), "INVALID_RECEIPT"),
                                ("OK", "INVALID_RECEIPT"), ("PENDING", "PENDING"),
                                ("MISMATCH_NAME", "MISMATCH_NAME"), ("", "INVALID_RECEIPT"),
                                (token + "x", "INVALID_RECEIPT")] {
            let source = "set rawReceipt to \"\(raw.escapedForAppleScript)\"\n" +
                NativeUploadScript.receiptValidationScript(receiptToken: token)
            let result = try await SafariBridge.runShell("/usr/bin/osascript", ["-e", source], timeout: 3)
            XCTAssertEqual(result, expected)
        }
    }
}
