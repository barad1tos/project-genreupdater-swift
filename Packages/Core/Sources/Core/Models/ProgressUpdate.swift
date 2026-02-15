// ProgressUpdate.swift — Async progress reporting model
// Phase 2A: Persistence Layer

import Foundation

/// Progress update for async operations reported to UI.
///
/// Used by processing pipelines to report status through
/// AsyncStream or AsyncChannel to SwiftUI views.
public struct ProgressUpdate: Sendable, Equatable {
    public let phase: ProcessingPhase
    public let current: Int
    public let total: Int
    public let message: String?

    public init(
        phase: ProcessingPhase,
        current: Int,
        total: Int,
        message: String? = nil
    ) {
        self.phase = phase
        self.current = current
        self.total = total
        self.message = message
    }

    /// Completion fraction (0.0–1.0). Returns 0 when total is 0.
    public var fractionComplete: Double {
        total > 0 ? Double(current) / Double(total) : 0
    }

    /// Whether the operation has completed.
    public var isComplete: Bool {
        phase == .complete
    }
}

// MARK: - Processing Phase

/// Stages of a track processing pipeline.
public enum ProcessingPhase: String, Sendable, Codable, CaseIterable {
    case fetching
    case analyzing
    case updating
    case complete
}
