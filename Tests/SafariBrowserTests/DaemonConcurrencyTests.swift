import XCTest
import Foundation
@testable import SafariBrowser

/// Task 10.1 — asserts that the `CompileCache` actor enforces
/// insert-on-miss serialization under concurrent access. This is the
/// real actor-isolation invariant: N parallel callers racing on
/// `compile(source:)` with the same source MUST produce exactly one
/// cached entry, and the same cached `NSAppleScript` MUST be reused.
///
/// The full IPC round-trip is covered by `DaemonDispatchTests` in the
/// serial case (N identical requests → cacheCount == 1); that path
/// makes blocking socket syscalls that would starve Swift's cooperative
/// thread pool under TaskGroup parallelism. The actor invariant this
/// test targets is independent of the socket layer — driving it via
/// `withThrowingTaskGroup` on the actor directly exercises the exact
/// "multiple callers race past the `cache[source]` nil-check together"
/// condition that the end-to-end path would need the scheduler to
/// simulate faithfully.
///
/// Covers the task-10.1 bullet "actor serialization of concurrent requests".
final class DaemonConcurrencyTests: XCTestCase {

    // Uses a real AppleScript expression (arithmetic). The compile step
    // takes a couple of milliseconds, which widens the window where two
    // callers could concurrently observe `cache[source] == nil` if the
    // actor lock were missing. The test asserts the actor closes that
    // window cleanly.

    /// N parallel callers compile the SAME source. Exactly one entry
    /// MUST end up cached; the actor's serialization guarantees
    /// insert-on-miss even when all callers check the nil-branch
    /// together.
    func testCompileCache_sameSource_cachesExactlyOnce_underConcurrency() async throws {
        let cache = PreCompiledScripts.CompileCache()
        let source = "return 21 * 2"

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    try await cache.compile(source: source)
                }
            }
            try await group.waitForAll()
        }

        let count = await cache.cacheCount
        XCTAssertEqual(
            count, 1,
            "32 concurrent compiles of the same source should cache exactly once"
        )
        let contains = await cache.contains(source: source)
        XCTAssertTrue(contains, "the cached handle should match the requested source")
    }

    /// N parallel callers compile DISTINCT sources. Each distinct source
    /// gets exactly one entry — no entry is dropped or double-inserted
    /// under race.
    func testCompileCache_distinctSources_allCached_underConcurrency() async throws {
        let cache = PreCompiledScripts.CompileCache()
        let sources = (1...16).map { "return \($0) + 1" }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask {
                    try await cache.compile(source: source)
                }
            }
            try await group.waitForAll()
        }

        let count = await cache.cacheCount
        XCTAssertEqual(
            count, sources.count,
            "16 distinct parallel compiles should produce 16 distinct cache entries"
        )
        for source in sources {
            let contains = await cache.contains(source: source)
            XCTAssertTrue(contains, "source '\(source)' should be cached after concurrent insert")
        }
    }

    /// Execute the same source N times concurrently. Every result MUST
    /// carry the arithmetic answer — proves no state leaks across
    /// concurrent `execute` calls, which would surface as wrong ints.
    func testCompileCache_execute_concurrentSameSource_returnsCorrectResult() async throws {
        let cache = PreCompiledScripts.CompileCache()
        let source = "return 6 * 7"

        let results: [Int32] = try await withThrowingTaskGroup(of: Int32.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    let result = try await cache.execute(source: source)
                    return result.int32Value
                }
            }
            var collected: [Int32] = []
            for try await value in group { collected.append(value) }
            return collected
        }

        XCTAssertEqual(results.count, 16)
        XCTAssertTrue(
            results.allSatisfy { $0 == 42 },
            "every concurrent execute should return 42; got \(results)"
        )
        let count = await cache.cacheCount
        XCTAssertEqual(count, 1, "execute(source:) still caches exactly once under concurrency")
    }
}
