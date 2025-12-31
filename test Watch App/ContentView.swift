
import SwiftUI

struct ContentView: View {
    // Create "instances" of your managers
    @StateObject private var audioManager = AudioStreamManager()
    private var udpManager = UDPManager()
    private var callManager = CallManager()
    
    @State private var isCalling = false

    var body: some View {
        VStack {
            Button(action: {
                if !isCalling {
                    startThePipeline()
                } else {
                    // Logic to end call would go here
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
        
        // 1. Tell the Watch "I am starting a VoIP call" (keeps app alive)
        callManager.startCall(handle: "BunServer")
        
        // 2. Open the UDP socket to your Bun server
        udpManager.connect(host: "192.168.1.160", port: 5555)
        
        // 3. Start the Mic and Speaker
        audioManager.setupAudio()
        audioManager.start()
        
        print("Pipeline is now active.")
    }
}
