// ContentView.swift
import SwiftUI
import os
import Combine

func logTime(_ message: String, start: CFAbsoluteTime? = nil) {
    let elapsed = start != nil ? String(format: "T+%dms", Int((CFAbsoluteTimeGetCurrent() - start!) * 1000)) : ""
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

    @State private var cancellables = Set<AnyCancellable>()
    @State private var pipelineStartTime: CFAbsoluteTime = 0

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
                        if !isCalling { startThePipeline() } else { stopThePipeline() }
                    } else {
                        if !isCalling { startThePipeline() }
                    }
                }) {
                    Text(buttonText).bold().padding()
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
                    .multilineTextAlignment(.center).padding(.horizontal)

                Button(action: { enrollDevice() }) {
                    Text(isEnrolling ? "Enrolling…" : "Enroll Device").bold().padding()
                }
                .buttonStyle(.borderedProminent).disabled(isEnrolling)

                if let err = enrollError {
                    Text(err).foregroundColor(.red).font(.footnote)
                }
            } else if serverReachable == false {
                Text("Server unreachable. Start your server.")
                    .multilineTextAlignment(.center).padding(.horizontal)
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
            
            // ✅ DEVICE: Pre-warm ML models at app launch (saves ~5s on call start)
            #if !targetEnvironment(simulator)
            Task {
                await MainActor.run {
                    audioManager.prepareAudioHardware()
                }
            }
            
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

            NotificationCenter.default.publisher(for: NSNotification.Name("StartAudioInternal"))
                .receive(on: RunLoop.main)
                .sink { [self] _ in self.handleStartAudioInternal() }
                .store(in: &cancellables)

            NotificationCenter.default.publisher(for: NSNotification.Name("EndAudioInternal"))
                .receive(on: RunLoop.main)
                .sink { [self] _ in self.handleEndAudioInternal() }
                .store(in: &cancellables)
            #endif
        }
        .onDisappear {
            cancellables.forEach { $0.cancel() }
            cancellables.removeAll()
        }
    }

    private func handleStartAudioInternal() {
        #if !targetEnvironment(simulator)
        logTime("🔔 handleStartAudioInternal received", start: pipelineStartTime)
        audioManager.setupAudioAfterActivation(pipelineStartTime: pipelineStartTime)
        #endif
    }

    private func handleEndAudioInternal() {
        #if !targetEnvironment(simulator)
        logTime("🔔 handleEndAudioInternal received", start: pipelineStartTime)
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
        pipelineStartTime = CFAbsoluteTimeGetCurrent()
        logTime("📞 [T+0ms] Start Call button tapped", start: pipelineStartTime)
        isCalling = true

        #if targetEnvironment(simulator)
        Task {
            do {
                audioManager.securityManager = securityManager
                udpManager.securityManager = securityManager
                audioManager.startAudio()
                
                let t2 = CFAbsoluteTimeGetCurrent()
                try await securityManager.performHandshake()
                logTime("🔐 Handshake complete", start: t2)

                udpManager.connect(host: AppConfig.resolvedServerHostname, port: 5555)
                logTime("🎉 Pipeline COMPLETE", start: pipelineStartTime)
            } catch {
                logTime("❌ Pipeline FAILED: \(error)", start: pipelineStartTime)
                stopThePipeline()
            }
        }
        #else
        let capturedAudio = audioManager
        let capturedSecurity = securityManager
        let capturedUDP = udpManager
        let capturedCall = callManager

        audioManager.onEngineStarted = {
            logTime("🔔 onEngineStarted FIRED — starting handshake", start: self.pipelineStartTime)
            Task { @MainActor in
                do {
                    let t2 = CFAbsoluteTimeGetCurrent()
                    try await capturedSecurity.performHandshake()
                    logTime("🔐 Handshake complete", start: t2)

                    capturedAudio.securityManager = capturedSecurity
                    capturedUDP.securityManager = capturedSecurity
                    capturedUDP.connect(host: AppConfig.resolvedServerHostname, port: 5555)
                    
                    logTime("📡 UDP connection ready", start: self.pipelineStartTime)

                    capturedCall.reportCallConnected()
                    logTime("🎉 Pipeline COMPLETE — Call Connected", start: self.pipelineStartTime)
                } catch {
                    logTime("❌ Post-activation setup FAILED: \(error)", start: self.pipelineStartTime)
                    capturedAudio.endCall()
                    capturedUDP.disconnect()
                    capturedCall.endCall()
                    capturedSecurity.clearSession()
                }
            }
        }

        Task {
            do {
                // ✅ Phase 1 already done at app launch — skip here!
                // await MainActor.run { audioManager.prepareAudioHardware() }
                
                let t0 = CFAbsoluteTimeGetCurrent()
                logTime("📞 CXTransaction requested", start: t0)
                try await callManager.startCall(handle: "BunServer")
                logTime("📞 callManager.startCall complete", start: t0)
            } catch {
                logTime("❌ Pipeline FAILED: \(error)", start: pipelineStartTime)
                audioManager.onEngineStarted = nil
                await MainActor.run { self.stopThePipeline() }
            }
        }
        #endif
    }

    func stopThePipeline() {
        logTime("🛑 Stopping pipeline...", start: pipelineStartTime)
        isCalling = false
        audioManager.endCall()
        udpManager.disconnect()
        
        #if !targetEnvironment(simulator)
        if callManager.currentCallUUID != nil {
            callManager.endCall()
        }
        #endif
        
        securityManager.clearSession()
        logTime("✅ Pipeline stopped", start: pipelineStartTime)
    }
}
