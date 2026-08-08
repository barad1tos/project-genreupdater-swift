import Core
import Foundation
import Services

private let log = AppLogger.make(category: "browse-commands")

/// Revalidating dispatch for browse-originated preview requests
/// (ADR 0011/0014): every command re-checks the CURRENT projection
/// before submission, so a stale click can never act on vanished
/// truth. Closure-injected like FixPlanCommands so pins run headless;
/// PR C wires the host closures.
struct BrowseCommands: Sendable {
    let currentBrowse: @Sendable () async -> BrowseProjection
    let submitAlbumPreview: @Sendable (FixPlanAlbumTarget) async throws -> RunSubmissionResult
    /// Rejections republish the projection that explains the current
    /// state instead of silently no-opping (ADR 0011).
    let republishBrowse: @Sendable () async -> Void

    func performAlbumPreview(target: BrowseCommandTarget) async -> CommandResultStatus {
        let projection = await currentBrowse()
        guard target.projectionRevision == projection.revision else {
            log.info("Browse preview rejected: stale projection revision")
            await republishBrowse()
            return .rejectedStale
        }
        guard let scope = projection.scope, scope.snapshotID == target.scopeSnapshotID else {
            log.info("Browse preview rejected: scope snapshot changed")
            await republishBrowse()
            return .rejectedStale
        }
        guard let album = album(target.albumID, in: projection), album.action.isEnabled else {
            log.info("Browse preview rejected: album unavailable or out of scope")
            await republishBrowse()
            return .rejectedInvalid
        }
        return await submit(FixPlanAlbumTarget(artist: album.artistName, album: album.title))
    }

    private func album(_ albumID: String, in projection: BrowseProjection) -> BrowseAlbumNode? {
        for artist in projection.artists {
            if let album = artist.albums.first(where: { $0.id == albumID }) {
                return album
            }
        }
        return nil
    }

    private func submit(_ target: FixPlanAlbumTarget) async -> CommandResultStatus {
        do {
            let result = try await submitAlbumPreview(target)
            let mapped = status(for: result)
            // Only the mapped category is public: the raw result carries
            // the lifecycle snapshot with user library metadata.
            log.info("Album preview submission outcome: \(mapped.rawValue, privacy: .public)")
            return mapped
        } catch {
            log.error("Album preview submission failed: \(error.localizedDescription, privacy: .private)")
            return .temporaryUnavailable
        }
    }

    private func status(for result: RunSubmissionResult) -> CommandResultStatus {
        switch result {
        case .completed:
            .accepted
        case .queued:
            .queued
        case .alreadyCovered:
            .alreadyCovered
        case .completedNoOp, .cancelled:
            .noOp
        case .recoverable, .recoveryRequired:
            // Unreachable for preview intent today; mirrors the sibling
            // dispatchers' vocabulary so the mapping stays uniform.
            .blockedByRecovery
        case .failed:
            .requiresAttention
        }
    }
}

extension BrowseCommands {
    /// Casual copy for every non-success preview outcome — a mute
    /// failure is a silent catch (ADR 0015).
    static func noticeCopy(for status: CommandResultStatus) -> String {
        switch status {
        case .rejectedStale:
            "Browse just refreshed — try the album again."
        case .rejectedInvalid:
            "This album is not available for preview right now."
        case .blockedByRecovery:
            "The previous run needs recovery before new previews."
        case .blockedByPermission:
            "Music access is required before previewing."
        case .requiresAttention:
            "The preview run failed. Check Activity for details."
        case .temporaryUnavailable:
            "Preview services are unavailable. Try again shortly."
        case .noOp, .navigated, .accepted, .queued, .alreadyCovered:
            // Covers cancelled runs too — "finished without changes" is
            // true for both, "nothing to fix" would not be.
            "The preview finished without changes to review."
        }
    }
}
