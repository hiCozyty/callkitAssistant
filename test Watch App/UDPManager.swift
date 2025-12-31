
import Foundation
import Network

class UDPManager {
    var connection: NWConnection?
    let queue = DispatchQueue(label: "UDPQueue")

    func connect(host: String, port: UInt16) {
        let hostObj = NWEndpoint.Host(host)
        let portObj = NWEndpoint.Port(rawValue: port)!
        
        connection = NWConnection(host: hostObj, port: portObj, using: .udp)
        
        connection?.stateUpdateHandler = { state in
            print("UDP Connection State: \(state)")
        }
        
        // Listen for data to SEND from the Audio Manager
        NotificationCenter.default.addObserver(forName: .sendUDP, object: nil, queue: .main) { notification in
            if let data = notification.object as? Data {
                self.send(data: data)
            }
        }
        
        connection?.start(queue: queue)
        receiveLoop()
    }

    func send(data: Data) {
        connection?.send(content: data, completion: .contentProcessed({ error in
            if let error = error { print("Send error: \(error)") }
        }))
    }

    private func receiveLoop() {
        connection?.receiveMessage { (data, context, isComplete, error) in
            if let data = data {
                // Send the data back to the Audio manager to be played
                NotificationCenter.default.post(name: .receivedUDP, object: data)
            }
            if error == nil {
                self.receiveLoop()
            }
        }
    }
}
