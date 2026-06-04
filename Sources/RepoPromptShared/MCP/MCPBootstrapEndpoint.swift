import Foundation

/// Neutral derivation of the app-proxy bootstrap socket endpoint.
/// Callers remain responsible for supplying their local process user ID and
/// for any directory creation or logging policy.
public enum MCPBootstrapEndpoint {
    public static let socketDirectoryName = "repoprompt-ce-mcp"
    public static let socketVersion = 6

    public static var bootstrapSocketName: String {
        "repoprompt-ce-\(socketVersion).sock"
    }

    public static func socketDirectoryURL(uid: UInt32) -> URL {
        URL(fileURLWithPath: "/tmp/\(socketDirectoryName)-\(uid)", isDirectory: true)
    }

    public static func bootstrapSocketURL(uid: UInt32) -> URL {
        socketDirectoryURL(uid: uid).appendingPathComponent(bootstrapSocketName, isDirectory: false)
    }
}
