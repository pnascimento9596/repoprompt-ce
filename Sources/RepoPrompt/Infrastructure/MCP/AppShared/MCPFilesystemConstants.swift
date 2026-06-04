import Foundation
import RepoPromptShared

// MARK: - MCP Debug Logging

#if DEBUG
    private var mcpFilesystemConstantsDebugLoggingEnabled = false
    private func mcpFilesystemConstantsDebugLog(_ message: @autoclosure () -> String) {
        guard mcpFilesystemConstantsDebugLoggingEnabled else { return }
        print("[MCPFilesystemConstants] \(message())")
    }
#else
    private func mcpFilesystemConstantsDebugLog(_ message: @autoclosure () -> String) {}
#endif

/// Centralized debug logging control for MCP transport layer.
/// Set flags to false to reduce console spam.
enum MCPDebugLogging {
    private static var envDebugEnabled: Bool {
        ProcessInfo.processInfo.environment["REPOPROMPT_MCP_DEBUG"] == "1"
    }

    /// Log transport-level details (send/receive byte counts, message previews)
    static var transportVerbose = envDebugEnabled

    /// Log connection lifecycle events (connect, disconnect, EOF)
    static var connectionLifecycle = envDebugEnabled

    /// Log routing decisions and tab context binding
    static var routing = envDebugEnabled

    /// Log all debug messages (master switch - overrides individual flags when false)
    static var enabled = envDebugEnabled
}

/// Logs MCP transport-level debug messages when enabled.
@inline(__always)
func mcpTransportLog(_ message: @autoclosure () -> String) {
    #if DEBUG
        if MCPDebugLogging.enabled, MCPDebugLogging.transportVerbose {
            print("[MCPTransport] \(message())")
            fflush(stdout)
        }
    #endif
}

/// Logs MCP connection lifecycle debug messages when enabled.
@inline(__always)
func mcpConnectionLog(_ message: @autoclosure () -> String) {
    #if DEBUG
        if MCPDebugLogging.enabled, MCPDebugLogging.connectionLifecycle {
            print("[MCPConnection] \(message())")
            fflush(stdout)
        }
    #endif
}

/// Logs MCP routing debug messages when enabled.
@inline(__always)
func mcpRoutingDebugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
        if MCPDebugLogging.enabled, MCPDebugLogging.routing {
            print("[MCPRouting] \(message())")
        }
    #endif
}

enum MCPFilesystemConstants {
    /// UNIX domain socket transport.
    /// Current CE bootstrap socket is placed in a per-user /tmp directory.
    /// sun_path limit is 104 bytes - typical path is ~40 bytes, well under limit.
    static let socketDirName = MCPBootstrapEndpoint.socketDirectoryName

    /// Returns the primary socket directory URL in /tmp.
    /// Uses /tmp/repoprompt-ce-mcp-{uid}/ which:
    /// - Is accessible by external sandboxed apps (Claude Desktop, Cursor, etc.)
    /// - Per-user suffix prevents conflicts between users
    /// - Is a well-known, stable path (not containerized per-app)
    static func socketDirectoryURL() -> URL {
        MCPBootstrapEndpoint.socketDirectoryURL(uid: getuid())
    }

    /// Creates the socket directory with secure permissions (0700)
    /// - Returns: true if directory exists or was created successfully
    @discardableResult
    static func ensureSocketDirectoryExists() -> Bool {
        let url = socketDirectoryURL()
        let fm = FileManager.default

        if fm.fileExists(atPath: url.path) {
            return true
        }

        do {
            // Create with owner-only permissions for security
            try fm.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return true
        } catch {
            mcpFilesystemConstantsDebugLog("Failed to create socket directory: \(error)")
            return false
        }
    }

    // MARK: - Bootstrap Socket (Single App-Owned Socket)

    /// Name of the single bootstrap socket owned by the app.
    /// CLI connects to this socket for all MCP communication.
    ///
    /// CE socket naming scheme:
    /// - `repoprompt-ce-{version}.sock`
    ///
    /// Keep path short due to sun_path 104-byte limit.
    static let socketVersion = MCPBootstrapEndpoint.socketVersion

    static var bootstrapSocketName: String {
        MCPBootstrapEndpoint.bootstrapSocketName
    }

    /// Returns the bootstrap socket URL.
    /// This is a single well-known socket that the app listens on.
    /// CLI connects to this socket to initiate MCP sessions.
    static func bootstrapSocketURL() -> URL {
        MCPBootstrapEndpoint.bootstrapSocketURL(uid: getuid())
    }

    // MARK: - External Client Events Directory

    /// Directory for external client error events.
    /// Gated by build flavor and socket version so different app versions don't cross-pollinate.
    /// e.g. "MCPEvents-6" for release, "MCPEvents-D-6" for debug
    static func eventsDirectoryURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dirname = "MCPEvents-CE-\(socketVersion)"
        return appSupport.appendingPathComponent("RepoPrompt CE/\(dirname)", isDirectory: true)
    }
}
