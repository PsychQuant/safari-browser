import Foundation

/// #197: typed, payload-free diagnostic candidates. The budget is owned by
/// one Instance actor; request logs do not use this policy.
struct DaemonDiagnosticBudget {
    enum Kind: String, CaseIterable, Sendable {
        case acceptError = "accept_error"
        case acceptWaitError = "accept_wait_error"
        case acceptRecovered = "accept_recovered"
        case setupFailed = "connection_setup_failed"
        case setupRecovered = "connection_setup_recovered"
        case requestTooLong = "request_too_long"
        case requestReadFailed = "request_read_failed"
    }
    enum Disposition: String, Sendable { case retry, backoff, stop, closed, recovered }
    struct Event: Sendable, Equatable {
        let kind: Kind
        let errno: Int32
        let disposition: Disposition
        var count: Int = 1
        var isTerminal: Bool { disposition == .stop }
        var isRecovery: Bool { disposition == .recovered }
    }
    struct Suppression: Sendable {
        var total = 0
        var byEvent: [Kind: Int] = [:]
        var byDisposition: [Disposition: Int] = [:]
        var first: Event?
        var lastRecovery: Event?
        var lastTerminal: Event?

        mutating func append(_ event: Event) {
            if total < Int.max { total += 1 }
            let count = byEvent[event.kind, default: 0]
            byEvent[event.kind] = count < Int.max ? count + 1 : Int.max
            let dispositionCount = byDisposition[event.disposition, default: 0]
            byDisposition[event.disposition] = dispositionCount < Int.max ? dispositionCount + 1 : Int.max
            if first == nil { first = event }
            if event.isRecovery { lastRecovery = event }
            if event.isTerminal { lastTerminal = event }
        }
    }
    struct Emission: Sendable {
        let event: Event?
        let suppressed: Suppression?
    }
    // One token is 500 ms of credit: integer Duration arithmetic avoids
    // rounding a fractional token into an early admission at the boundary.
    private static let unit: Duration = .milliseconds(500)
    private static let capacity: Duration = .seconds(4)
    private var credit = Self.capacity
    private var lastRefill: ContinuousClock.Instant
    private var pending = Suppression()

    init(now: ContinuousClock.Instant) { lastRefill = now }
    var hasPending: Bool { pending.total > 0 }

    mutating func record(_ event: Event, at now: ContinuousClock.Instant) -> Emission? {
        refill(at: now)
        guard consume(terminal: event.isTerminal || pending.lastTerminal != nil) else {
            pending.append(event)
            return nil
        }
        let summary = hasPending ? pending : nil
        pending = Suppression()
        return Emission(event: event, suppressed: summary)
    }

    mutating func drain(at now: ContinuousClock.Instant) -> Emission? {
        refill(at: now)
        guard hasPending, consume(terminal: pending.lastTerminal != nil) else { return nil }
        let summary = pending
        pending = Suppression()
        return Emission(event: nil, suppressed: summary)
    }

    mutating func discardPending() { pending = Suppression() }

    private mutating func refill(at now: ContinuousClock.Instant) {
        guard now > lastRefill else { return }
        let elapsed = lastRefill.duration(to: now)
        lastRefill = now
        // Cap before addition, including arbitrarily large clock advances.
        if elapsed >= Self.capacity - credit { credit = Self.capacity }
        else { credit += elapsed }
    }

    private mutating func consume(terminal: Bool) -> Bool {
        let required = terminal ? Self.unit : Self.unit + Self.unit
        guard credit >= required else { return false }
        credit -= Self.unit
        return true
    }
}
