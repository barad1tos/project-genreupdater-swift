public struct RecoveryItemActionDescriptor: Equatable, Sendable {
    private static let dismissalReasons = ["Duplicate", "Handled manually", "Not wanted"]
    private static let acknowledgementReasons = [
        "Track removed",
        "Identity changed",
        "Keep mirror unchanged",
    ]

    public let attentionLabel: String?
    public let tone: Tone
    public let sectionTitle: String
    public let accessibilityLabel: String
    public let reasons: [String]
    public let runID: String
    public let itemID: String

    public static func make(
        detail: RunReportDetailSnapshot,
        item: RunReportWorkItemRow
    ) -> Self? {
        guard detail.canDismissItems, item.canDismiss else { return nil }
        let acknowledgesLegacyNoOp = !item.isOpen
        let sectionTitle = if acknowledgesLegacyNoOp {
            "Keep the mirror unchanged"
        } else if item.isWriteUncertain {
            "Write status is uncertain — dismissing records your explicit decision"
        } else {
            "Dismiss item"
        }
        return Self(
            attentionLabel: item.attentionLabel,
            tone: acknowledgesLegacyNoOp || item.isWriteUncertain ? .warning : .info,
            sectionTitle: sectionTitle,
            accessibilityLabel: acknowledgesLegacyNoOp ? "Acknowledge recovery item" : "Dismiss work item",
            reasons: acknowledgesLegacyNoOp ? acknowledgementReasons : dismissalReasons,
            runID: detail.runID,
            itemID: item.id
        )
    }

    public func perform(reason: String, using actions: RecoveryDetailActions?) {
        guard reasons.contains(reason) else { return }
        actions?.dismissItem(runID, itemID, reason)
    }
}
