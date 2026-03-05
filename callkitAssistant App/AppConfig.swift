import Foundation
enum AppConfig {
    static let serverURL = Bundle.main.object(forInfoDictionaryKey: "serverURL") as? String ?? "https://k2jxdme.duckdns.org"
    static let serverHost: String = URLComponents(string: serverURL)?.host ?? "k2jxdme.duckdns.org"
    static let localHostname = Bundle.main.object(forInfoDictionaryKey: "serverHostName") as? String ?? "fedora.local"
    static let enrollSecret = Bundle.main.object(forInfoDictionaryKey: "enrollSecret") as? String ?? "toothpick is bad for you"

    #if DEBUG
    static var resolvedServerHostname: String {
        return "192.168.1.132" // Hardcode your server IP for development
    }
    #else
    static var resolvedServerHostname: String {
        return localHostname // "fedora.local" for production
    }
    #endif

}
