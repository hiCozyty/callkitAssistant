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

        let params = NWParameters.udp
        params.serviceClass = .interactiveVoice
        params.allowLocalEndpointReuse = true
        params.preferNoProxies = false

        #if !targetEnvironment(simulator)
        params.requiredInterfaceType = .wifi
        #endif

        // ✅ Create connection FIRST, then set all handlers
        connection = NWConnection(host: hostObj, port: portObj, using: params)

        // ✅ pathUpdateHandler is now set on the actual connection object
        connection?.pathUpdateHandler = { path in
            logTime("🛜 Path status: \(path.status)")
            logTime("🛜 Interfaces: \(path.availableInterfaces.map { "\($0.name)/\($0.type)" })")
            logTime("🛜 Unsatisfied reason: \(String(describing: path.unsatisfiedReason))")
        }

        connection?.viabilityUpdateHandler = { isViable in
            logTime("📶 Connection viable: \(isViable)")
        }

        connection?.stateUpdateHandler = { [weak self] state in
            logTime("UDP Connection State: \(state)")
            switch state {
            case .ready:
                self?.startHeartbeat()
            case .waiting(let error):
                logTime("🟡 UDP waiting: \(error)")
            case .failed(let error):
                logTime("🔴 UDP failed: \(error)")
            case .cancelled:
                logTime("⚪ UDP cancelled")
            default:
                break
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
//                logTime("UDP: Heartbeat sent for \(idData.count) bytes")
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
        logTime("UDP: Connection and observers cleared")
    }

    func send(data: Data) {
        guard let connection = connection else {
            logTime("🔴 UDP send failed: no connection")
            return
        }
        guard connection.state == .ready else {
            logTime("🟡 UDP send skipped: state is \(connection.state), not ready")
            return
        }
        connection.send(
            content: data,
            completion: .contentProcessed({ error in
                if let error = error { logTime("UDP Send error: \(error)") }
            }))
    }

    private func receiveLoop() {
        connection?.receiveMessage { [weak self] (data, context, isComplete, error) in
            guard let self = self else { return }
            
            // ✅ LOG EVERY CALLBACK INVOCATION
            if let error = error {
                logTime("🔴 UDP receiveMessage error: \(error) (domain: \(error._domain), code: \(error._code))")
            } else {
//                logTime("📡← UDP received \(data?.count ?? 0)B")
            }
            
            if let data = data {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .receivedUDP, object: data)
                }
            }
            
            let state = self.connection?.state
            let shouldContinue: Bool
            
            switch state {
            case .ready, .preparing, .setup:
                shouldContinue = true
            case .waiting(let nwError), .failed(let nwError):
                // Log the error and stop recursing
                logTime("⚠️ UDP connection unhealthy: \(nwError)")
                shouldContinue = false
            case .cancelled, .none:
                shouldContinue = false
            @unknown default:
                shouldContinue = false
            }
            
            if shouldContinue {
                self.receiveLoop()
            } else {
                logTime("⚠️ UDP receiveLoop stopped - state: \(state ?? .cancelled)")
            }
        }
    }
    // ADDED: Cleanup on deinit
    deinit {
        disconnect()
    }
}
