import Foundation

public struct FixPlanProduction: Equatable, Sendable {
    public let planID: FixPlanID?
    public let proposalCount: Int

    public init(planID: FixPlanID?, proposalCount: Int) {
        self.planID = planID
        self.proposalCount = proposalCount
    }

    public static let empty = Self(planID: nil, proposalCount: 0)

    public var producedPlan: Bool {
        planID != nil
    }
}
