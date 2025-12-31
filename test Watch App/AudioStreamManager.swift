import AVFoundation
import SwiftUI
import Combine
import Opus

class AudioStreamManager: NSObject, ObservableObject {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var encoder: Opus.Encoder?
    private var decoder: Opus.Decoder?
    private var receivedObserver: NSObjectProtocol?
    
    // We will initialize these once we know the hardware's native format
    private var format: AVAudioFormat?

    func setupAudio() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
            try session.setActive(true)
            
            // 1. Get the EXACT format the hardware is currently using (usually 48000Hz)
            let hardwareFormat = engine.inputNode.inputFormat(forBus: 0)
            self.format = hardwareFormat
            
            // 2. Initialize Opus to match the hardware exactly
            self.encoder = try Opus.Encoder(format: hardwareFormat, application: .voip)
            self.decoder = try Opus.Decoder(format: hardwareFormat)
            
            print("Audio Pipeline initialized at \(hardwareFormat.sampleRate)Hz")
        } catch {
            print("Initialization Error: \(error)")
            return
        }

        guard let format = self.format else { return }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        // 3. Tap the input node directly (No mismatch because formats match!)
        engine.inputNode.installTap(onBus: 0, bufferSize: 960, format: format) { [weak self] (buffer, time) in
            guard let self = self, let encoder = self.encoder else { return }
            
            do {
                var data = Data(count: 1500)
                let encodedCount = try encoder.encode(buffer, to: &data)
                
                if encodedCount > 0 {
                    let finalPacket = data.prefix(encodedCount)
                    NotificationCenter.default.post(name: .sendUDP, object: finalPacket)
                }
            } catch {
                print("Encoding error: \(error)")
            }
        }
        
        receivedObserver = NotificationCenter.default.addObserver(forName: .receivedUDP, object: nil, queue: .main) { [weak self] notification in
            if let data = notification.object as? Data {
                self?.handleIncomingAudio(data: data)
            }
        }
    }

    func handleIncomingAudio(data: Data) {
        guard let decoder = self.decoder else { return }
        do {
            let decodedBuffer = try decoder.decode(data)
            if !player.isPlaying { player.play() }
            player.scheduleBuffer(decodedBuffer, completionHandler: nil)
        } catch {
            print("Decoding error: \(error)")
        }
    }

    func start() {
        do {
            try engine.start()
            player.play()
        } catch {
            print("Engine start error: \(error)")
        }
    }
    
    func endCall() {
        // Stop playback first
        player.stop()
        
        // Remove mic tap to stop capturing
        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        
        // Stop and reset engine
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()
        
        // Deactivate audio session
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            print("Session deactivation error: \(error)")
        }
        
        // Remove UDP receive observer
        if let token = receivedObserver {
            NotificationCenter.default.removeObserver(token)
            receivedObserver = nil
        }
        
        // Optionally clear encoder/decoder if you recreate them on next call
        // encoder = nil
        // decoder = nil
    }
}
