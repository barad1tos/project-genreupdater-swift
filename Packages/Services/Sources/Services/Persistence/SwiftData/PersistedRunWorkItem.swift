import Foundation
import SwiftData

@Model
public final class PersistedRunWorkItem {
    @Attribute(.unique) public var key: String
    public var runID: UUID
    public var itemID: UUID
    public var position: Int
    public var itemData: Data

    public init(runID: UUID, itemID: UUID, position: Int, itemData: Data) {
        key = Self.key(runID: runID, itemID: itemID)
        self.runID = runID
        self.itemID = itemID
        self.position = position
        self.itemData = itemData
    }

    static func key(runID: UUID, itemID: UUID) -> String {
        "\(runID.uuidString):\(itemID.uuidString)"
    }
}
