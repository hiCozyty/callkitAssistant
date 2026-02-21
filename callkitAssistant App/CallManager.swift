//CallManager.swift
import Foundation
import CallKit
import AVFoundation
import Combine
class CallManager: NSObject, CXProviderDelegate, ObservableObject {
    let controller = CXCallController()
    private let provider: CXProvider
    private let callKitQueue = DispatchQueue(label: "com.myApp.callkit")
    
    var currentCallUUID: UUID? {
        didSet {
            if oldValue != currentCallUUID {
                logTime("📞 Call UUID changed: \(currentCallUUID?.uuidString ?? "nil")")
            }
        }
    }
    func reportCallConnected() {
        guard let uuid = currentCallUUID else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
        logTime("📞 CallKit: reported call connected (session ready)")
    }

    
    enum CallState { case idle, starting, active, ending, ended }
    @Published private(set) var callState: CallState = .idle
    
    // ✅ Only allow didDeactivate to post EndAudioInternal when WE ended the call
    private var isCallIntentionallyEnded = false

    private var cancellables = Set<AnyCancellable>()
    
    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false

        self.provider = CXProvider(configuration: configuration)
        super.init()
        self.provider.setDelegate(self, queue: callKitQueue)
        
        NotificationCenter.default.publisher(for: NSNotification.Name("EndAudioInternal"))
            .receive(on: RunLoop.main)
            .sink { [weak self] (_: Notification) in
                self?.callState = .ended
            }
            .store(in: &cancellables)
    }

    func startCall(handle: String) async throws {
        // ✅ Reset flag at the start of every new call
        isCallIntentionallyEnded = false

        Task { @MainActor in
            self.callState = .starting
        }
        
        let uuid = UUID()
        self.currentCallUUID = uuid
        let startCallAction = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: handle))
        let transaction = CXTransaction(action: startCallAction)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controller.request(transaction) { error in
                Task {
                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        if let error = error {
                            self.callState = .idle
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }
    
    func providerDidReset(_ provider: CXProvider) {
        logTime("🔴 CallKit: providerDidReset fired")
        stopAudio()
        currentCallUUID = nil
    }
    
    func forceEndCall() {
        isCallIntentionallyEnded = true
        Task { @MainActor in
            self.callState = .ended
        }
        currentCallUUID = nil
        stopAudio()
    }
    
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
        } catch {
            logTime("Failed to configure audio session: \(error)")
            action.fail()
            return
        }
        
        action.fulfill()
//        provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
        
        Task { @MainActor in
            self.callState = .active
        }
        logTime("CallKit: Call Started — waiting for session before reporting connected")

        #if targetEnvironment(simulator)
        logTime("🖥️ Simulator: manually firing didActivate")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.provider(provider, didActivate: AVAudioSession.sharedInstance())
        }
        #endif // targetEnvironment(simulator)

    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        isCallIntentionallyEnded = true  // ✅ System-initiated end (e.g. CallKit UI)
        stopAudio()
        action.fulfill()
        
        Task { @MainActor in
            self.callState = .ended
        }
        logTime("CallKit: Call Ended")
    }
    
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        logTime("✅ CallKit: didActivate — posting StartAudioInternal")
        NotificationCenter.default.post(name: NSNotification.Name("StartAudioInternal"), object: nil)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // ✅ Log BEFORE the guard so we always see this fire
        logTime("⚠️ CallKit: didDeactivate — isCallIntentionallyEnded: \(isCallIntentionallyEnded)")
        guard isCallIntentionallyEnded else {
            logTime("⚠️ CallKit: Ignoring spurious didDeactivate")
            return
        }
        logTime("📣 EndAudioInternal posted from: didDeactivate")
        NotificationCenter.default.post(name: NSNotification.Name("EndAudioInternal"), object: nil)
    }

    private func stopAudio() {
        logTime("📣 EndAudioInternal posted from: stopAudio() — callstack: \(Thread.callStackSymbols.prefix(5).joined(separator: "\n"))")
        NotificationCenter.default.post(name: NSNotification.Name("EndAudioInternal"), object: nil)
    }

    func endCall() {
        guard let uuid = currentCallUUID else { return }
        isCallIntentionallyEnded = true  // ✅ User-initiated end
        let endCallAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endCallAction)
        
        controller.request(transaction) { error in
            Task {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    if let error = error {
                        logTime("Error ending call: \(error)")
                    } else {
                        self.currentCallUUID = nil
                        self.callState = .ended
                    }
                }
            }
        }
    }
    
    deinit {
        provider.invalidate()
        cancellables.forEach { $0.cancel() }
    }
}
