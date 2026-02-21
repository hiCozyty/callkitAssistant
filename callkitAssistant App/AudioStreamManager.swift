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
    private let maxPreRollCount = 25

    private let stateLock = NSLock()
    private var isTransmitting = false
    private var hangoverWorkItem: DispatchWorkItem?

    private let networkQueue = DispatchQueue(label: "com.audio.networkQueue", qos: .userInteractive)

    private var receivedObserver: NSObjectProtocol?
    private var analyzer: SNAudioStreamAnalyzer?
    private let observer = SpeechResultObserver()
    private var hasEnded = false
    private var isActive = false
    private var audioSetupComplete = false

    @Published var isSpeaking: Bool = false
    private var format: AVAudioFormat?
    var securityManager: SecurityManager?

    // ✅ CallKit Callback: Fires after engine is fully running (Post-VPIO)
    var onEngineStarted: (() -> Void)?

    override init() {
        super.init()
        setupObservers()
    }

    // ─────────────────────────────────────────────────────────────────────
    // 🖥️ SIMULATOR PATH (Direct Control)
    // ─────────────────────────────────────────────────────────────────────
    #if targetEnvironment(simulator)
    func startAudio() {
        guard !isActive else { return }
        logTime("🎤 startAudio — beginning setup (Simulator)")
        let session = AVAudioSession.sharedInstance()

        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
            try session.setActive(true)

            engine.attach(player)
            let inputNode = engine.inputNode
            let hardwareFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
            
            self.format = hardwareFormat
            self.encoder = try Opus.Encoder(format: hardwareFormat, application: .voip)
            self.decoder = try Opus.Decoder(format: hardwareFormat)

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
                    if !self.isTransmitting { self.flushPreRoll(); self.isTransmitting = true }
                } else { self.startHangoverTimer() }
                self.stateLock.unlock()
                Task { @MainActor in self.isSpeaking = detected }
            }

            engine.connect(player, to: engine.mainMixerNode, format: hardwareFormat)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 960, format: hardwareFormat) { [weak self] (buffer, time) in
                guard let self = self else { return }
                self.analyzer?.analyze(buffer, atAudioFramePosition: time.sampleTime)
                self.stateLock.lock()
                if self.isTransmitting { self.processAndSend(buffer: buffer) }
                else { self.appendPreRoll(buffer: buffer) }
                self.stateLock.unlock()
            }

            try engine.start()
            player.play()
            isActive = true
            hasEnded = false
            isTransmitting = true // Force transmit on simulator

            logTime("✅ Audio Engine Started & Running (Simulator)")

        } catch {
            logTime("❌ startAudio failed: \(error)")
            isActive = false
        }
    }
    #endif

    // ─────────────────────────────────────────────────────────────────────
    // 📱 DEVICE PATH (CallKit Lifecycle)
    // ─────────────────────────────────────────────────────────────────────
    #if !targetEnvironment(simulator)
    
    // Phase 1: Called BEFORE startCall() — slow DSP init, NO format queries
    func prepareAudioHardware() {
        logTime("🔧 prepareAudioHardware — Phase 1 (Pre-CallKit)")
        do {
            // Set category but DO NOT activate — CallKit will do that
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
            engine.attach(player)

            // Pre-warm ML model and Opus with a dummy format
            let warmupFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
            
            // Warmup analyzer
            let warmupAnalyzer = SNAudioStreamAnalyzer(format: warmupFormat)
            let warmupRequest = try SNClassifySoundRequest(classifierIdentifier: .version1)
            try warmupAnalyzer.add(warmupRequest, withObserver: SpeechResultObserver())

            // Warmup Opus
            self.encoder = try Opus.Encoder(format: warmupFormat, application: .voip)
            self.decoder = try Opus.Decoder(format: warmupFormat)

            logTime("✅ Audio hardware prepared (ML models warmed)")
        } catch {
            logTime("❌ prepareAudioHardware failed: \(error)")
        }
    }

    // Phase 2: Called AFTER didActivate — format is now valid
    func setupAudioAfterActivation() {
        logTime("🔧 setupAudioAfterActivation — Phase 2 (Post-CallKit)")
        let inputNode = engine.inputNode

        do {
            let hardwareFormat = inputNode.inputFormat(forBus: 0)
            logTime("🔧 hardwareFormat: \(hardwareFormat)")

            engine.connect(player, to: engine.mainMixerNode, format: hardwareFormat)

            // Enable VPIO — triggers async reconfiguration
            try inputNode.setVoiceProcessingEnabled(true)
            logTime("🔧 setVoiceProcessingEnabled called")

            // Listen for configuration change (VPIO reconfig)
            NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                guard let self = self, !self.hasEnded else { return }
                NotificationCenter.default.removeObserver(
                    self, name: .AVAudioEngineConfigurationChange, object: self.engine
                )
                logTime("✅ AVAudioEngineConfigurationChange received")
                self.engine.stop()
                self.finishAudioSetup()
            }

            try engine.start()
            logTime("🔧 engine.start() returned — isRunning: \(engine.isRunning)")

            if engine.isRunning {
                // VPIO applied synchronously (rare but possible)
                logTime("🔧 Engine running after VPIO — stopping for finishAudioSetup")
                NotificationCenter.default.removeObserver(
                    self, name: .AVAudioEngineConfigurationChange, object: engine
                )
                engine.stop()
                finishAudioSetup()
            }

        } catch {
            logTime("❌ setupAudioAfterActivation failed: \(error)")
        }
    }

    // Phase 3: Final setup after VPIO reconfiguration
    private func finishAudioSetup() {
        stateLock.lock()
        guard !audioSetupComplete else {
            stateLock.unlock()
            logTime("⚠️ finishAudioSetup called twice — ignoring")
            return
        }
        audioSetupComplete = true
        stateLock.unlock()
        
        let inputNode = engine.inputNode

        do {
            let hardwareFormat = inputNode.inputFormat(forBus: 0)
            logTime("✅ Hardware format post-VPIO: \(hardwareFormat)")
            self.format = hardwareFormat

            // Re-init encoder/decoder with confirmed format
            self.encoder = try Opus.Encoder(format: hardwareFormat, application: .voip)
            self.decoder = try Opus.Decoder(format: hardwareFormat)

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
                    if !self.isTransmitting { self.flushPreRoll(); self.isTransmitting = true }
                } else { self.startHangoverTimer() }
                self.stateLock.unlock()
                Task { @MainActor in self.isSpeaking = detected }
            }

            engine.connect(player, to: engine.mainMixerNode, format: hardwareFormat)

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 960, format: hardwareFormat) { [weak self] (buffer, time) in
                guard let self = self else { return }
                self.analyzer?.analyze(buffer, atAudioFramePosition: time.sampleTime)
                self.stateLock.lock()
                if self.isTransmitting { self.processAndSend(buffer: buffer) }
                else { self.appendPreRoll(buffer: buffer) }
                self.stateLock.unlock()
            }

            try engine.start()
            player.play()
            isActive = true
            hasEnded = false
            
            logTime("🎤 Engine restarted post-VPIO, isRunning: \(engine.isRunning)")
            
            // ✅ Fire callback for handshake/UDP
            onEngineStarted?()

        } catch {
            logTime("❌ finishAudioSetup failed: \(error)")
        }
    }
    #endif

    // ─────────────────────────────────────────────────────────────────────
    // COMMON: Teardown & Helpers (Both Paths)
    // ─────────────────────────────────────────────────────────────────────
    
    func endCall() {
        guard !hasEnded else {  // ✅ Add this guard at the VERY top
            logTime("⚠️ endCall called but hasEnded is true — ignoring")
            return
        }
        logTime("🛑 endCall called")

        hasEnded = true
        isActive = false
        audioSetupComplete = false
        onEngineStarted = nil

        if engine.isRunning { engine.stop() }
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
        } catch { logTime("Decoding error: \(error)") }
    }

    private func setupObservers() {
        receivedObserver = NotificationCenter.default.addObserver(
            forName: .receivedUDP, object: nil, queue: .main
        ) { [weak self] notification in
            if let data = notification.object as? Data { self?.handleIncomingAudio(data: data) }
        }
    }

    private func appendPreRoll(buffer: AVAudioPCMBuffer) {
        if let copy = buffer.deepCopy() { preRollBuffers.append(copy) }
        if preRollBuffers.count > maxPreRollCount { preRollBuffers.removeFirst() }
    }

    private func flushPreRoll() {
        logTime("VAD: Flushing \(preRollBuffers.count) frames")
        for buffer in preRollBuffers { self.processAndSend(buffer: buffer) }
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
            onSpeechStatusChanged?(detected)
        }
    }
}
