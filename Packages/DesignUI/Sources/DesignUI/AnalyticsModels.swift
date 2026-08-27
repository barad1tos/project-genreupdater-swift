import Foundation

public enum DesignAnalyticsWindow: String, CaseIterable, Identifiable, Equatable, Sendable {
    case currentSession
    case last24Hours
    case last7Days

    public var id: String {
        rawValue
    }

    public var label: String {
        switch self {
        case .currentSession: "Session"
        case .last24Hours: "24 hours"
        case .last7Days: "7 days"
        }
    }
}

public enum DesignAnalyticsState: Equatable, Sendable {
    case disabled
    case empty
    case unavailable
    case populated
}

public enum DesignAnalyticsOutcome: String, Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
    case degraded

    var tone: Tone {
        switch self {
        case .succeeded: .success
        case .failed: .error
        case .cancelled: .warning
        case .degraded: .warning
        }
    }
}

public struct DesignAnalyticsSummary: Equatable, Sendable {
    public let calls: Int
    public let succeeded: Int
    public let failed: Int
    public let cancelled: Int
    public let degraded: Int
    public let successRate: Double
    public let totalDuration: String
    public let averageDuration: String
    public let p95Duration: String

    public init(
        succeeded: Int,
        failed: Int,
        cancelled: Int,
        degraded: Int,
        totalDuration: String,
        averageDuration: String,
        p95Duration: String
    ) {
        calls = succeeded + failed + cancelled + degraded
        self.succeeded = succeeded
        self.failed = failed
        self.cancelled = cancelled
        self.degraded = degraded
        successRate = calls == 0 ? 0 : Double(succeeded) / Double(calls)
        self.totalDuration = totalDuration
        self.averageDuration = averageDuration
        self.p95Duration = p95Duration
    }

    public static let empty = Self(
        succeeded: 0,
        failed: 0,
        cancelled: 0,
        degraded: 0,
        totalDuration: "0 ms",
        averageDuration: "0 ms",
        p95Duration: "0 ms"
    )
}

public struct DesignAnalyticsBucket: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let count: Int
    public let tone: Tone

    public init(id: String, label: String, count: Int, tone: Tone) {
        self.id = id
        self.label = label
        self.count = count
        self.tone = tone
    }
}

public struct DesignAnalyticsOperation: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let category: String
    public let calls: Int
    public let successRate: String
    public let totalDuration: String
    public let averageDuration: String
    public let p95Duration: String

    public init(
        id: String,
        name: String,
        category: String,
        calls: Int,
        successRate: String,
        durations: (total: String, average: String, p95: String)
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.calls = calls
        self.successRate = successRate
        totalDuration = durations.total
        averageDuration = durations.average
        p95Duration = durations.p95
    }
}

public struct DesignAnalyticsEvent: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let operation: String
    public let startedAt: String
    public let duration: String
    public let outcome: DesignAnalyticsOutcome

    public init(
        id: UUID,
        operation: String,
        startedAt: String,
        duration: String,
        outcome: DesignAnalyticsOutcome
    ) {
        self.id = id
        self.operation = operation
        self.startedAt = startedAt
        self.duration = duration
        self.outcome = outcome
    }
}

public struct DesignAnalyticsSnapshot: Equatable, Sendable {
    public let state: DesignAnalyticsState
    public let selectedWindow: DesignAnalyticsWindow
    public let availableWindows: [DesignAnalyticsWindow]
    public let summary: DesignAnalyticsSummary
    public let distribution: [DesignAnalyticsBucket]
    public let operations: [DesignAnalyticsOperation]
    public let recentEvents: [DesignAnalyticsEvent]

    public init(
        state: DesignAnalyticsState,
        selectedWindow: DesignAnalyticsWindow,
        availableWindows: [DesignAnalyticsWindow] = DesignAnalyticsWindow.allCases,
        summary: DesignAnalyticsSummary,
        distribution: [DesignAnalyticsBucket],
        operations: [DesignAnalyticsOperation],
        recentEvents: [DesignAnalyticsEvent]
    ) {
        self.state = state
        self.selectedWindow = selectedWindow
        self.availableWindows = availableWindows
        self.summary = summary
        self.distribution = distribution
        self.operations = operations
        self.recentEvents = recentEvents
    }

    public static let empty = Self(
        state: .empty,
        selectedWindow: .currentSession,
        summary: .empty,
        distribution: [],
        operations: [],
        recentEvents: []
    )
}

enum AnalyticsSection: Equatable {
    case header
    case summary
    case distribution
    case operations
    case recentEvents
    case state

    static func order(for state: DesignAnalyticsState) -> [Self] {
        switch state {
        case .populated:
            [.header, .summary, .distribution, .operations, .recentEvents]
        case .disabled, .empty, .unavailable:
            [.header, .state]
        }
    }
}

enum AnalyticsStateAction: Equatable {
    case openSettings
    case retry

    static func forState(_ state: DesignAnalyticsState) -> Self? {
        switch state {
        case .disabled: .openSettings
        case .unavailable: .retry
        case .empty, .populated: nil
        }
    }
}
