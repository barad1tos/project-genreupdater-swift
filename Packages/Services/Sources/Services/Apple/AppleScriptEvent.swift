import Carbon.OpenScripting
import Foundation

extension AppleScriptBridge {
    static func makeRunAppleEvent(arguments: [String]) -> NSAppleEventDescriptor? {
        guard !arguments.isEmpty else { return nil }

        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )

        let argList = NSAppleEventDescriptor.list()
        for (index, arg) in arguments.enumerated() {
            argList.insert(NSAppleEventDescriptor(string: arg), at: index + 1)
        }
        event.setDescriptor(argList, forKeyword: keyDirectObject)

        return event
    }
}
