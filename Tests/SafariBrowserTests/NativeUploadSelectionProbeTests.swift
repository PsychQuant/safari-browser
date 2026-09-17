import Foundation
import XCTest
@testable import SafariBrowser

final class NativeUploadSelectionProbeTests: XCTestCase {
    struct Node {
        var role: String
        var identifier: String? = nil
        var selected: Bool? = nil
        var url: URL? = nil
        var edges: [String: [Int]] = [:]
        var id: Int = 0
    }
    final class Provider: NativeUploadSelectionProvider {
        var nodes: [Int: Node] = [:]
        var active = true
        var roots = [0]
        var reads: [(Int, String)] = []
        var canonical: [URL: String] = [:]
        func foreground() throws -> Bool { active }
        func windows() throws -> [Int] { roots }
        func windowID(_ node: Int) throws -> Int { nodes[node]!.id }
        func string(_ node: Int, _ attribute: String) throws -> String? {
            attribute == "AXRole" ? nodes[node]!.role : nodes[node]!.identifier
        }
        func selected(_ node: Int) throws -> Bool? { nodes[node]!.selected }
        func url(_ node: Int) throws -> URL? { nodes[node]!.url }
        func elements(_ node: Int, _ attribute: String, limit: Int) throws -> [Int] {
            reads.append((node, attribute)); return nodes[node]!.edges[attribute] ?? []
        }
        func canonicalRegularFile(_ url: URL) throws -> String { canonical[url] ?? url.path }
    }
    let path = "/tmp/.隱藏 空白's/檔案.txt"
    func fixture(_ mode: String) -> Provider {
        let p = Provider()
        p.nodes[0] = Node(role: "AXWindow", edges: ["AXChildren": [1]], id: 42)
        p.nodes[1] = Node(role: "AXSheet", identifier: "open-panel", edges: ["AXChildren": [2]])
        p.nodes[2] = Node(role: "AXSplitGroup", edges: ["AXChildren": [3]])
        p.nodes[3] = Node(role: mode == "ColumnView" ? "AXBrowser" : mode == "ListView" ? "AXOutline" : "AXList", identifier: mode)
        p.nodes[4] = Node(role: "AXGroup", edges: ["AXChildren": [5]])
        p.nodes[5] = Node(role: mode == "IconView" ? "AXImage" : "AXTextField", selected: true, url: URL(fileURLWithPath: path))
        if mode == "ColumnView" {
            p.nodes[3]!.edges["AXColumns"] = [6]
            p.nodes[6] = Node(role: "AXScrollArea", edges: ["AXContents": [7]])
            p.nodes[7] = Node(role: "AXList", edges: ["AXSelectedChildren": [4]])
        } else { p.nodes[3]!.edges[mode == "ListView" ? "AXSelectedRows" : "AXSelectedChildren"] = [4] }
        return p
    }
    func verdict(_ p: Provider, maxNodes: Int = 256, maxDepth: Int = 18) -> String {
        NativeUploadSelectionProbe.inspect(provider: p, windowID: 42, expectedPath: path,
            deadline: .now() + 1, maxNodes: maxNodes, maxDepth: maxDepth)
    }
    func testMeasuredViewsSelectExactHiddenUnicodeFile() {
        for mode in ["ColumnView", "ListView", "IconView"] { XCTAssertEqual(verdict(fixture(mode)), "MATCH", mode) }
    }
    func testRejectsMissingSelectedLeafAndWrongPath() {
        let p = fixture("ListView")
        p.nodes[5]!.selected = false
        XCTAssertNotEqual(verdict(p), "MATCH")
        p.nodes[5]!.selected = true; p.nodes[5]!.url = URL(fileURLWithPath: "/tmp/other")
        XCTAssertNotEqual(verdict(p), "MATCH")
    }
    func testDoesNotEnumerateUnselectedRowsOrWebContent() {
        let p = fixture("ListView")
        p.nodes[3]!.edges["AXChildren"] = Array(repeating: 99, count: 10000)
        p.nodes[2]!.edges["AXChildren"]! += [8,9]
        p.nodes[8] = Node(role: "AXWebArea", edges: ["AXChildren": [99]])
        p.nodes[9] = Node(role: "AXScrollArea", identifier: "_NS:61", edges: ["AXChildren": [99]])
        XCTAssertEqual(verdict(p), "MATCH")
        XCTAssertFalse(p.reads.contains { ($0.0 == 3 || $0.0 == 8 || $0.0 == 9) && $0.1 == "AXChildren" })
    }
    func testRefusesMultipleSelectionEvenWhenOnlyOneLeafMatches() {
        let p = fixture("IconView")
        p.nodes[3]!.edges["AXSelectedChildren"] = [4,4]
        XCTAssertNotEqual(verdict(p), "MATCH")
    }
    func testRefusesBoundsAndExpiredDeadline() {
        let p = fixture("ListView")
        XCTAssertNotEqual(verdict(p, maxNodes: 3), "MATCH")
        XCTAssertNotEqual(verdict(p, maxDepth: 2), "MATCH")
        XCTAssertNotEqual(NativeUploadSelectionProbe.inspect(provider: p, windowID: 42, expectedPath: path, deadline: .now()), "MATCH")
        p.nodes[2]!.edges["AXChildren"] = Array(repeating: 3, count: 65)
        XCTAssertNotEqual(verdict(p), "MATCH")
    }
    func testRefusesWindowFocusPanelAndModeAmbiguity() {
        let p = fixture("ListView")
        p.active = false; XCTAssertNotEqual(verdict(p), "MATCH")
        p.active = true; p.roots = [0,0]; XCTAssertNotEqual(verdict(p), "MATCH")
        p.roots = [0]; p.nodes[0]!.edges["AXChildren"] = [1,1]; XCTAssertNotEqual(verdict(p), "MATCH")
        p.nodes[0]!.edges["AXChildren"] = [1]; p.nodes[3]!.identifier = "UnknownView"
        XCTAssertNotEqual(verdict(p), "MATCH")
    }
    func testColumnAncestorDirectoryIsNotFinalSelection() {
        let p = fixture("ColumnView")
        p.nodes[3]!.edges["AXColumns"]! += [8]
        p.nodes[8] = Node(role: "AXScrollArea", edges: ["AXContents": [9]])
        p.nodes[9] = Node(role: "AXList", edges: ["AXSelectedChildren": [10]])
        p.nodes[10] = Node(role: "AXGroup", edges: ["AXChildren": [11]])
        p.nodes[11] = Node(role: "AXTextField", selected: false, url: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(verdict(p), "MATCH")
        p.nodes[11]!.selected = true
        XCTAssertNotEqual(verdict(p), "MATCH")
    }
    func testRejectsDuplicateViewsNestedPanelAndExcessWindows() {
        let p = fixture("ListView")
        p.nodes[2]!.edges["AXChildren"] = [3,3]
        XCTAssertNotEqual(verdict(p), "MATCH")
        p.nodes[2]!.edges["AXChildren"] = [3,8]
        p.nodes[8] = Node(role: "AXSheet")
        XCTAssertNotEqual(verdict(p), "MATCH")
        p.nodes[2]!.edges["AXChildren"] = [3]
        p.roots = Array(repeating: 0, count: 33)
        XCTAssertNotEqual(verdict(p), "MATCH")
    }
    func testRequiresLeafEvidenceAndOneCandidate() {
        let p = fixture("IconView")
        p.nodes[5]!.role = "AXGroup"
        XCTAssertNotEqual(verdict(p), "MATCH")
        p.nodes[5]!.role = "AXImage"
        p.nodes[4]!.edges["AXChildren"] = [5,5]
        XCTAssertNotEqual(verdict(p), "MATCH")
    }
    func testProductionFileReferenceResolutionAndRegularFileRequirement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-selection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".隱藏 空白'檔案.txt")
        try Data("owned".utf8).write(to: file)
        let referenceCF = try XCTUnwrap(CFURLCreateFileReferenceURL(kCFAllocatorDefault, file as CFURL, nil))
        // Preserve the CF URL object until NSURL.filePathURL; bridging through
        // Swift URL first can eagerly turn a file reference into a path URL.
        let reference = unsafeBitCast(referenceCF, to: NSURL.self)
        XCTAssertTrue(reference.isFileReferenceURL())
        let resolved = try NativeUploadSelectionProbe.canonicalRegularFile(reference)
        XCTAssertEqual(resolved, file.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertThrowsError(try NativeUploadSelectionProbe.canonicalRegularFile(directory))
        XCTAssertThrowsError(try NativeUploadSelectionProbe.canonicalRegularFile(URL(string: "https://example.invalid/file")!))
        XCTAssertThrowsError(try NativeUploadSelectionProbe.canonicalRegularFile(directory.appendingPathComponent("missing")))
        let p = fixture("ListView")
        p.nodes[5]!.url = reference as URL
        p.canonical[reference as URL] = path
        XCTAssertEqual(verdict(p), "MATCH")
    }
    func testInvalidDeadlineRefusesBeforeProductionAXAccess() {
        for deadline in [Double.nan, Double.infinity, 0] {
            XCTAssertNotEqual(NativeUploadSelectionProbe.check(windowID: 42, expectedPath: path, deadlineUptime: deadline), "MATCH")
        }
    }

    func testRefusesCapturedPathWhoseCanonicalReferentChanged() {
        let p = fixture("ListView")
        p.canonical[URL(fileURLWithPath: path)] = "/tmp/other.txt"
        p.nodes[5]!.url = URL(fileURLWithPath: "/tmp/other.txt")
        XCTAssertNotEqual(verdict(p), "MATCH")
    }

    func testSelectedReferenceMayResolveToUnchangedCapturedPath() {
        let p = fixture("ListView")
        let selectedReference = URL(fileURLWithPath: "/tmp/selected-symlink.txt")
        p.nodes[5]!.url = selectedReference
        p.canonical[selectedReference] = path
        XCTAssertEqual(verdict(p), "MATCH")
    }

}
