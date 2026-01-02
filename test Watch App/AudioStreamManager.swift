import AVFoundation
import SwiftUI
import Combine
import Opus
import SoundAnalysis

class AudioStreamManager: NSObject, ObservableObject {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var encoder: Opus.Encoder?
    private var decoder: Opus.Decoder?

    // --- VAD & BUFFERING PROPERTIES ---
    private var preRollBuffers: [AVAudioPCMBuffer] = []
    private let maxPreRollCount = 50 // Exactly 1 second if buffer is 20ms

    // We use a lock to ensure the Audio Thread and VAD Thread don't collide
    private let stateLock = NSLock()
    private var isTransmitting = false
    private var hangoverWorkItem: DispatchWorkItem?

    // Serial queue for network tasks to keep the audio thread fast
    private let networkQueue = DispatchQueue(label: "com.audio.networkQueue", qos: .userInteractive)

    private var receivedObserver: NSObjectProtocol?
    private var endCallObserver: NSObjectProtocol?
    private var analyzer: SNAudioStreamAnalyzer?
    private let observer = SpeechResultObserver()
    private var hasEnded = false
    private var isActive = false

    @Published var isSpeaking: Bool = false
    private var format: AVAudioFormat?
    var securityManager: SecurityManager?

    func setupAudio() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
            try session.setActive(true)

            let inputNode = engine.inputNode
            let hardwareFormat = inputNode.inputFormat(forBus: 0)
            self.format = hardwareFormat
            self.analyzer = SNAudioStreamAnalyzer(format: hardwareFormat)

            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: 0.5, preferredTimescale: 600)
            request.overlapFactor = 0.7
            try analyzer?.add(request, withObserver: observer)

            // --- VAD LOGIC CALLBACK ---
            observer.onSpeechStatusChanged = { [weak self] detected in
                guard let self = self else { return }

                // We handle the state change immediately on the VAD thread
                self.stateLock.lock()
                if detected {
                    self.hangoverWorkItem?.cancel()
                    if !self.isTransmitting {
                        // Rising Edge: Send the "Time Machine" buffers first
                        self.flushPreRoll()
                        self.isTransmitting = true
                    }
                } else {
                    // Start the timer to close the gate in 1 second
                    self.startHangoverTimer()
                }
                self.stateLock.unlock()

                // Update UI on main thread
                DispatchQueue.main.async { self.isSpeaking = detected }
            }

            self.encoder = try Opus.Encoder(format: hardwareFormat, application: .voip)
            self.decoder = try Opus.Decoder(format: hardwareFormat)

            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: hardwareFormat)

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 960, format: hardwareFormat) { [weak self] (buffer, time) in
                guard let self = self, self.isActive else { return }

                // 1. Analyze for speech detection
                self.analyzer?.analyze(buffer, atAudioFramePosition: time.sampleTime)

                // 2. Thread-safe data handling
                self.stateLock.lock()
                if self.isTransmitting {
                    // Send real-time
                    self.processAndSend(buffer: buffer)
                } else {
                    // Not transmitting? Fill the pre-roll "rolling window"
                    self.appendPreRoll(buffer: buffer)
                }
                self.stateLock.unlock()
            }

            setupObservers()
        } catch {
            print("❌ Setup Failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Core Buffer Logic

    private func appendPreRoll(buffer: AVAudioPCMBuffer) {
        // Deep copy the audio samples to prevent "glitched" sounds
        if let copy = buffer.deepCopy() {
            preRollBuffers.append(copy)
        }
        if preRollBuffers.count > maxPreRollCount {
            preRollBuffers.removeFirst()
        }
    }

    private func flushPreRoll() {
        // Since we are inside the lock when this is called, order is guaranteed
        print("VAD: Flushing \(preRollBuffers.count) frames.")
        for buffer in preRollBuffers {
            self.processAndSend(buffer: buffer)
        }
        preRollBuffers.removeAll()
    }

    private func startHangoverTimer() {
        hangoverWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            print("VAD: 1.0s silence reached. Stopping transmission.")
            self.isTransmitting = false
            self.stateLock.unlock()
        }
        hangoverWorkItem = workItem
        // We use 1.0s to ensure even slow talkers aren't cut off
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func processAndSend(buffer: AVAudioPCMBuffer) {
        guard let secManager = self.securityManager, secManager.sessionKey != nil else { return }

        // Use a background queue so network lag doesn't stutter your mic recording
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                var data = Data(count: 1500)
                if let encodedCount = try self.encoder?.encode(buffer, to: &data), encodedCount > 0 {
                    let opusData = data.prefix(encodedCount)
                    let encryptedData = try secManager.encryptPayload(Data(opusData))
                    NotificationCenter.default.post(name: .sendUDP, object: encryptedData)
                }
            } catch {
                print("Opus Error: \(error)")
            }
        }
    }

    // MARK: - Standard Helpers

    private func setupObservers() {
        receivedObserver = NotificationCenter.default.addObserver(forName: .receivedUDP, object: nil, queue: .main) { [weak self] notification in
            if let data = notification.object as? Data { self?.handleIncomingAudio(data: data) }
        }
        endCallObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name("EndAudioInternal"), object: nil, queue: .main) { [weak self] _ in
            self?.endCall()
        }
    }

    func start() {
        do {
            hasEnded = false
            isActive = true
            try engine.start()
            player.play()
        } catch { print("Engine start error: \(error)") }
    }

    func endCall() {
        // 1. Mark as no longer active immediately to stop new processing
        isActive = false
        hasEnded = true

        // 2. Stop the engine FIRST (outside the lock)
        // This stops the audio thread, preventing the deadlock
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.reset()

        // 3. Now safely lock to clean up the data states
        stateLock.lock()
        isTransmitting = false
        isSpeaking = false
        preRollBuffers.removeAll()
        hangoverWorkItem?.cancel()
        stateLock.unlock()

        // 4. Cleanup observers and session
        player.stop()
        analyzer?.removeAllRequests()
        analyzer = nil
        observer.onSpeechStatusChanged = nil
        securityManager?.clearSession()

        if let token = receivedObserver {
            NotificationCenter.default.removeObserver(token)
            receivedObserver = nil
        }
        if let token = endCallObserver {
            NotificationCenter.default.removeObserver(token)
            endCallObserver = nil
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        encoder = nil
        decoder = nil

        print("✅ Call ended successfully.")
    }

    func handleIncomingAudio(data: Data) {
        guard isActive, let decoder = self.decoder else { return }
        do {
            let decodedBuffer = try decoder.decode(data)
            if !player.isPlaying { player.play() }
            player.scheduleBuffer(decodedBuffer, completionHandler: nil)
        } catch { print("Decoding error: \(error)") }
    }
}

// MARK: - Deep Copy Helper
extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: self.frameCapacity) else { return nil }
        copy.frameLength = self.frameLength

        let size = Int(self.frameLength) * MemoryLayout<Float>.size // Assuming standard float format
        if let src = self.floatChannelData, let dst = copy.floatChannelData {
            for i in 0..<Int(self.format.channelCount) {
                memcpy(dst[i], src[i], size)
            }
        }
        return copy
    }
}

class SpeechResultObserver: NSObject, SNResultsObserving {
    var isSpeaking: Bool = false
    var onSpeechStatusChanged: ((Bool) -> Void)?

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult,
              let speech = result.classification(forIdentifier: "speech") else { return }
        let detected = speech.confidence > 0.7
        if detected != isSpeaking {
            isSpeaking = detected
            onSpeechStatusChanged?(detected)
        }
    }
}
