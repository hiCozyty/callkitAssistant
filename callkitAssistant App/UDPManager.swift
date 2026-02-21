//UDPManager.swift
import Combine
import Foundation
import Network

class UDPManager: ObservableObject {
    var connection: NWConnection?
    let queue = DispatchQueue(label: "UDPQueue")

    private var sendObserver: NSObjectProtocol?
    private var heartbeatTimer: Timer?
    var securityManager: SecurityManager?

    func connect(host: String, port: UInt16) {
        disconnect()

        let hostObj = NWEndpoint.Host(host)
        let portObj = NWEndpoint.Port(rawValue: port)!

        // 1. Create custom UDP parameters
        let params = NWParameters.udp

        // 2. Set the Service Class to .interactiveVoice
        params.serviceClass = .interactiveVoice

        // 3. (Optional) Allow fast path to reduce overhead
        params.preferNoProxies = false  // Must be false for the iPhone proxy to work!

        // connection = NWConnection(host: hostObj, port: portObj, using: .udp)
        connection = NWConnection(host: hostObj, port: portObj, using: params)

        connection?.stateUpdateHandler = { [weak self] state in
            print("UDP Connection State: \(state)")
            if state == .ready {
                self?.startHeartbeat()
            }
        }

        sendObserver = NotificationCenter.default.addObserver(
            forName: .sendUDP,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let data = notification.object as? Data {
                self?.send(data: data)
            }
        }

        connection?.start(queue: queue)
        receiveLoop()
    }

    private func startHeartbeat() {
        stopHeartbeat()
        DispatchQueue.main.async {
            self.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) {
                [weak self] _ in
                guard let self = self,
                    let idData = self.securityManager?.sessionIdData
                else { return }

                // Heartbeat = SessionID (16 bytes) + 0x00 (1 byte)
                var heartbeatPacket = idData
                heartbeatPacket.append(0x00)

                self.send(data: heartbeatPacket)
                print("UDP: Heartbeat sent for \(idData.count) bytes")
            }
        }
    }

    // ADDED: Separate method for clarity
    private func stopHeartbeat() {
        DispatchQueue.main.async {
            self.heartbeatTimer?.invalidate()
            self.heartbeatTimer = nil
        }
    }

    func disconnect() {
        stopHeartbeat()

        if let observer = sendObserver {
            NotificationCenter.default.removeObserver(observer)
            sendObserver = nil
        }

        connection?.cancel()
        connection = nil
        print("UDP: Connection and observers cleared")
    }

    func send(data: Data) {
        connection?.send(
            content: data,
            completion: .contentProcessed({ error in
                if let error = error { print("UDP Send error: \(error)") }
            }))
    }

    private func receiveLoop() {
        connection?.receiveMessage { [weak self] (data, context, isComplete, error) in
            guard let self = self else { return }
            if let data = data {
                NotificationCenter.default.post(name: .receivedUDP, object: data)
            }
            if error == nil && self.connection != nil {
                self.receiveLoop()
            }
        }
    }

    // ADDED: Cleanup on deinit
    deinit {
        disconnect()
    }
}
