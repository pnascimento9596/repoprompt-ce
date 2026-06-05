import Foundation

final class HeadlessMCPServer {
    private enum LifecycleState {
        case uninitialized
        case awaitingInitializedNotification
        case ready
        case shutdown
    }

    private let configurationStore: HeadlessConfigurationStore
    private let host: HeadlessHost
    private let registry: HeadlessToolRegistry
    private var lifecycleState: LifecycleState = .uninitialized

    init(configurationStore: HeadlessConfigurationStore) {
        self.configurationStore = configurationStore
        host = HeadlessHost(configurationStore: configurationStore)
        registry = HeadlessToolRegistry(host: host)
    }

    func handle(frame: Data) async -> HeadlessRPCAction {
        do {
            let object = try HeadlessJSONRPC.requestObject(from: frame)
            return await handle(object: object)
        } catch let error as HeadlessJSONRPCError {
            return HeadlessRPCAction(
                responseData: HeadlessJSONRPC.errorResponse(id: NSNull(), code: -32600, message: error.localizedDescription),
                shouldExit: false
            )
        } catch {
            return HeadlessRPCAction(
                responseData: HeadlessJSONRPC.errorResponse(id: NSNull(), code: -32700, message: "Parse error: \(error.localizedDescription)"),
                shouldExit: false
            )
        }
    }

    private func handle(object: [String: Any]) async -> HeadlessRPCAction {
        let hasID = object.keys.contains("id")
        let id = object["id"] ?? NSNull()
        guard object["jsonrpc"] as? String == "2.0" else {
            return invalidRequest(id: hasID ? id : NSNull(), message: "Only JSON-RPC 2.0 requests are supported.")
        }
        guard let method = object["method"] as? String, !method.isEmpty else {
            return invalidRequest(id: hasID ? id : NSNull(), message: "JSON-RPC request is missing a method.")
        }

        switch HeadlessJSONRPC.messageKind(for: object) {
        case .notification:
            return handleNotification(method: method)
        case let .request(requestID):
            return await handleRequest(method: method, id: requestID, object: object)
        }
    }

    private func handleNotification(method: String) -> HeadlessRPCAction {
        switch method {
        case "notifications/initialized":
            if lifecycleState == .awaitingInitializedNotification {
                lifecycleState = .ready
            }
            return HeadlessRPCAction(responseData: nil, shouldExit: false)
        case "exit":
            return HeadlessRPCAction(responseData: nil, shouldExit: lifecycleState == .shutdown)
        default:
            // MCP methods other than notifications/initialized and exit are request-only.
            // Unknown notifications are also ignored per JSON-RPC notification semantics.
            return HeadlessRPCAction(responseData: nil, shouldExit: false)
        }
    }

    private func handleRequest(method: String, id: Any, object: [String: Any]) async -> HeadlessRPCAction {
        if lifecycleState == .shutdown {
            return requestError(
                hasID: true,
                id: id,
                code: -32600,
                message: "Server has shut down and no longer accepts requests."
            )
        }

        switch method {
        case "notifications/initialized":
            return requestError(
                hasID: true,
                id: id,
                code: -32600,
                message: "notifications/initialized must be sent as a notification without an id."
            )
        case "exit":
            return requestError(
                hasID: true,
                id: id,
                code: -32600,
                message: "exit must be sent as a notification without an id."
            )
        case "initialize":
            guard lifecycleState == .uninitialized else {
                return requestError(
                    hasID: true,
                    id: id,
                    code: -32600,
                    message: "initialize may only be sent once."
                )
            }
            guard validInitializeParams(object["params"]) else {
                return requestError(
                    hasID: true,
                    id: id,
                    code: -32602,
                    message: "initialize requires params.protocolVersion, params.capabilities, and params.clientInfo with non-empty name and version."
                )
            }
            lifecycleState = .awaitingInitializedNotification
            return requestResult(hasID: true, id: id, result: initializeResult())
        default:
            guard lifecycleState == .ready else {
                return requestError(
                    hasID: true,
                    id: id,
                    code: -32002,
                    message: "Server not initialized. Send initialize, then notifications/initialized."
                )
            }
            return await executeReadyRequest(method: method, id: id, object: object)
        }
    }

    private func executeReadyRequest(method: String, id: Any, object: [String: Any]) async -> HeadlessRPCAction {
        switch method {
        case "ping":
            return requestResult(hasID: true, id: id, result: [:])
        case "tools/list":
            return requestResult(hasID: true, id: id, result: ["tools": registry.listDescriptors()])
        case "tools/call":
            guard let params = object["params"] as? [String: Any] else {
                return requestError(hasID: true, id: id, code: -32602, message: "tools/call requires params.")
            }
            guard let name = params["name"] as? String, !name.isEmpty else {
                return requestError(hasID: true, id: id, code: -32602, message: "tools/call requires params.name.")
            }
            let arguments: [String: Any]
            if let rawArguments = params["arguments"] {
                if rawArguments is NSNull {
                    arguments = [:]
                } else if let objectArguments = rawArguments as? [String: Any] {
                    arguments = objectArguments
                } else {
                    return requestError(hasID: true, id: id, code: -32602, message: "tools/call params.arguments must be an object when provided.")
                }
            } else {
                arguments = [:]
            }
            let result = await registry.call(name: name, arguments: arguments)
            return requestResult(hasID: true, id: id, result: result)
        case "shutdown":
            lifecycleState = .shutdown
            return requestResult(hasID: true, id: id, result: NSNull())
        default:
            return requestError(hasID: true, id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func initializeResult() -> [String: Any] {
        let configuredRootCount = (try? configurationStore.loadOrCreate().allowedRoots.count) ?? 0
        return [
            "protocolVersion": HeadlessVersion.mcpProtocolVersion,
            "capabilities": [
                "tools": [:]
            ],
            "serverInfo": [
                "name": HeadlessVersion.displayName,
                "version": HeadlessVersion.marketingVersion
            ],
            "instructions": "RepoPrompt Headless is running the standalone read-oriented safe profile over direct stdio. Configure allowed roots with `repoprompt-headless config roots add /absolute/path --name NAME`. Only bind_context, constrained manage_workspaces, manage_selection, workspace_context, get_file_tree, get_code_structure, read_file, file_search, and prompt are enabled.",
            "headless": [
                "configuredRootCount": configuredRootCount,
                "stateDirectory": configurationStore.paths.rootDirectory.path,
                "safeToolsEnabled": true
            ]
        ]
    }

    private func requestResult(hasID: Bool, id: Any, result: Any, shouldExit: Bool = false) -> HeadlessRPCAction {
        guard hasID else {
            return HeadlessRPCAction(responseData: nil, shouldExit: shouldExit)
        }
        return HeadlessRPCAction(responseData: HeadlessJSONRPC.response(id: id, result: result), shouldExit: shouldExit)
    }

    private func requestError(hasID: Bool, id: Any, code: Int, message: String) -> HeadlessRPCAction {
        guard hasID else {
            return HeadlessRPCAction(responseData: nil, shouldExit: false)
        }
        return HeadlessRPCAction(responseData: HeadlessJSONRPC.errorResponse(id: id, code: code, message: message), shouldExit: false)
    }

    private func invalidRequest(id: Any, message: String) -> HeadlessRPCAction {
        HeadlessRPCAction(
            responseData: HeadlessJSONRPC.errorResponse(id: id, code: -32600, message: message),
            shouldExit: false
        )
    }

    private func validInitializeParams(_ rawParams: Any?) -> Bool {
        guard let params = rawParams as? [String: Any],
              let protocolVersion = params["protocolVersion"] as? String,
              !protocolVersion.isEmpty,
              params["capabilities"] is [String: Any],
              let clientInfo = params["clientInfo"] as? [String: Any],
              let clientName = clientInfo["name"] as? String,
              !clientName.isEmpty,
              let clientVersion = clientInfo["version"] as? String,
              !clientVersion.isEmpty
        else {
            return false
        }
        return true
    }
}
