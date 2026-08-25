import Foundation

public actor ProjectionStore {
    private var currentActivityProjection: ActivityProjection
    private var latestIssuedActivityProjectionInputGeneration: UInt64
    private var latestAppliedActivityProjectionInputGeneration: UInt64
    private var activityContinuations: [UUID: AsyncStream<ActivityProjection>.Continuation]

    private var currentReportsProjection: ReportsProjection
    private var latestIssuedReportsProjectionInputGeneration: UInt64
    private var latestAppliedReportsProjectionInputGeneration: UInt64
    private var reportsContinuations: [UUID: AsyncStream<ReportsProjection>.Continuation]

    private var currentFixPlanProjection: FixPlanProjection
    private var issuedFixPlanGeneration: UInt64
    private var appliedFixPlanGeneration: UInt64
    private var fixPlanContinuations: [UUID: AsyncStream<FixPlanProjection>.Continuation]

    private var currentSettingsProjection: SettingsProjection
    private var issuedSettingsGeneration: UInt64
    private var appliedSettingsGeneration: UInt64
    private var settingsContinuations: [UUID: AsyncStream<SettingsProjection>.Continuation]
    private var currentChromeProjection: ChromeProjection
    private var issuedChromeGeneration: UInt64
    private var appliedChromeGeneration: UInt64
    private var chromeContinuations: [UUID: AsyncStream<ChromeProjection>.Continuation]

    private var currentBrowseProjection: BrowseProjection
    private var issuedBrowseGeneration: UInt64
    private var appliedBrowseGeneration: UInt64
    private var browseContinuations: [UUID: AsyncStream<BrowseProjection>.Continuation]

    private var currentArtistCatalog: ArtistCatalogProjection
    private var issuedArtistCatalogGeneration: UInt64
    private var appliedArtistCatalogGeneration: UInt64
    private var artistCatalogContinuations: [UUID: AsyncStream<ArtistCatalogProjection>.Continuation]

    public init() {
        currentActivityProjection = .empty()
        latestIssuedActivityProjectionInputGeneration = 0
        latestAppliedActivityProjectionInputGeneration = 0
        activityContinuations = [:]

        currentReportsProjection = .empty()
        latestIssuedReportsProjectionInputGeneration = 0
        latestAppliedReportsProjectionInputGeneration = 0
        reportsContinuations = [:]

        currentFixPlanProjection = .empty()
        issuedFixPlanGeneration = 0
        appliedFixPlanGeneration = 0
        fixPlanContinuations = [:]

        currentSettingsProjection = .empty()
        issuedSettingsGeneration = 0
        appliedSettingsGeneration = 0
        settingsContinuations = [:]
        currentChromeProjection = .empty()
        issuedChromeGeneration = 0
        appliedChromeGeneration = 0
        chromeContinuations = [:]

        currentBrowseProjection = .empty()
        issuedBrowseGeneration = 0
        appliedBrowseGeneration = 0
        browseContinuations = [:]

        currentArtistCatalog = .empty()
        issuedArtistCatalogGeneration = 0
        appliedArtistCatalogGeneration = 0
        artistCatalogContinuations = [:]
    }

    public func activityProjection() -> ActivityProjection {
        currentActivityProjection
    }

    public func activityUpdates() -> AsyncStream<ActivityProjection> {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream<ActivityProjection>.makeStream(bufferingPolicy: .bufferingNewest(1))

        registerActivityContinuation(continuation, id: subscriptionID)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeActivityContinuation(id: subscriptionID)
            }
        }

        return stream
    }

    public func nextActivityProjectionInputGeneration() -> UInt64 {
        latestIssuedActivityProjectionInputGeneration += 1
        return latestIssuedActivityProjectionInputGeneration
    }

    /// Replaces the activity projection when the optional input generation is newer.
    ///
    /// Returns the stored projection. If the input generation is stale, or if the
    /// new projection is content-identical to the current one, this returns the
    /// existing projection without advancing its revision or notifying subscribers.
    @discardableResult
    public func replaceActivityProjection(
        _ projection: ActivityProjection,
        inputGeneration: UInt64? = nil
    ) -> ActivityProjection {
        if let inputGeneration {
            guard inputGeneration > latestAppliedActivityProjectionInputGeneration else {
                return currentActivityProjection
            }
            latestIssuedActivityProjectionInputGeneration = max(
                latestIssuedActivityProjectionInputGeneration,
                inputGeneration
            )
            latestAppliedActivityProjectionInputGeneration = inputGeneration
        }

        let comparableProjection = projection.withRevision(currentActivityProjection.revision)
        guard comparableProjection != currentActivityProjection else {
            return currentActivityProjection
        }

        let storedProjection = projection.withRevision(currentActivityProjection.revision.advanced())

        currentActivityProjection = storedProjection
        broadcastActivityProjection(storedProjection)

        return storedProjection
    }

    private func registerActivityContinuation(
        _ continuation: AsyncStream<ActivityProjection>.Continuation,
        id: UUID
    ) {
        if case .terminated = continuation.yield(currentActivityProjection) {
            return
        }
        activityContinuations[id] = continuation
    }

    private func broadcastActivityProjection(_ projection: ActivityProjection) {
        var terminatedContinuationIDs: [UUID] = []

        for (id, continuation) in activityContinuations {
            switch continuation.yield(projection) {
            case .enqueued, .dropped:
                break
            case .terminated:
                terminatedContinuationIDs.append(id)
            @unknown default:
                break
            }
        }

        for id in terminatedContinuationIDs {
            activityContinuations[id] = nil
        }
    }

    private func removeActivityContinuation(id: UUID) {
        activityContinuations[id] = nil
    }

    public func reportsProjection() -> ReportsProjection {
        currentReportsProjection
    }

    public func reportsUpdates() -> AsyncStream<ReportsProjection> {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream<ReportsProjection>.makeStream(bufferingPolicy: .bufferingNewest(1))

        registerReportsContinuation(continuation, id: subscriptionID)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeReportsContinuation(id: subscriptionID)
            }
        }

        return stream
    }

    public func nextReportsProjectionInputGeneration() -> UInt64 {
        latestIssuedReportsProjectionInputGeneration += 1
        return latestIssuedReportsProjectionInputGeneration
    }

    /// Replaces the reports projection when the optional input generation is newer.
    ///
    /// Returns the stored projection. If the input generation is stale, or if the
    /// new projection is content-identical to the current one, this returns the
    /// existing projection without advancing its revision or notifying subscribers.
    @discardableResult
    public func replaceReportsProjection(
        _ projection: ReportsProjection,
        inputGeneration: UInt64? = nil
    ) -> ReportsProjection {
        if let inputGeneration {
            guard inputGeneration > latestAppliedReportsProjectionInputGeneration else {
                return currentReportsProjection
            }
            latestIssuedReportsProjectionInputGeneration = max(
                latestIssuedReportsProjectionInputGeneration,
                inputGeneration
            )
            latestAppliedReportsProjectionInputGeneration = inputGeneration
        }

        let comparableProjection = projection.withRevision(currentReportsProjection.revision)
        guard comparableProjection != currentReportsProjection else {
            return currentReportsProjection
        }

        let storedProjection = projection.withRevision(currentReportsProjection.revision.advanced())

        currentReportsProjection = storedProjection
        broadcastReportsProjection(storedProjection)

        return storedProjection
    }

    private func registerReportsContinuation(
        _ continuation: AsyncStream<ReportsProjection>.Continuation,
        id: UUID
    ) {
        if case .terminated = continuation.yield(currentReportsProjection) {
            return
        }
        reportsContinuations[id] = continuation
    }

    private func broadcastReportsProjection(_ projection: ReportsProjection) {
        var terminatedContinuationIDs: [UUID] = []

        for (id, continuation) in reportsContinuations {
            switch continuation.yield(projection) {
            case .enqueued, .dropped:
                break
            case .terminated:
                terminatedContinuationIDs.append(id)
            @unknown default:
                break
            }
        }

        for id in terminatedContinuationIDs {
            reportsContinuations[id] = nil
        }
    }

    private func removeReportsContinuation(id: UUID) {
        reportsContinuations[id] = nil
    }

    public func fixPlanProjection() -> FixPlanProjection {
        currentFixPlanProjection
    }

    public func fixPlanUpdates() -> AsyncStream<FixPlanProjection> {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream<FixPlanProjection>.makeStream(bufferingPolicy: .bufferingNewest(1))

        registerFixPlanContinuation(continuation, id: subscriptionID)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeFixPlanContinuation(id: subscriptionID)
            }
        }

        return stream
    }

    public func nextFixPlanInputGeneration() -> UInt64 {
        issuedFixPlanGeneration += 1
        return issuedFixPlanGeneration
    }

    /// Replaces the fix-plan projection when the optional input generation is newer.
    @discardableResult
    public func replaceFixPlanProjection(
        _ projection: FixPlanProjection,
        inputGeneration: UInt64? = nil
    ) -> FixPlanProjection {
        if let inputGeneration {
            guard inputGeneration > appliedFixPlanGeneration else {
                return currentFixPlanProjection
            }
            issuedFixPlanGeneration = max(issuedFixPlanGeneration, inputGeneration)
            appliedFixPlanGeneration = inputGeneration
        }

        let comparableProjection = projection.withRevision(currentFixPlanProjection.revision)
        guard comparableProjection != currentFixPlanProjection else {
            return currentFixPlanProjection
        }

        let storedProjection = projection.withRevision(currentFixPlanProjection.revision.advanced())

        currentFixPlanProjection = storedProjection
        broadcastFixPlanProjection(storedProjection)

        return storedProjection
    }

    private func registerFixPlanContinuation(
        _ continuation: AsyncStream<FixPlanProjection>.Continuation,
        id: UUID
    ) {
        if case .terminated = continuation.yield(currentFixPlanProjection) {
            return
        }
        fixPlanContinuations[id] = continuation
    }

    private func broadcastFixPlanProjection(_ projection: FixPlanProjection) {
        var terminatedContinuationIDs: [UUID] = []

        for (id, continuation) in fixPlanContinuations {
            switch continuation.yield(projection) {
            case .enqueued, .dropped:
                break
            case .terminated:
                terminatedContinuationIDs.append(id)
            @unknown default:
                break
            }
        }

        for id in terminatedContinuationIDs {
            fixPlanContinuations[id] = nil
        }
    }

    private func removeFixPlanContinuation(id: UUID) {
        fixPlanContinuations[id] = nil
    }

    public func currentSettings() -> SettingsProjection {
        currentSettingsProjection
    }

    public func settingsUpdates() -> AsyncStream<SettingsProjection> {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream<SettingsProjection>.makeStream(bufferingPolicy: .bufferingNewest(1))

        registerSettingsContinuation(continuation, id: subscriptionID)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeSettingsContinuation(id: subscriptionID)
            }
        }

        return stream
    }

    public func nextSettingsInputGeneration() -> UInt64 {
        issuedSettingsGeneration += 1
        return issuedSettingsGeneration
    }

    /// Replaces the settings projection when the optional input generation is newer.
    @discardableResult
    public func replaceSettingsProjection(
        _ projection: SettingsProjection,
        inputGeneration: UInt64? = nil
    ) -> SettingsProjection {
        if let inputGeneration {
            guard inputGeneration > appliedSettingsGeneration else {
                return currentSettingsProjection
            }
            issuedSettingsGeneration = max(issuedSettingsGeneration, inputGeneration)
            appliedSettingsGeneration = inputGeneration
        }

        let comparableProjection = projection.withRevision(currentSettingsProjection.revision)
        guard comparableProjection != currentSettingsProjection else {
            return currentSettingsProjection
        }

        let storedProjection = projection.withRevision(currentSettingsProjection.revision.advanced())

        currentSettingsProjection = storedProjection
        broadcastSettingsProjection(storedProjection)

        return storedProjection
    }

    private func registerSettingsContinuation(
        _ continuation: AsyncStream<SettingsProjection>.Continuation,
        id: UUID
    ) {
        if case .terminated = continuation.yield(currentSettingsProjection) {
            return
        }
        settingsContinuations[id] = continuation
    }

    private func broadcastSettingsProjection(_ projection: SettingsProjection) {
        var terminatedContinuationIDs: [UUID] = []

        for (id, continuation) in settingsContinuations {
            switch continuation.yield(projection) {
            case .enqueued, .dropped:
                break
            case .terminated:
                terminatedContinuationIDs.append(id)
            @unknown default:
                break
            }
        }

        for id in terminatedContinuationIDs {
            settingsContinuations[id] = nil
        }
    }

    private func removeSettingsContinuation(id: UUID) {
        settingsContinuations[id] = nil
    }

    public func currentChrome() -> ChromeProjection {
        currentChromeProjection
    }

    public func chromeUpdates() -> AsyncStream<ChromeProjection> {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream<ChromeProjection>.makeStream(bufferingPolicy: .bufferingNewest(1))

        registerChromeContinuation(continuation, id: subscriptionID)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeChromeContinuation(id: subscriptionID)
            }
        }

        return stream
    }

    public func nextChromeInputGeneration() -> UInt64 {
        issuedChromeGeneration += 1
        return issuedChromeGeneration
    }

    /// Replaces the chrome projection when the optional input generation is newer.
    @discardableResult
    public func replaceChromeProjection(
        _ projection: ChromeProjection,
        inputGeneration: UInt64? = nil
    ) -> ChromeProjection {
        if let inputGeneration {
            guard inputGeneration > appliedChromeGeneration else {
                return currentChromeProjection
            }
            issuedChromeGeneration = max(issuedChromeGeneration, inputGeneration)
            appliedChromeGeneration = inputGeneration
        }

        let comparableProjection = projection.withRevision(currentChromeProjection.revision)
        guard comparableProjection != currentChromeProjection else {
            return currentChromeProjection
        }

        let storedProjection = projection.withRevision(currentChromeProjection.revision.advanced())

        currentChromeProjection = storedProjection
        broadcastChromeProjection(storedProjection)

        return storedProjection
    }

    private func registerChromeContinuation(
        _ continuation: AsyncStream<ChromeProjection>.Continuation,
        id: UUID
    ) {
        if case .terminated = continuation.yield(currentChromeProjection) {
            return
        }
        chromeContinuations[id] = continuation
    }

    private func broadcastChromeProjection(_ projection: ChromeProjection) {
        var terminatedContinuationIDs: [UUID] = []

        for (id, continuation) in chromeContinuations {
            switch continuation.yield(projection) {
            case .enqueued, .dropped:
                break
            case .terminated:
                terminatedContinuationIDs.append(id)
            @unknown default:
                break
            }
        }

        for id in terminatedContinuationIDs {
            chromeContinuations[id] = nil
        }
    }

    private func removeChromeContinuation(id: UUID) {
        chromeContinuations[id] = nil
    }

    public func currentBrowse() -> BrowseProjection {
        currentBrowseProjection
    }

    public func browseUpdates() -> AsyncStream<BrowseProjection> {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream<BrowseProjection>.makeStream(bufferingPolicy: .bufferingNewest(1))

        registerBrowseContinuation(continuation, id: subscriptionID)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeBrowseContinuation(id: subscriptionID)
            }
        }

        return stream
    }

    public func nextBrowseInputGeneration() -> UInt64 {
        issuedBrowseGeneration += 1
        return issuedBrowseGeneration
    }

    /// Replaces the browse projection when the optional input generation is newer.
    @discardableResult
    public func replaceBrowseProjection(
        _ projection: BrowseProjection,
        inputGeneration: UInt64? = nil
    ) -> BrowseProjection {
        if let inputGeneration {
            guard inputGeneration > appliedBrowseGeneration else {
                return currentBrowseProjection
            }
            issuedBrowseGeneration = max(issuedBrowseGeneration, inputGeneration)
            appliedBrowseGeneration = inputGeneration
        }

        let comparableProjection = projection.withRevision(currentBrowseProjection.revision)
        guard comparableProjection != currentBrowseProjection else {
            return currentBrowseProjection
        }

        let storedProjection = projection.withRevision(currentBrowseProjection.revision.advanced())

        currentBrowseProjection = storedProjection
        broadcastBrowseProjection(storedProjection)

        return storedProjection
    }

    private func registerBrowseContinuation(
        _ continuation: AsyncStream<BrowseProjection>.Continuation,
        id: UUID
    ) {
        if case .terminated = continuation.yield(currentBrowseProjection) {
            return
        }
        browseContinuations[id] = continuation
    }

    private func broadcastBrowseProjection(_ projection: BrowseProjection) {
        var terminatedContinuationIDs: [UUID] = []

        for (id, continuation) in browseContinuations {
            switch continuation.yield(projection) {
            case .enqueued, .dropped:
                break
            case .terminated:
                terminatedContinuationIDs.append(id)
            @unknown default:
                break
            }
        }

        for id in terminatedContinuationIDs {
            browseContinuations[id] = nil
        }
    }

    private func removeBrowseContinuation(id: UUID) {
        browseContinuations[id] = nil
    }

    /// Subscribes to the current catalog followed by revision advances.
    public func artistCatalogUpdates() -> AsyncStream<ArtistCatalogProjection> {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream<ArtistCatalogProjection>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )

        registerArtistCatalogContinuation(continuation, id: subscriptionID)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeArtistCatalogContinuation(id: subscriptionID)
            }
        }

        return stream
    }

    /// Claims ordering before a potentially suspending mirror read.
    public func claimArtistCatalogGeneration() -> UInt64 {
        issuedArtistCatalogGeneration += 1
        return issuedArtistCatalogGeneration
    }

    /// Publishes only newer catalog input and deduplicates identical content.
    @discardableResult
    public func replaceArtistCatalog(
        _ projection: ArtistCatalogProjection,
        inputGeneration: UInt64? = nil
    ) -> ArtistCatalogProjection {
        if let inputGeneration {
            guard inputGeneration >= issuedArtistCatalogGeneration,
                  inputGeneration > appliedArtistCatalogGeneration else {
                return currentArtistCatalog
            }
            issuedArtistCatalogGeneration = max(issuedArtistCatalogGeneration, inputGeneration)
            appliedArtistCatalogGeneration = inputGeneration
        }

        let comparableProjection = projection.withRevision(currentArtistCatalog.revision)
        guard comparableProjection != currentArtistCatalog else {
            return currentArtistCatalog
        }

        let storedProjection = projection.withRevision(currentArtistCatalog.revision.advanced())
        currentArtistCatalog = storedProjection
        broadcastArtistCatalog(storedProjection)
        return storedProjection
    }

    private func registerArtistCatalogContinuation(
        _ continuation: AsyncStream<ArtistCatalogProjection>.Continuation,
        id: UUID
    ) {
        if case .terminated = continuation.yield(currentArtistCatalog) {
            return
        }
        artistCatalogContinuations[id] = continuation
    }

    private func broadcastArtistCatalog(_ projection: ArtistCatalogProjection) {
        var terminatedContinuationIDs: [UUID] = []

        for (id, continuation) in artistCatalogContinuations {
            switch continuation.yield(projection) {
            case .enqueued, .dropped:
                break
            case .terminated:
                terminatedContinuationIDs.append(id)
            @unknown default:
                break
            }
        }

        for id in terminatedContinuationIDs {
            artistCatalogContinuations[id] = nil
        }
    }

    private func removeArtistCatalogContinuation(id: UUID) {
        artistCatalogContinuations[id] = nil
    }
}
