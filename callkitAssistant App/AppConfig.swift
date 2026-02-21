import Foundation
enum AppConfig {
    static let serverURL = Bundle.main.object(forInfoDictionaryKey: "serverURL") as? String ?? ""
    static let serverHost: String = URLComponents(string: serverURL)?.host ?? ""
    static let localHostname = Bundle.main.object(forInfoDictionaryKey: "serverHostName") as? String ?? ""
    static let enrollSecret = Bundle.main.object(forInfoDictionaryKey: "enrollSecret") as? String ?? ""

    #if DEBUG
    static var resolvedServerHostname: String {
        return "192.168.1.160" // Hardcode your server IP for development
    }
    #else
    static var resolvedServerHostname: String {
        return localHostname // "fedora.local" for production
    }
    #endif

}
