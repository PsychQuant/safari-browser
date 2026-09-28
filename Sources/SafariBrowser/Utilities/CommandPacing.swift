import ArgumentParser
import Foundation

/// Opt-in spacing for a single command, not a cross-process rate limiter.
struct CommandPacing {
    @TaskLocal static var currentEnabled: Bool? = nil
    static let key = "SAFARI_BROWSER_PACING"

    private let enabled: (distribution: TruncatedCauchy, range: WaitCommand.JitterNanosecondRange)?
    var isEnabled: Bool { enabled != nil }

    struct Prepared {
        let nanoseconds: UInt64
        let warning: String?
    }

    struct InterruptedAfterExecution: LocalizedError {
        var errorDescription: String? {
            "Command pacing interrupted after execution; earlier effects are not undone."
        }
    }

    init(environment: [String: String]) throws {
        let mode = environment[Self.key] ?? "off"
        guard mode != "off", !mode.isEmpty else { enabled = nil; return }
        guard mode == "cauchy" else {
            throw ValidationError("SAFARI_BROWSER_PACING must be cauchy or off.")
        }
        func number(_ suffix: String, default fallback: Double?) throws -> Double? {
            let key = Self.key + "_" + suffix + "_MS"
            guard let text = environment[key] else { return fallback }
            guard let value = Double(text), value.isFinite else {
                throw ValidationError("\(key) must be a finite number of milliseconds.")
            }
            return value
        }
        let minimum = try number("MIN", default: TruncatedCauchy.defaultMin)!
        let maximum = try number("MAX", default: TruncatedCauchy.defaultMax)!
        let median = try number("MEDIAN", default: TruncatedCauchy.defaultMedian)!
        let scale = try number("SCALE", default: nil)
        guard maximum <= WaitCommand.longJitterMaxMilliseconds else {
            throw ValidationError("SAFARI_BROWSER_PACING_MAX_MS must not exceed 3600000 milliseconds.")
        }
        do {
            let distribution = try TruncatedCauchy(min: minimum, max: maximum, median: median, scale: scale)
            let range = try WaitCommand.JitterNanosecondRange(min: minimum, max: maximum)
            enabled = (distribution, range)
        } catch {
            throw ValidationError("Invalid SAFARI_BROWSER_PACING settings: \(Self.environmentTerms(String(describing: error)))")
        }
    }

    /// Reuse the sampler's guidance, but name the knobs available here rather
    /// than suggesting wait-only flags on unrelated commands.
    private static func environmentTerms(_ message: String) -> String {
        ["min", "max", "median", "scale"].reduce(message) { text, name in
            text.replacingOccurrences(of: "--" + name, with: key + "_" + name.uppercased() + "_MS")
        }
    }

    private static func draw(_ distribution: TruncatedCauchy) throws -> Double {
        var generator = SystemRandomNumberGenerator()
        return try distribution.sample(using: &generator)
    }

    func prepare(draw: (TruncatedCauchy) throws -> Double = Self.draw) throws -> Prepared? {
        guard let enabled else { return nil }
        return try Prepared(nanoseconds: enabled.range.nanoseconds(for: draw(enabled.distribution)),
                            warning: enabled.distribution.nearlyFixedWarning.map(Self.environmentTerms))
    }

    func perform<Value>(
        draw: (TruncatedCauchy) throws -> Double = Self.draw,
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        warning: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
        operation: () async throws -> Value
    ) async throws -> Value {
        guard let prepared = try prepare(draw: draw) else { return try await operation() }
        try Task.checkCancellation()
        if let text = prepared.warning { warning(text) }
        let outcome: Result<Value, Error>
        do { outcome = .success(try await operation()) }
        catch {
            if error is CancellationError || Task.isCancelled { throw error }
            outcome = .failure(error)
        }
        do {
            try Task.checkCancellation()
            try await sleep(prepared.nanoseconds)
        } catch {
            if case .failure(let original) = outcome { throw original }
            throw InterruptedAfterExecution()
        }
        return try outcome.get()
    }
}
