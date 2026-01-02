import Foundation
import CryptoKit
import Security
import Combine

class SecurityManager: ObservableObject {
    @Published var sessionKey: SymmetricKey?
    private var sequenceNumber: UInt16 = 0
    private let keyTag = "com.yourapp.voip.identity".data(using: .utf8)!
    private var currentSessionId: String?
    private var lastServerURL: String?
    
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

    func clearSession() {
        // Notify server before clearing local state
        if let sessionId = currentSessionId, let baseURL = lastServerURL {
            Task {
                try? await disconnectFromServer(url: "\(baseURL)/auth/disconnect", sessionId: sessionId)
            }
        }
        
        DispatchQueue.main.async {
            self.sessionKey = nil
            self.sequenceNumber = 0
            self.currentSessionId = nil
            print("🔐 Security: Session keys cleared.")
        }
    }
    
    private func disconnectFromServer(url: String, sessionId: String) async throws {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["sessionId": sessionId])
        
        let (_, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            print("✅ Server notified of disconnect")
        }
    }
    
    // MARK: - Handshake Entry Point
    func performHandshake(serverURL: String) async throws {
        self.lastServerURL = serverURL
        
        // 1. Get Nonce from server
        let (nonce, sessionId) = try await fetchNonce(url: "\(serverURL)/auth/none")
        self.currentSessionId = sessionId
        
        // 2. Sign the nonce with Secure Enclave
        let signature = try signNonce(nonce)
        let pubKey = try getOrCreatePublicKey()
        
        // 3. Verify with server and get Session Key
        let sessionKeyB64 = try await verifyWithServer(
            url: "\(serverURL)/auth/verify",
            sessionId: sessionId,
            signature: signature,
            pubKey: pubKey
        )
        
        guard let keyData = Data(base64Encoded: sessionKeyB64) else {
            throw NSError(domain: "SecurityManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid session key format"])
        }
        
        self.setSessionKey(keyData)
    }

    // MARK: - Crypto Logic
    func getOrCreatePublicKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecReturnRef as String: true
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        if status == errSecSuccess {
            let key = item as! SecKey
            var error: Unmanaged<CFError>?
            guard let publicKey = SecKeyCopyPublicKey(key),
                  let data = SecKeyCopyExternalRepresentation(publicKey, &error) else {
                throw error!.takeRetainedValue() as Error
            }
            return data as Data
        } else {
            // Create hardware-bound P256 key
            let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                .privateKeyUsage,
                nil
            )!
            
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256,
                kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
                kSecPrivateKeyAttrs as String: [
                    kSecAttrIsPermanent as String: true,
                    kSecAttrApplicationTag as String: keyTag,
                    kSecAttrAccessControl as String: access
                ]
            ]
            
            var error: Unmanaged<CFError>?
            guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
                throw error!.takeRetainedValue() as Error
            }
            
            let publicKey = SecKeyCopyPublicKey(privateKey)!
            
            guard let data = SecKeyCopyExternalRepresentation(publicKey, &error) else {
                throw error!.takeRetainedValue() as Error
            }
            return data as Data
        }
    }

    func signNonce(_ nonce: Data) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecReturnRef as String: true
        ]
        
        var item: CFTypeRef?
        SecItemCopyMatching(query as CFDictionary, &item)
        let privateKey = item as! SecKey
        
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            nonce as CFData,
            &error
        ) else {
            throw error!.takeRetainedValue() as Error
        }
        return signature as Data
    }

    func setSessionKey(_ keyData: Data) {
        self.sessionKey = SymmetricKey(data: keyData)
        self.sequenceNumber = 0
    }

    func encryptPayload(_ data: Data) throws -> Data {
        guard let key = sessionKey else {
            throw NSError(domain: "Security", code: -1, userInfo: [NSLocalizedDescriptionKey: "No Active Key"])
        }
        
        guard let sessionIdBytes = sessionIdData else {
            throw NSError(domain: "Security", code: -2, userInfo: [NSLocalizedDescriptionKey: "No Session ID"])
        }
        
        // Create nonce with sequence number
        var nonceBytes = Data(count: 12)
        withUnsafeBytes(of: sequenceNumber.bigEndian) { nonceBytes.replaceSubrange(0..<2, with: $0) }
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        
        let sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)
        
        var packet = Data()
        // 1. SessionId (16 bytes)
        packet.append(sessionIdBytes)
        // 2. Sequence Number (2 bytes)
        packet.append(withUnsafeBytes(of: sequenceNumber.bigEndian) { Data($0) })
        // 3. Combined box (Nonce + Ciphertext + Tag)
        packet.append(sealedBox.combined!)
        
        sequenceNumber &+= 1
        return packet
    }

    // MARK: - Networking
    private func fetchNonce(url: String) async throws -> (Data, String) {
        let (data, _) = try await URLSession.shared.data(from: URL(string: url)!)
        let res = try JSONDecoder().decode(NonceRes.self, from: data)
        return (Data(base64Encoded: res.nonce)!, res.sessionId)
    }

    private func verifyWithServer(url: String, sessionId: String, signature: Data, pubKey: Data) async throws -> String {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "sessionId": sessionId,
            "signature": signature.base64EncodedString(),
            "pubkey": pubKey.base64EncodedString()
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let res = try JSONDecoder().decode(VerifyRes.self, from: data)
        return res.sessionKey
    }
}

struct NonceRes: Codable { let sessionId: String; let nonce: String }
struct VerifyRes: Codable { let sessionKey: String }
