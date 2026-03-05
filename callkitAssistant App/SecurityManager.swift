//SecurityManager.swift
import Combine
import CryptoKit
import Foundation
import Security
import X509
import SwiftASN1
import WatchKit
import Network

// already enrolled? → skip discovery entirely, proceed normally
// not enrolled + on LAN? → discover, enroll, proceed
// not enrolled + not on LAN? → tell user they need to be on home network first

class SecurityManager: ObservableObject {
    @Published var sessionKey: SymmetricKey?
    private var sequenceNumber: UInt16 = 0
    private let keyTag = "com.myApp.voip.identity".data(using: .utf8)!
    private var currentSessionId: String?
    private var nonceSalt = Data(repeating: 0, count: 10)
    private let certTag = "com.myApp.voip.clientcert".data(using: .utf8)!
    private var inboundSequenceNumber: UInt16 = 0
    private let inboundSeqLock = NSLock()
    
    private var outboundNoncePrefix = Data(repeating: 0, count: 10)
    private var inboundNoncePrefix = Data(repeating: 0, count: 10)
    
    // Expose sessionId for UDP packets
    var sessionIdData: Data? {
        guard let sessionId = currentSessionId else { return nil }
        // Remove dashes so the hex string matches exactly what Bun expects
        let hexString = sessionId.replacingOccurrences(of: "-", with: "")
        
        // Convert hex string to raw 16 bytes
        var data = Data()
        var tempHex = hexString
        while !tempHex.isEmpty {
            let subIndex = tempHex.index(tempHex.startIndex, offsetBy: 2)
            let byteString = String(tempHex[..<subIndex])
            tempHex = String(tempHex[subIndex...])
            if let byte = UInt8(byteString, radix: 16) {
                data.append(byte)
            }
        }
        return data
    }
    
    private func deriveNoncePrefix(from key: SymmetricKey, direction: String) -> Data {
        let keyData = key.withUnsafeBytes { Data($0) }
        let input = keyData + Data(direction.utf8) + Data("nonce_v1".utf8)
        return Data(SHA256.hash(data: input).prefix(10))
    }

    func clearSession() {
        if let sessionId = currentSessionId {
            logTime("🔐 Notifying server of disconnect (sessionId: \(sessionId))")
            
            Task {
                do {
                    try await disconnectFromServer(
                        url: "http://\(AppConfig.serverHost):5556/auth/disconnect",
                        sessionId: sessionId
                    )
                    logTime("✅ Server disconnect notification SENT")
                } catch {
                    logTime("❌ Server disconnect notification FAILED: \(error)")
                }
            }
        }
        
        self.sessionKey = nil
        self.sequenceNumber = 0
        self.currentSessionId = nil
        logTime("🔐 Security: Session keys cleared.")
    }
    
    private func disconnectFromServer(url: String, sessionId: String) async throws {
        let host = AppConfig.serverHost
        let port: UInt16 = 5556
        
        guard let params = makeMTLSParameters() else {
            throw NSError(domain: "mTLS", code: -1, userInfo: [NSLocalizedDescriptionKey: "No identity"])
        }
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: params
            )
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let body = "{\"sessionId\":\"\(sessionId)\"}"
                    let http = "POST /auth/disconnect HTTP/1.1\r\nHost: \(host):5556\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: http.data(using: .utf8), completion: .contentProcessed({ _ in }))
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, _, _ in
                        connection.cancel()
                        continuation.resume()
                    }
                case .failed(let error):
                    continuation.resume(throwing: error)
                case .setup, .preparing, .waiting, .cancelled:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: DispatchQueue.global())
        }
    }
    private func makeMTLSParameters() -> NWParameters? {
        guard let identity = getIdentity() else { return nil }
        
        logTime("✅ mTLS: Got identity: \(identity)")
        
        let tlsOptions = NWProtocolTLS.Options()
        let secIdentity = sec_identity_create(identity)!
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)
        
        logTime("✅ mTLS: Set local identity, configuring verify block...")
        
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, trust, completionHandler in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            let crtPaths = Bundle.main.paths(forResourcesOfType: "crt", inDirectory: nil)
            guard let caCertPath = crtPaths.first(where: { $0.hasSuffix("ca.crt") }),
                  let caCertPEM = try? String(contentsOfFile: caCertPath, encoding: .utf8) else {
                completionHandler(false); return
            }
            let pemStripped = caCertPEM
                .components(separatedBy: "\n")
                .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
                .joined()
            guard let caCertData = Data(base64Encoded: pemStripped),
                  let caCert = SecCertificateCreateWithData(nil, caCertData as CFData) else {
                completionHandler(false); return
            }
            SecTrustSetAnchorCertificates(secTrust, [caCert] as CFArray)
            SecTrustSetAnchorCertificatesOnly(secTrust, true)
            var trustError: CFError?
            
            let result = SecTrustEvaluateWithError(secTrust, &trustError)
            
            if !result {
                logTime("❌ mTLS verify FAILED: \(trustError?.localizedDescription ?? "unknown error")")
                // Log certificate chain for debugging
                for _ in 0..<SecTrustGetCertificateCount(secTrust) {
                    if let certChain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate] {
                        for (i, cert) in certChain.enumerated() {
                            logTime("   Cert[\(i)]: \(SecCertificateCopySubjectSummary(cert) as String?)")
                        }
                    }
                }
            } else {
                logTime("✅ mTLS verify succeeded")
            }
            completionHandler(SecTrustEvaluateWithError(secTrust, &trustError))
        }, DispatchQueue.global())
        
        return NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
    }
    private func checkCertExists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certTag,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }
    
    func performHandshake() async throws {
        let serverURL = AppConfig.serverURL
        logTime("🔐 performHandshake entered — serverURL: \(serverURL)")
        
        if !checkCertExists() {
            let enrollURL = "http://\(AppConfig.resolvedServerHostname):5557"
            try await enrollIfNeeded(enrollURL: enrollURL)
        }
        
        let sessionKeyB64 = try await fetchSessionKey()
        guard let keyData = Data(base64Encoded: sessionKeyB64) else {
            throw NSError(domain: "SecurityManager", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid session key"])
        }
        self.setSessionKey(keyData)
    }
    func isEnrolled() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certTag,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }
    func enrollIfNeeded(enrollURL: String) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certTag,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess {
            return
        }
        let deviceName = "watch-\(WKInterfaceDevice.current().identifierForVendor?.uuidString ?? "unknown")"
        let keyTag = "com.myApp.voip.identity".data(using: .utf8)!
        
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
            ]
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        
        // Wrap it for swift-certificates
        let privateKeyCertificate = try Certificate.PrivateKey(secKey)
        
        
        let attributes = CertificateSigningRequest.Attributes() // remove try
        
        let csr = try CertificateSigningRequest(
            version: .v1,
            subject: DistinguishedName { CommonName(deviceName) }, // remove try
            privateKey: privateKeyCertificate,
            attributes: attributes,
            signatureAlgorithm: .ecdsaWithSHA256
        )
        
        let csrPEM = try csr.serializeAsPEM(discriminator: CertificateSigningRequest.defaultPEMDiscriminator).pemString
        
        var request = URLRequest(url: URL(string: "\(enrollURL)/enroll")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "csr": csrPEM,
            "enrollSecret": AppConfig.enrollSecret
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        let res = try JSONDecoder().decode(EnrollRes.self, from: data)
        
        // Strip PEM headers and decode base64 to get DER
        let pemString = res.cert
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        
        guard let derData = Data(base64Encoded: pemString),
              let cert = SecCertificateCreateWithData(nil, derData as CFData)
        else {
            throw NSError(domain: "Enroll", code: -2, userInfo: [NSLocalizedDescriptionKey: "PEM→DER conversion failed"])
        }
        
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certTag,
            kSecValueRef as String: cert,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        logTime("🔐 Cert stored, keychain status: \(addStatus)")
    }
    
    // private func getIdentity() -> SecIdentity? {
    //     let query: [String: Any] = [
    //         kSecClass as String: kSecClassIdentity,
    //         kSecReturnRef as String: true,
    //     ]
    //     var item: CFTypeRef?
    //     guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
    //     return (item as! SecIdentity)
    // }
    private func getIdentity() -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity, // Look for the "Pair"
            kSecAttrLabel as String: certTag,       // This MUST match your certTag
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        if status == errSecSuccess {
            return (item as! SecIdentity)
        } else {
            logTime("❌ Keychain: Could not find mTLS Identity. Status: \(status)")
            return nil
        }
    }
    
    nonisolated func getPublicKeyIdentifier() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: "com.myApp.voip.clientcert".data(using: .utf8)!,
            kSecReturnRef as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        let cert = item as! SecCertificate
        guard let pubKey = SecCertificateCopyKey(cert),
              let pubKeyData = SecKeyCopyExternalRepresentation(pubKey, nil) as Data?
        else { return nil }
        return SHA256.hash(data: pubKeyData).map { String(format: "%02x", $0) }.joined()
    }
    
    
    private func fetchSessionKey() async throws -> String {
        let host = AppConfig.serverHost
        let port: UInt16 = 5556
        
        guard let params = makeMTLSParameters() else {
            throw NSError(domain: "mTLS", code: -1, userInfo: [NSLocalizedDescriptionKey: "No identity"])
        }
        //for performance benching..
        let t0 = CFAbsoluteTimeGetCurrent()
        
        return try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: params
            )
            
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .preparing:
                    logTime("⏱ NWConnection preparing: \(Int((CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
                case .ready:
                    logTime("⏱ NWConnection ready (mTLS done): \(Int((CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
                    guard let self = self else { return }
                    let pubkey = self.getPublicKeyIdentifier() ?? ""
                    let body = "{\"deviceId\":\"\(pubkey)\"}"
                    let http = "POST /auth/session HTTP/1.1\r\nHost: \(host):5556\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: http.data(using: .utf8), completion: .contentProcessed({ _ in }))
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                        connection.cancel()
                        guard let data = data, let response = String(data: data, encoding: .utf8) else {
                            continuation.resume(throwing: NSError(domain: "mTLS", code: -3, userInfo: [NSLocalizedDescriptionKey: "No response"]))
                            return
                        }
                        guard let jsonStart = response.range(of: "\r\n\r\n") else {
                            continuation.resume(throwing: NSError(domain: "mTLS", code: -4, userInfo: [NSLocalizedDescriptionKey: "Bad response"]))
                            return
                        }
                        let jsonString = String(response[jsonStart.upperBound...])
                        guard let jsonData = jsonString.data(using: .utf8),
                              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: String],
                              let sessionId = dict["sessionId"],
                              let sessionKey = dict["sessionKey"] else {
                            continuation.resume(throwing: NSError(domain: "mTLS", code: -5, userInfo: [NSLocalizedDescriptionKey: "JSON decode failed"]))
                            return
                        }
                        self.currentSessionId = sessionId
                        continuation.resume(returning: sessionKey)
                    }
                case .failed(let error):
                    logTime("❌ NWConnection failed: \(error)")
                    continuation.resume(throwing: error)
                case .setup, .waiting, .cancelled:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: DispatchQueue.global())
        }
    }
    
    func setSessionKey(_ keyData: Data) {
        precondition(keyData.count == 16)
        
        // use raw key for both directions
        self.sessionKey = SymmetricKey(data: keyData)
        
        // Nonce prefixes still use raw key (directional separation)
        self.outboundNoncePrefix = deriveNoncePrefix(from: self.sessionKey!, direction: "client_to_server")
        self.inboundNoncePrefix  = deriveNoncePrefix(from: self.sessionKey!, direction: "server_to_client")
        
        self.sequenceNumber = 0
        self.inboundSequenceNumber = 0
        logTime("🔐 Session key set, nonce prefixes derived")
    }
    
    func encryptPayload(_ data: Data) throws -> Data {
        guard let key = sessionKey else {
            throw NSError(domain: "Security", code: -1, userInfo: [NSLocalizedDescriptionKey: "No Active Key"])
        }
        guard let sessionIdBytes = sessionIdData else {
            throw NSError(domain: "Security", code: -2, userInfo: [NSLocalizedDescriptionKey: "No Session ID"])
        }
        
        // ✅ Build nonce: derived prefix (10B) + sequence (2B BE)
        var nonceBytes = outboundNoncePrefix
        nonceBytes.append(withUnsafeBytes(of: sequenceNumber.bigEndian) { Data($0) })
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        
        let sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)
        
        var packet = Data()
        packet.append(sessionIdBytes)                                          // 16B
        packet.append(withUnsafeBytes(of: sequenceNumber.bigEndian) { Data($0) }) // 2B
        packet.append(sealedBox.combined!)                                     // 12B nonce + ciphertext + 16B tag
        
        sequenceNumber &+= 1
        return packet
    }
    func decryptServerPayload(_ packet: Data) throws -> Data {
        // === DEBUG LOGGING START ===
//        logTime("🔐 [DECRYPT] Packet: \(packet.count)B")
        
        guard packet.count >= 46 else {
            logTime("❌ [DECRYPT] Too short: \(packet.count)B")
            throw NSError(domain: "Security", code: -10, userInfo: [NSLocalizedDescriptionKey: "Packet too short"])
        }
        
        // Parse offsets
        let sessionIDEnd = 16
        let seqEnd = sessionIDEnd + 2
        let nonceEnd = seqEnd + 12
        let tagStart = packet.count - 16
        
        // Extract fields
//        let receivedSessionID = packet.subdata(in: 0..<16)
        let receivedSeq = packet.subdata(in: sessionIDEnd..<seqEnd).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        let nonceData = packet.subdata(in: seqEnd..<nonceEnd)
        let ciphertext = packet.subdata(in: nonceEnd..<tagStart)
        let authTag = packet.subdata(in: tagStart..<packet.count)
        
//        // Log hex for comparison
//        logTime("🔑 SessionID: received=\(receivedSessionID.map { String(format: "%02x", $0) }.joined())")
//        logTime("🔢 Seq: \(receivedSeq) (0x\(String(format: "%04x", receivedSeq)))")
//        logTime("🎲 Nonce: \(nonceData.map { String(format: "%02x", $0) }.joined())")
//        logTime("🔐 Ciphertext: \(ciphertext.count)B, Tag: \(authTag.map { String(format: "%02x", $0) }.joined())")
        
        guard let key = sessionKey else {
            logTime("❌ [DECRYPT] No session key")
            throw NSError(domain: "Security", code: -1, userInfo: [NSLocalizedDescriptionKey: "No Active Key"])
        }
        
        // Log key hex
        let keyHex = key.withUnsafeBytes { Array($0).map { String(format: "%02x", $0) }.joined() }
//        logTime("🗝️  Key: \(keyHex)")
        
        // === Build expected nonce for comparison ===
        var expectedNonce = inboundNoncePrefix
        expectedNonce.append(withUnsafeBytes(of: receivedSeq.bigEndian) { Data($0) })
        let expectedHex = expectedNonce.map { String(format: "%02x", $0) }.joined()
        let receivedHex = nonceData.map { String(format: "%02x", $0) }.joined()
        
//        logTime("🎲 Expected nonce prefix: \(inboundNoncePrefix.map { String(format: "%02x", $0) }.joined())")
//        logTime("🎲 Expected full nonce: \(expectedHex)")
//        logTime("🎲 Received full nonce: \(receivedHex)")
//        logTime("🎲 Nonce match: \(expectedHex == receivedHex ? "✅" : "❌")")
        
        // === Attempt decryption ===
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: authTag)
            let plaintext = try AES.GCM.open(sealedBox, using: key)
            
//            logTime("✅ [DECRYPT] SUCCESS — \(plaintext.count)B plaintext")
            inboundSeqLock.lock()
            if receivedSeq >= inboundSequenceNumber {
                inboundSequenceNumber = receivedSeq &+ 1
            }
            inboundSeqLock.unlock()
            return plaintext
            
        } catch let error as CryptoKitError {
            logTime("❌ [DECRYPT] CryptoKitError: \(error)")
            logTime("   Nonce match: \(expectedHex == receivedHex ? "✅" : "❌")")
            logTime("   inboundSequenceNumber: \(inboundSequenceNumber)")
            throw error
        }
        // === DEBUG LOGGING END ===
    }
}
