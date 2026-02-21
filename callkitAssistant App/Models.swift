
struct EnrollRes: Codable, Sendable { let cert: String }
struct SessionRes: Codable, Sendable { let sessionId: String; let sessionKey: String }
