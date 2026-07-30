import Foundation

struct ScriptFetchCall: Sendable {
    let trackIDs: [String]
    let batchSize: Int
    let timeout: Duration?
}
