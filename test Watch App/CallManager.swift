
import CallKit

class CallManager: NSObject {
    let controller = CXCallController()
    
    func startCall(handle: String) {
        let handle = CXHandle(type: .generic, value: handle)
        let startCallAction = CXStartCallAction(call: UUID(), handle: handle)
        let transaction = CXTransaction(action: startCallAction)
        
        controller.request(transaction) { error in
            if let error = error { print("Error starting call: \(error)") }
        }
    }
}
