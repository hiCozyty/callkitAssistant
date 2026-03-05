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

    // ✅ Performance Tracking
    private var pipelineStartTime: CFAbsoluteTime = 0

    @Published var isSpeaking: Bool = false
    private var format: AVAudioFormat?
    var securityManager: SecurityManager?

    // ✅ CallKit Callback
    var onEngineStarted: (() -> Void)?

    override init() {
        super.init()
        setupObservers()
    }

    // ─────────────────────────────────────────────────────────────────────
    // 🖥️ SIMULATOR PATH
    // ─────────────────────────────────────────────────────────────────────
    #if targetEnvironment(simulator)
    func startAudio() {
        guard !isActive else { return }
        pipelineStartTime = CFAbsoluteTimeGetCurrent()
        logTime("🎤 startAudio — beginning setup (Simulator)", start: pipelineStartTime)
        
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
            try session.setActive(true)

            engine.attach(player)
            let inputNode = engine.inputNode
//            try inputNode.setVoiceProcessingEnabled(true) //doesnt do anything..
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
            
            Task { @MainActor in
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setActive(true, options: [.notifyOthersOnDeactivation])
                    logTime("🔊 Simulator: Audio session re-activated for playback")
                } catch {
                    logTime("⚠️ Failed to re-activate session: \(error)")
                }
            }
            
            isActive = true
            hasEnded = false
            isTransmitting = true

            logTime("✅ Audio Engine Started & Running (Simulator)", start: pipelineStartTime)

        } catch {
            logTime("❌ startAudio failed: \(error)", start: pipelineStartTime)
            isActive = false
        }
    }
    #endif

    // ─────────────────────────────────────────────────────────────────────
    // 📱 DEVICE PATH
    // ─────────────────────────────────────────────────────────────────────
    #if !targetEnvironment(simulator)
    
    // Phase 1: Called at APP LAUNCH — slow DSP init
    func prepareAudioHardware() {
        let prepStart = CFAbsoluteTimeGetCurrent()
        logTime("🔧 prepareAudioHardware — Phase 1 (Pre-CallKit)", start: prepStart)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
            engine.attach(player)

            let warmupFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
            
            let warmupAnalyzer = SNAudioStreamAnalyzer(format: warmupFormat)
            let warmupRequest = try SNClassifySoundRequest(classifierIdentifier: .version1)
            try warmupAnalyzer.add(warmupRequest, withObserver: SpeechResultObserver())

            self.encoder = try Opus.Encoder(format: warmupFormat, application: .voip)
            self.decoder = try Opus.Decoder(format: warmupFormat)

            logTime("✅ Audio hardware prepared (ML models warmed)", start: prepStart)
        } catch {
            logTime("❌ prepareAudioHardware failed: \(error)", start: prepStart)
        }
    }

    // Phase 2: Called AFTER didActivate
    func setupAudioAfterActivation(pipelineStartTime: CFAbsoluteTime) {
        self.pipelineStartTime = pipelineStartTime
        logTime("🔧 setupAudioAfterActivation — Phase 2 (Post-CallKit)", start: pipelineStartTime)
        let inputNode = engine.inputNode

        do {
            let hardwareFormat = inputNode.inputFormat(forBus: 0)
            logTime("🔧 hardwareFormat: \(hardwareFormat)", start: pipelineStartTime)

            engine.connect(player, to: engine.mainMixerNode, format: hardwareFormat)

            try inputNode.setVoiceProcessingEnabled(true)
            logTime("🔧 setVoiceProcessingEnabled called", start: pipelineStartTime)

            NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                guard let self = self, !self.hasEnded else { return }
                NotificationCenter.default.removeObserver(
                    self, name: .AVAudioEngineConfigurationChange, object: self.engine
                )
                logTime("✅ AVAudioEngineConfigurationChange received", start: self.pipelineStartTime)
                self.engine.stop()
                self.finishAudioSetup()
            }

            try engine.start()
            logTime("🔧 engine.start() returned — isRunning: \(engine.isRunning)", start: pipelineStartTime)

            if engine.isRunning {
                logTime("🔧 Engine running after VPIO — stopping for finishAudioSetup", start: pipelineStartTime)
                NotificationCenter.default.removeObserver(
                    self, name: .AVAudioEngineConfigurationChange, object: engine
                )
                engine.stop()
                finishAudioSetup()
            }

        } catch {
            logTime("❌ setupAudioAfterActivation failed: \(error)", start: pipelineStartTime)
        }
    }

    private func finishAudioSetup() {
        stateLock.lock()
        guard !audioSetupComplete else {
            stateLock.unlock()
            logTime("⚠️ finishAudioSetup called twice — ignoring", start: pipelineStartTime)
            return
        }
        audioSetupComplete = true
        stateLock.unlock()
        
        let inputNode = engine.inputNode

        do {
            let hardwareFormat = inputNode.inputFormat(forBus: 0)
            logTime("✅ Hardware format post-VPIO: \(hardwareFormat)", start: pipelineStartTime)
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
            
            logTime("🎤 Engine restarted post-VPIO, isRunning: \(engine.isRunning)", start: pipelineStartTime)
            
            onEngineStarted?()

        } catch {
            logTime("❌ finishAudioSetup failed: \(error)", start: pipelineStartTime)
        }
    }
    #endif

    // ─────────────────────────────────────────────────────────────────────
    // COMMON: Teardown & Helpers
    // ─────────────────────────────────────────────────────────────────────
    
    func endCall() {
        guard !hasEnded else {
            logTime("⚠️ endCall called but hasEnded is true — ignoring", start: pipelineStartTime)
            return
        }
        logTime("🛑 endCall called", start: pipelineStartTime)

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

//        if let token = receivedObserver {
//            NotificationCenter.default.removeObserver(token)
//            receivedObserver = nil
//        }

        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        encoder = nil
        decoder = nil

        logTime("✅ Call ended successfully.", start: pipelineStartTime)
    }

    func handleIncomingAudio(data: Data) {
        guard isActive,
              let secManager = self.securityManager,
              let decoder = self.decoder
        else {
            logTime("🔴 handleIncomingAudio: guard failed - isActive=\(isActive), decoder=\(decoder != nil)")
            return
        }
        
        do {
//            logTime("📥 Incoming packet: \(data.count)B")
            
            // 1. Decrypt packet → raw Opus frame
            let opusFrame = try secManager.decryptServerPayload(data)
//            logTime("🔓 Decrypted Opus frame: \(opusFrame.count)B")
            
            // 2. Decode Opus → PCM buffer
            let decodedBuffer = try decoder.decode(opusFrame)
//            logTime("🎵 Decoded PCM: \(decodedBuffer.frameLength) frames @ \(decodedBuffer.format.sampleRate)Hz, channels=\(decodedBuffer.format.channelCount)")
            
            // 3. Check player state
//            logTime("🔊 Player state: isPlaying=\(player.isPlaying), engine.isRunning=\(engine.isRunning)")
            
            // 4. Schedule for playback
            if !player.isPlaying {
//                logTime("▶️ Starting player")
                player.play()
            }
            player.scheduleBuffer(decodedBuffer, completionHandler: nil)
//            logTime("✅ Buffer scheduled")
            
        } catch {
            logTime("🔴 Incoming audio error: \(error)")
        }
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
        logTime("VAD: Flushing \(preRollBuffers.count) frames", start: pipelineStartTime)
        for buffer in preRollBuffers { self.processAndSend(buffer: buffer) }
        preRollBuffers.removeAll()
    }

    private func startHangoverTimer() {
        hangoverWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            logTime("VAD: silence threshold reached. Stopping transmission", start: self.pipelineStartTime)
            self.isTransmitting = false
            self.stateLock.unlock()
        }
        hangoverWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func processAndSend(buffer: AVAudioPCMBuffer) {
        guard let secManager = self.securityManager else {
            logTime("🔴 processAndSend: securityManager is nil", start: pipelineStartTime)
            return
        }
        guard secManager.sessionKey != nil else {
            logTime("🔴 processAndSend: sessionKey is nil — handshake incomplete?", start: pipelineStartTime)
            return
        }
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            
            let samplesPerFrame: AVAudioFrameCount = 960
            let totalFrameLength: AVAudioFrameCount = buffer.frameLength
            var frameStart: AVAudioFrameCount = 0

            while frameStart < totalFrameLength {
                let remaining: AVAudioFrameCount = totalFrameLength - frameStart
                let currentFrameLength: AVAudioFrameCount = min(remaining, samplesPerFrame)

                guard let chunk = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: samplesPerFrame) else {
                    frameStart &+= currentFrameLength
                    continue
                }
                chunk.frameLength = currentFrameLength

                // Copy samples using floatChannelData (mono float32)
                if let srcChannels = buffer.floatChannelData, let dstChannels = chunk.floatChannelData {
                    // We assume mono (channel 0). If more channels are present, consider iterating channels.
                    let src = srcChannels[0].advanced(by: Int(frameStart))
                    let dst = dstChannels[0]
                    let byteCount = Int(currentFrameLength) * MemoryLayout<Float>.size
                    memcpy(dst, src, byteCount)
                } else {
                    // Fallback: if channel data is unavailable, skip this chunk safely
                    frameStart &+= currentFrameLength
                    continue
                }

                do {
                    var data = Data(count: 1500)
                    guard let encodedCount = try self.encoder?.encode(chunk, to: &data), encodedCount > 0 else {
                        frameStart &+= currentFrameLength
                        continue
                    }
                    let opusData = data.prefix(encodedCount)
                    let encryptedData = try secManager.encryptPayload(Data(opusData))
                    NotificationCenter.default.post(name: .sendUDP, object: encryptedData)
                } catch {
                    logTime("🔴 Chunk encode error: \(error)", start: self.pipelineStartTime)
                }

                frameStart &+= currentFrameLength
            }
        }
    }
    deinit {
        // Only remove the NotificationCenter observer here
        if let token = receivedObserver {
            NotificationCenter.default.removeObserver(token)
            receivedObserver = nil
        }
        // Optional safety cleanup (analyzer is already nil'd in endCall)
        analyzer?.removeAllRequests()
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

