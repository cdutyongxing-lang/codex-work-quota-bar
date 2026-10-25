import Foundation

// Request tickets prevent a reply from an earlier host process from replacing
// the current host's status or quota after the main app has restarted.
struct RefreshState {
    struct Ticket: Equatable {
        let generation: Int
        let sequence: Int
    }

    private(set) var hostPID: Int32?
    private(set) var paused = false
    private var generation = 0
    private var sequence = 0
    private var active: Ticket?
    private var lastAttempt: Date?

    mutating func setHost(_ pid: Int32?) -> Bool {
        guard pid != hostPID else { return false }
        hostPID = pid
        invalidate()
        return true
    }

    mutating func setPaused(_ value: Bool) {
        guard paused != value else { return }
        paused = value
        if !value { lastAttempt = nil }
    }

    mutating func invalidate() {
        generation += 1
        active = nil
        lastAttempt = nil
    }

    mutating func begin(now: Date = Date(), manual: Bool = false) -> Ticket? {
        guard hostPID != nil, active == nil, manual || !paused else { return nil }
        if !manual, let last = lastAttempt, now.timeIntervalSince(last) < 60 { return nil }
        sequence += 1
        let ticket = Ticket(generation: generation, sequence: sequence)
        active = ticket
        lastAttempt = now
        return ticket
    }

    mutating func finish(_ ticket: Ticket) -> Bool {
        guard active == ticket else { return false }
        active = nil
        return true
    }
}
