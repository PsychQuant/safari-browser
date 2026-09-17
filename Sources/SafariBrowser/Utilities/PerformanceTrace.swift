import Foundation

enum PerformanceTrace {
    enum Phase: String, Codable, Sendable {
        case command, targetResolve = "target.resolve", nativeTarget = "target.native"
        case appleScriptDirect = "applescript.direct", appleScriptDaemon = "applescript.daemon", appleScriptInProcess = "applescript.inprocess"
        case processSpawn = "process.spawn", processWait = "process.wait", fileDialog = "file-dialog.run"
        case axWait = "ax.wait", axInspect = "ax.inspect"
        case daemonRequest = "daemon.request", daemonCompile = "daemon.compile", daemonExecute = "daemon.execute", daemonCacheHit = "daemon.cache_hit"
        case execRun = "exec.run"
    }
    enum Outcome: String, Codable, Sendable { case ok, error, unfinished }
    struct Span: Codable, Sendable {
        let id: Int
        let parentID: Int?
        let phase: Phase
        let durationNanoseconds: UInt64
        let outcome: Outcome
    }
    struct Summary: Codable, Sendable {
        let schemaVersion: Int
        let requestID: String
        let processID: Int?
        let status: Outcome
        let totalNanoseconds: UInt64
        let spans: [Span]
        let droppedSpans: UInt64
    }
    struct Context: Sendable { let collector: Collector; let parentID: Int? }
    @TaskLocal static var context: Context?
    @TaskLocal static var daemonErrorTimingSink: (@Sendable (Summary?) -> Void)?
    static var isActive: Bool { context?.collector.isRecording == true }
    static let prefix = "[safari-browser timing] "
    static func isEnabled(_ environment: [String: String]) -> Bool { environment["SAFARI_BROWSER_TRACE_TIMING"] == "1" }
    /// Only timings cross this boundary; no script, target, or AX node is retained.
    final class Collector: @unchecked Sendable {
        private struct Entry {
            let id: Int
            let parentID: Int?
            let phase: Phase
            let start: UInt64
            var duration: UInt64?
            var outcome: Outcome?
        }
        private let lock = NSLock()
        private let requestID = UUID().uuidString
        private let clock: @Sendable () -> UInt64
        private let started: UInt64
        private let limit: Int
        private var entries: [Entry] = []
        private var dropped: UInt64 = 0
        private var closed = false

        init(startNanoseconds: UInt64? = nil, maxSpans: Int = 64,
             clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
            self.clock = clock
            self.started = startNanoseconds ?? clock()
            self.limit = max(1, min(64, maxSpans))
        }

        var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return !closed }

        func begin(_ phase: Phase, parentID: Int? = nil, startNanoseconds: UInt64? = nil) -> Int? {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return nil }
            guard entries.count < limit,
                  parentID == nil || (parentID! > 0 && parentID! <= entries.count) else {
                addDropped(1); return nil
            }
            let id = entries.count + 1
            entries.append(Entry(id: id, parentID: parentID, phase: phase,
                                 start: startNanoseconds ?? clock()))
            return id
        }

        func end(_ id: Int, outcome: Outcome) {
            lock.lock(); defer { lock.unlock() }
            guard !closed, id > 0, id <= entries.count, entries[id - 1].duration == nil else { return }
            entries[id - 1].duration = Self.elapsed(from: entries[id - 1].start, to: clock())
            entries[id - 1].outcome = outcome
        }

        func finish(status: Outcome) -> Summary? {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return nil }
            closed = true
            let end = clock()
            let spans = entries.map { entry in
                Span(id: entry.id, parentID: entry.parentID, phase: entry.phase,
                     durationNanoseconds: entry.duration ?? Self.elapsed(from: entry.start, to: end),
                     outcome: entry.outcome ?? .unfinished)
            }
            return Summary(schemaVersion: 1, requestID: requestID,
                           processID: Int(ProcessInfo.processInfo.processIdentifier), status: status == .unfinished ? .error : status,
                           totalNanoseconds: Self.elapsed(from: started, to: end),
                           spans: spans, droppedSpans: dropped)
        }

        /// Optional peer metadata never changes execution success/failure.
        /// Decode into closed enums before retaining anything from the peer.
        func importRemote(_ object: Any, parentID: Int?) -> Bool {
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 65536,
                  let summary = try? JSONDecoder().decode(Summary.self, from: data),
                  let ordered = PerformanceTrace.validatedSpans(in: summary) else { return false }
            lock.lock(); defer { lock.unlock() }
            guard !closed, parentID == nil || (parentID! > 0 && parentID! <= entries.count) else { return false }
            var mapping: [Int: Int] = [:]
            for span in ordered {
                guard entries.count < limit else { addDropped(1); continue }
                let id = entries.count + 1
                let parent = span.parentID.flatMap { mapping[$0] } ?? parentID
                entries.append(Entry(id: id, parentID: parent, phase: span.phase, start: 0,
                                     duration: span.durationNanoseconds, outcome: span.outcome))
                mapping[span.id] = id
            }
            addDropped(summary.droppedSpans)
            return true
        }

        private func addDropped(_ count: UInt64) {
            let (sum, overflow) = dropped.addingReportingOverflow(count)
            dropped = overflow ? UInt64.max : sum
        }
        private static func elapsed(from start: UInt64, to end: UInt64) -> UInt64 {
            end >= start ? end - start : 0
        }
    }
    /// Share validation between imported metadata and separation of our own
    /// child trace from the command's ordinary error text.
    private static func validatedSpans(in summary: Summary) -> [Span]? {
        guard summary.schemaVersion == 1, summary.requestID.utf8.count == 36,
              UUID(uuidString: summary.requestID) != nil, summary.status != .unfinished,
              summary.processID == nil || (summary.processID! > 0 && summary.processID! <= Int(Int32.max)),
              summary.spans.count <= 64 else { return nil }
        let ordered = summary.spans.sorted { $0.id < $1.id }
        var ids = Set<Int>()
        for span in ordered {
            guard (1...64).contains(span.id), !ids.contains(span.id),
                  span.parentID == nil || ids.contains(span.parentID!) else { return nil }
            ids.insert(span.id)
        }
        return ordered
    }

    static func removingOwnSummaryLines(from text: String, processID: Int32) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            guard line.hasPrefix(prefix), line.utf8.count + 1 <= 65536,
                  let summary = try? JSONDecoder().decode(Summary.self, from: Data(line.dropFirst(prefix.count).utf8)),
                  summary.processID == Int(processID), validatedSpans(in: summary) != nil else { return true }
            return false
        }.joined(separator: "\n")
    }

    static func literalTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    static func consumeRemote(_ value: Any?) {
        guard let value, let context, context.collector.isRecording else { return }
        _ = context.collector.importRemote(value, parentID: context.parentID)
    }

    /// Server response metadata is per request, never inherited from its host.
    static func withDaemonTiming(enabled: Bool, operation: () async throws -> Data) async rethrows -> Data {
        guard enabled else { return try await $context.withValue(nil) { try await operation() } }
        let collector = Collector()
        let result: Data
        do {
            result = try await $context.withValue(Context(collector: collector, parentID: nil)) {
                try await spanAsync(.daemonRequest, operation: operation)
            }
        } catch {
            let summary = collector.finish(status: .error)
            daemonErrorTimingSink?(summary)
            throw error
        }
        guard var payload = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any],
              let summary = collector.finish(status: payload["status"] as? String == "error" ? .error : .ok),
              let data = try? JSONEncoder().encode(summary),
              let object = try? JSONSerialization.jsonObject(with: data) else { return result }
        payload["timing"] = object
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? result
    }

    static func line(_ summary: Summary) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(summary), data.count + prefix.utf8.count + 1 <= 65536 else { return nil }
        return Data(prefix.utf8) + data + Data([10])
    }

    static func emit(_ summary: Summary,
                     sink: (Data) throws -> Void = { try FileHandle.standardError.write(contentsOf: $0) }) {
        guard let data = line(summary) else { return }
        try? sink(data)
    }

    static func span<Value>(_ phase: Phase, operation: () throws -> Value) rethrows -> Value {
        guard let previous = context,
              let id = previous.collector.begin(phase, parentID: previous.parentID) else { return try operation() }
        return try $context.withValue(Context(collector: previous.collector, parentID: id)) {
            do {
                let value = try operation()
                previous.collector.end(id, outcome: .ok)
                return value
            } catch {
                previous.collector.end(id, outcome: .error)
                throw error
            }
        }
    }

    static func spanAsync<Value>(_ phase: Phase, operation: () async throws -> Value) async rethrows -> Value {
        guard let previous = context,
              let id = previous.collector.begin(phase, parentID: previous.parentID) else { return try await operation() }
        return try await $context.withValue(Context(collector: previous.collector, parentID: id)) {
            do {
                let value = try await operation()
                previous.collector.end(id, outcome: .ok)
                return value
            } catch {
                previous.collector.end(id, outcome: .error)
                throw error
            }
        }
    }
}
