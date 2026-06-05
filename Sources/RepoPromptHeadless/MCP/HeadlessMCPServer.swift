import Foundation

final class HeadlessMCPServer {
    private let configurationStore: HeadlessConfigurationStore
    private let host: HeadlessHost
    private let registry: HeadlessToolRegistry

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
            return requestError(hasID: hasID, id: id, code: -32600, message: "Only JSON-RPC 2.0 requests are supported.")
        }
        guard let method = object["method"] as? String, !method.isEmpty else {
            return requestError(hasID: hasID, id: id, code: -32600, message: "JSON-RPC request is missing a method.")
        }

        switch method {
        case "initialize":
            return requestResult(hasID: hasID, id: id, result: initializeResult())
        case "notifications/initialized":
            return HeadlessRPCAction(responseData: nil, shouldExit: false)
        case "ping":
            return requestResult(hasID: hasID, id: id, result: [:])
        case "tools/list":
            return requestResult(hasID: hasID, id: id, result: ["tools": registry.listDescriptors()])
        case "tools/call":
            guard let params = object["params"] as? [String: Any] else {
                return requestError(hasID: hasID, id: id, code: -32602, message: "tools/call requires params.")
            }
            guard let name = params["name"] as? String, !name.isEmpty else {
                return requestError(hasID: hasID, id: id, code: -32602, message: "tools/call requires params.name.")
            }
            let arguments: [String: Any]
            if let rawArguments = params["arguments"] {
                if rawArguments is NSNull {
                    arguments = [:]
                } else if let objectArguments = rawArguments as? [String: Any] {
                    arguments = objectArguments
                } else {
                    return requestError(hasID: hasID, id: id, code: -32602, message: "tools/call params.arguments must be an object when provided.")
                }
            } else {
                arguments = [:]
            }
            let result = await registry.call(name: name, arguments: arguments)
            return requestResult(hasID: hasID, id: id, result: result)
        case "shutdown":
            return requestResult(hasID: hasID, id: id, result: NSNull(), shouldExit: true)
        case "exit":
            if hasID {
                return requestResult(hasID: true, id: id, result: NSNull(), shouldExit: true)
            }
            return HeadlessRPCAction(responseData: nil, shouldExit: true)
        default:
            return requestError(hasID: hasID, id: id, code: -32601, message: "Method not found: \(method)")
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
}
