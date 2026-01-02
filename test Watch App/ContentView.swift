import SwiftUI // Ensure this is at the very top

struct ContentView: View {
    @StateObject private var audioManager = AudioStreamManager()
    @StateObject private var udpManager = UDPManager()
    @StateObject private var securityManager = SecurityManager()

    // CallManager is a simple class, it doesn't need @StateObject
    // unless you want the UI to react to its internal changes.
    private var callManager = CallManager()
    
    @State private var isCalling = false

    var body: some View {
        VStack {
            Button(action: {
                if !isCalling {
                    startThePipeline()
                } else {
                    stopThePipeline()
                }
            }) {
                Text(isCalling ? "End Call" : "Start Call")
                    .bold()
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(isCalling ? .red : .green)
        }
    }

    func startThePipeline() {
        isCalling = true
        Task {
            do {
                try await securityManager.performHandshake(serverURL: "http://192.168.1.160:5556")
                
                callManager.startCall(handle: "BunServer")
                
                // Connect UDP AND link the security manager
                udpManager.securityManager = securityManager
                udpManager.connect(host: "192.168.1.160", port: 5555)
                
                audioManager.securityManager = securityManager
                audioManager.setupAudio()
                audioManager.start()
            } catch {
                print("Pipeline Failed: \(error)")
                stopThePipeline()
            }
        }
    }

    func stopThePipeline() {
        isCalling = false
            
        // 1. Stop audio FIRST (stops generating data)
        audioManager.endCall()
        
        // 2. Close network (stops sending/receiving data)
        udpManager.disconnect()
        
        // 3. End CallKit UI last
        callManager.endCall()
        
        // 4. Clear security keys
        securityManager.clearSession()
    }
}
