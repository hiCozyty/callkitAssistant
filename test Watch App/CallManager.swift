import Foundation
import CallKit

class CallManager: NSObject, CXProviderDelegate {
    let controller = CXCallController()
    private let provider: CXProvider
    var currentCallUUID: UUID?

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.supportedHandleTypes = [.generic]
        
        self.provider = CXProvider(configuration: configuration)
        super.init()
        self.provider.setDelegate(self, queue: nil)
    }

    func startCall(handle: String) {
        let uuid = UUID()
        self.currentCallUUID = uuid
        let startCallAction = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: handle))
        let transaction = CXTransaction(action: startCallAction)
        
        controller.request(transaction) { error in
            if let error = error { print("CallKit Request Error: \(error)") }
        }
    }

    func providerDidReset(_ provider: CXProvider) {
        stopAudio()
        currentCallUUID = nil
    }
    
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
        print("CallKit: Call Started")
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        stopAudio()
        action.fulfill()
        print("CallKit: Call Ended")
    }

    private func stopAudio() {
        NotificationCenter.default.post(name: NSNotification.Name("EndAudioInternal"), object: nil)
    }
    
    func endCall() {
        guard let uuid = currentCallUUID else { return }
        let endCallAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endCallAction)
        
        controller.request(transaction) { [weak self] error in
            if let error = error {
                print("Error ending call: \(error)")
            } else {
                self?.currentCallUUID = nil
            }
        }
    }
    
    // ADDED: Proper cleanup
    deinit {
        provider.invalidate()
    }
}
