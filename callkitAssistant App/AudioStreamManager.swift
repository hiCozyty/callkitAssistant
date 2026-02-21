// AudioStreamManager.swift
import AVFoundation
import Combine
import Opus
import SoundAnalysis
import SwiftUI

class AudioStreamManager: NSObject, ObservableObject {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var encoder: Opus.Encoder?
    private var decoder: Opus.Decoder?

    // --- VAD & BUFFERING PROPERTIES ---
    private var preRollBuffers: [AVAudioPCMBuffer] = []
    private let maxPreRollCount = 25 // ~0.5 seconds of preroll (20ms frames)

    private let stateLock = NSLock()
    private var isTransmitting = false
    private var hangoverWorkItem: DispatchWorkItem?

    private let networkQueue = DispatchQueue(label: "com.audio.networkQueue", qos: .userInteractive)

    private var receivedObserver: NSObjectProtocol?
    private var analyzer: SNAudioStreamAnalyzer?
    private let observer = SpeechResultObserver()
    private var hasEnded = false
    private var isActive = false

    @Published var isSpeaking: Bool = false
    private var format: AVAudioFormat?
    var securityManager: SecurityManager?

    override init() {
        super.init()
        setupObservers()
    }

    // ✅ Single Setup Method for Simulator
    func startAudio() {
        guard !isActive else {
            logTime("⚠️ startAudio called but already active")
            return
        }

        logTime("🎤 startAudio — beginning setup")
        let session = AVAudioSession.sharedInstance()

        do {
            // 1. Session Configuration
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
            try session.setActive(true)

            // 2. Engine Setup
            engine.attach(player)
            let inputNode = engine.inputNode
            
            // Simulator uses a fixed format, Device would query hardwareFormat
            #if targetEnvironment(simulator)
            let hardwareFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
            #else
            let hardwareFormat = inputNode.inputFormat(forBus: 0)
            #endif
            
            self.format = hardwareFormat
            logTime("🔧 Using format: \(hardwareFormat)")

            // 3. Opus Init
            self.encoder = try Opus.Encoder(format: hardwareFormat, application: .voip)
            self.decoder = try Opus.Decoder(format: hardwareFormat)

            // 4. VAD Init
            self.analyzer = SNAudioStreamAnalyzer(format: hardwareFormat)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: 0.5, preferredTimescale: 600)
            request.overlapFactor = 0.7
            try analyzer?.add(request, withObserver: observer)

            observer.onSpeechStatusChanged = { [weak self] detected in
                guard let self = self else { return }
                self.stateLock.lock()
                if detected {
                    self.hangoverWorkItem?.cancel()
                    if !self.isTransmitting {
                        self.flushPreRoll()
                        self.isTransmitting = true
                    }
                } else {
                    self.startHangoverTimer()
                }
                self.stateLock.unlock()
                Task { @MainActor in self.isSpeaking = detected }
            }

            // 5. Connect & Tap
            engine.connect(player, to: engine.mainMixerNode, format: hardwareFormat)

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 960, format: hardwareFormat) { [weak self] (buffer, time) in
                guard let self = self else { return }
                
                // VAD Analysis
                self.analyzer?.analyze(buffer, atAudioFramePosition: time.sampleTime)

                // Buffering Logic
                self.stateLock.lock()
                if self.isTransmitting {
                    self.processAndSend(buffer: buffer)
                } else {
                    self.appendPreRoll(buffer: buffer)
                }
                self.stateLock.unlock()
            }

            // 6. Start Engine
            try engine.start()
            player.play()
            isActive = true
            hasEnded = false
            
            // Simulator Force Transmit (since VAD might not trigger reliably on sim mic)
            #if targetEnvironment(simulator)
            stateLock.lock()
            isTransmitting = true
            stateLock.unlock()
            #endif

            logTime("✅ Audio Engine Started & Running")

        } catch {
            logTime("❌ startAudio failed: \(error)")
            isActive = false
        }
    }

    func endCall() {
        guard isActive || hasEnded else { return }
        logTime("🛑 endCall called")

        hasEnded = true
        isActive = false

        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.reset()
        player.stop()

        stateLock.lock()
        isTransmitting = false
        preRollBuffers.removeAll()
        hangoverWorkItem?.cancel()
        stateLock.unlock()

        Task { @MainActor in self.isSpeaking = false }

        analyzer?.removeAllRequests()
        analyzer = nil
        observer.onSpeechStatusChanged = nil
        securityManager?.clearSession()

        if let token = receivedObserver {
            NotificationCenter.default.removeObserver(token)
            receivedObserver = nil
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        encoder = nil
        decoder = nil

        logTime("✅ Call ended successfully.")
    }

    func handleIncomingAudio(data: Data) {
        guard isActive, let decoder = self.decoder else { return }
        do {
            let decodedBuffer = try decoder.decode(data)
            if !player.isPlaying { player.play() }
            player.scheduleBuffer(decodedBuffer, completionHandler: nil)
        } catch {
            logTime("Decoding error: \(error)")
        }
    }

    // MARK: - Private Helpers

    private func setupObservers() {
        receivedObserver = NotificationCenter.default.addObserver(
            forName: .receivedUDP, object: nil, queue: .main
        ) { [weak self] notification in
            if let data = notification.object as? Data { self?.handleIncomingAudio(data: data) }
        }
    }

    private func appendPreRoll(buffer: AVAudioPCMBuffer) {
        if let copy = buffer.deepCopy() {
            preRollBuffers.append(copy)
        }
        if preRollBuffers.count > maxPreRollCount {
            preRollBuffers.removeFirst()
        }
    }

    private func flushPreRoll() {
        logTime("VAD: Flushing \(preRollBuffers.count) frames")
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
            logTime("VAD: silence threshold reached. Stopping transmission")
            self.isTransmitting = false
            self.stateLock.unlock()
        }
        hangoverWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func processAndSend(buffer: AVAudioPCMBuffer) {
        guard let secManager = self.securityManager else {
            logTime("🔴 processAndSend: securityManager is nil")
            return
        }
        guard secManager.sessionKey != nil else {
            logTime("🔴 processAndSend: sessionKey is nil — handshake incomplete?")
            return
        }
        
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                var data = Data(count: 1500)
                guard let encodedCount = try self.encoder?.encode(buffer, to: &data), encodedCount > 0 else {
                    logTime("🔴 Encode returned 0 or nil")
                    return
                }
                let opusData = data.prefix(encodedCount)
                let encryptedData = try secManager.encryptPayload(Data(opusData))
                NotificationCenter.default.post(name: .sendUDP, object: encryptedData)
            } catch {
                logTime("🔴 processAndSend error: \(error)")
            }
        }
    }
}

// MARK: - Deep Copy Helper
extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: self.frameCapacity)
        else { return nil }
        copy.frameLength = self.frameLength

        let size = Int(self.frameLength) * MemoryLayout<Float>.size
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
            let speech = result.classification(forIdentifier: "speech")
        else { return }
        let detected = speech.confidence > 0.7
        if detected != isSpeaking {
            isSpeaking = detected
            // Optional: Log VAD status
            // logTime("🎤 [VAD] Speech: \(detected) (conf: \(String(format: "%.2f", speech.confidence)))")
            onSpeechStatusChanged?(detected)
        }
    }
}
