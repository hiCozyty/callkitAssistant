// ContentView.swift
import SwiftUI
import os
import Combine

// ✅ Ensure logTime is accessible globally (move to Utils.swift if preferred)
func logTime(_ message: String, start: CFAbsoluteTime? = nil) {
    let elapsed = start != nil ? String(format: "%.0fms", (CFAbsoluteTimeGetCurrent() - start!) * 1000) : ""
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    print("[\(timestamp)] \(message) \(elapsed)")
}

func deleteEnrollmentCert() {
    let certTag = "com.myApp.voip.clientcert".data(using: .utf8)!
    let query: [String: Any] = [
        kSecClass as String: kSecClassCertificate,
        kSecAttrLabel as String: certTag,
    ]
    let status = SecItemDelete(query as CFDictionary)
    logTime(status == errSecSuccess ? "✅ Cert deleted" : "⚠️ Status: \(status)")
}

struct ContentView: View {
    @StateObject private var audioManager = AudioStreamManager()
    @StateObject private var udpManager = UDPManager()
    @StateObject private var securityManager = SecurityManager()
    @StateObject private var callManager = CallManager()

    @State private var isCalling = false
    @State private var isEnrolled = false
    @State private var isEnrolling = false
    @State private var enrollError: String? = nil
    @State private var serverReachable: Bool? = nil

    // ✅ Declare cancellables
    @State private var cancellables = Set<AnyCancellable>()

    #if targetEnvironment(simulator)
    let isRunningOnSimulator = true
    #else
    let isRunningOnSimulator = false
    #endif

    private let appLaunchTime = CFAbsoluteTimeGetCurrent()

    private var buttonText: String {
        if isRunningOnSimulator {
            return isCalling ? "End Call" : "Start Call"
        } else {
            return isCalling ? "In Call…" : "Start Call"
        }
    }
    
    private var buttonColor: Color {
        if isRunningOnSimulator {
            return isCalling ? .red : .green
        } else {
            return isCalling ? .gray : .green
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            switch serverReachable {
            case nil:
                Text("Checking server…").font(.footnote).foregroundColor(.gray)
            case false:
                Text("⚠️ Server unreachable").font(.footnote).foregroundColor(.red)
            default:
                EmptyView()
            }

            if isEnrolled && serverReachable == true {
                Text("✅ Ready to call").font(.footnote).foregroundColor(.green)

                Button(action: {
                    if isRunningOnSimulator {
                        if !isCalling {
                            startThePipeline()
                        } else {
                            stopThePipeline()
                        }
                    } else {
                        if !isCalling {
                            startThePipeline()
                        }
                    }
                }) {
                    Text(buttonText)
                        .bold().padding()
                }
                .buttonStyle(.borderedProminent)
                .tint(buttonColor)
                .disabled(isRunningOnSimulator ? false : isCalling)

                Button("Reset Enrollment (Debug)") {
                    deleteEnrollmentCert()
                    isEnrolled = false
                }
                .foregroundColor(.gray).font(.footnote)

            } else if !isEnrolled && serverReachable == true {
                Text("Not enrolled. Connect to your home network first.")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button(action: { enrollDevice() }) {
                    Text(isEnrolling ? "Enrolling…" : "Enroll Device")
                        .bold().padding()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isEnrolling)

                if let err = enrollError {
                    Text(err).foregroundColor(.red).font(.footnote)
                }
            } else if serverReachable == false {
                Text("Server unreachable. Start your server.")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retry") {
                    Task { await checkServerReachability() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            logTime("🚀 App launched", start: appLaunchTime)

            let enrollCheckStart = CFAbsoluteTimeGetCurrent()
            isEnrolled = securityManager.isEnrolled()
            logTime("📋 Enrollment check complete: \(isEnrolled ? "ENROLLED" : "NOT ENROLLED")", start: enrollCheckStart)

            Task { await checkServerReachability() }
            
            // ✅ Device-only: Wire CallKit state to SwiftUI
            #if !targetEnvironment(simulator)
            callManager.$callState
                .receive(on: RunLoop.main)
                .sink { [self] (state: CallManager.CallState) in
                    switch state {
                    case .active:
                        self.isCalling = true
                    case .ended, .idle:
                        if self.isCalling {
                            self.isCalling = false
                            self.stopThePipeline()
                        }
                    default: break
                    }
                }
                .store(in: &cancellables)

            // ✅ Device-only: Listen for CallKit lifecycle notifications using Combine
            NotificationCenter.default.publisher(for: NSNotification.Name("StartAudioInternal"))
                .receive(on: RunLoop.main)
                .sink { [self] _ in
                    self.handleStartAudioInternal()
                }
                .store(in: &cancellables)

            NotificationCenter.default.publisher(for: NSNotification.Name("EndAudioInternal"))
                .receive(on: RunLoop.main)
                .sink { [self] _ in
                    self.handleEndAudioInternal()
                }
                .store(in: &cancellables)
            #endif
        }
        .onDisappear {
            cancellables.forEach { $0.cancel() }
            cancellables.removeAll()
        }
    }

    // ✅ Device: Called when CallKit fires didActivate
    private func handleStartAudioInternal() {
        #if !targetEnvironment(simulator)
        logTime("🔔 handleStartAudioInternal received")
        audioManager.setupAudioAfterActivation()
        #endif
    }

    private func handleEndAudioInternal() {
        #if !targetEnvironment(simulator)
        logTime("🔔 handleEndAudioInternal received")
        stopThePipeline()
        #endif
    }

    func checkServerReachability() async {
        let reachabilityStart = CFAbsoluteTimeGetCurrent()
        let hostname = AppConfig.resolvedServerHostname
        logTime("🔍 DEBUG: Using hostname = '\(hostname)'")

        await MainActor.run { serverReachable = nil }

        let url = URL(string: "http://\(hostname):5557/health")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = false
        config.allowsConstrainedNetworkAccess = false

        let wifiSession = URLSession(configuration: config)

        do {
            let (_, response) = try await wifiSession.data(for: request)
            let httpResp = response as? HTTPURLResponse
            let isSuccess = (httpResp?.statusCode == 200)
            logTime("📡 Server reachability: \(isSuccess ? "✅ REACHABLE" : "❌ UNREACHABLE")", start: reachabilityStart)
            await MainActor.run { serverReachable = isSuccess }
        } catch {
            logTime("❌ Server reachability: FAILED - \(error.localizedDescription)", start: reachabilityStart)
            await MainActor.run { serverReachable = false }
        }
    }

    func enrollDevice() {
        let enrollStart = CFAbsoluteTimeGetCurrent()
        logTime("🔐 Starting enrollment...", start: enrollStart)

        isEnrolling = true
        enrollError = nil
        Task {
            do {
                let enrollURL = "http://\(AppConfig.resolvedServerHostname):5557"
                try await securityManager.enrollIfNeeded(enrollURL: enrollURL)
                await MainActor.run {
                    isEnrolled = true
                    isEnrolling = false
                    logTime("🎉 Enrollment COMPLETE", start: enrollStart)
                }
            } catch {
                logTime("❌ Enrollment FAILED: \(error.localizedDescription)", start: enrollStart)
                await MainActor.run {
                    enrollError = "Enrollment failed: \(error.localizedDescription)"
                    isEnrolling = false
                }
            }
        }
    }

    func startThePipeline() {
        let pipelineStart = CFAbsoluteTimeGetCurrent()
        logTime("📞 Starting call pipeline...", start: pipelineStart)
        isCalling = true

        #if targetEnvironment(simulator)
        // 🖥️ SIMULATOR: Direct path (unchanged)
        Task {
            do {
                audioManager.securityManager = securityManager
                udpManager.securityManager = securityManager
                audioManager.startAudio()
                
                let t2 = CFAbsoluteTimeGetCurrent()
                try await securityManager.performHandshake()
                logTime("🔐 Handshake complete", start: t2)

                udpManager.connect(host: AppConfig.resolvedServerHostname, port: 5555)
                logTime("🎉 Pipeline COMPLETE", start: pipelineStart)
            } catch {
                logTime("❌ Pipeline FAILED: \(error)", start: pipelineStart)
                stopThePipeline()
            }
        }
        #else
        // 📱 DEVICE: CallKit path
        let capturedAudio = audioManager
        let capturedSecurity = securityManager
        let capturedUDP = udpManager
        let capturedCall = callManager

        // ✅ Set callback BEFORE starting call
        audioManager.onEngineStarted = {
            logTime("🔔 onEngineStarted FIRED — starting handshake")
            Task { @MainActor in
                do {
                    let t2 = CFAbsoluteTimeGetCurrent()
                    try await capturedSecurity.performHandshake()
                    logTime("🔐 Handshake complete", start: t2)

                    capturedAudio.securityManager = capturedSecurity
                    capturedUDP.securityManager = capturedSecurity
                    capturedUDP.connect(host: AppConfig.resolvedServerHostname, port: 5555)

                    capturedCall.reportCallConnected()
                    logTime("🎉 Pipeline COMPLETE", start: pipelineStart)
                } catch {
                    logTime("❌ Post-activation setup FAILED: \(error)", start: pipelineStart)
                    capturedAudio.endCall()
                    capturedUDP.disconnect()
                    capturedCall.endCall()
                    capturedSecurity.clearSession()
                }
            }
        }

        Task {
            do {
                // Phase 1: Slow DSP init BEFORE startCall
                await MainActor.run { audioManager.prepareAudioHardware() }
                
                // Phase 2: Start CallKit (will trigger didActivate → StartAudioInternal)
                let t0 = CFAbsoluteTimeGetCurrent()
                try await callManager.startCall(handle: "BunServer")
                logTime("📞 callManager.startCall complete", start: t0)
            } catch {
                logTime("❌ Pipeline FAILED: \(error)", start: pipelineStart)
                audioManager.onEngineStarted = nil
                await MainActor.run { self.stopThePipeline() }
            }
        }
        #endif
    }

    func stopThePipeline() {
        logTime("🛑 Stopping pipeline...")
        guard isCalling else {
            logTime("⚠️ stopThePipeline called but isCalling is false — ignoring")
            return
        }
        
        isCalling = false
        audioManager.endCall()
        udpManager.disconnect()
        
        #if !targetEnvironment(simulator)
        if callManager.currentCallUUID != nil {
            callManager.endCall()
        }
        #endif
        
        securityManager.clearSession()
        logTime("✅ Pipeline stopped")
    }
}
