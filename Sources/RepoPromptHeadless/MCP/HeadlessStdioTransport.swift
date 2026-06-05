import Foundation

final class HeadlessStdioTransport {
    private let server: HeadlessMCPServer
    private let writer: HeadlessStdoutWriter

    init(server: HeadlessMCPServer, writer: HeadlessStdoutWriter) {
        self.server = server
        self.writer = writer
    }

    func run() async throws {
        var decoder = HeadlessNewlineFrameDecoder()
        while true {
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty {
                _ = await handle(events: decoder.finish())
                return
            }
            if await handle(events: decoder.append(chunk)) {
                return
            }
        }
    }

    private func handle(events: [HeadlessNewlineFrameDecoder.Event]) async -> Bool {
        for event in events {
            switch event {
            case let .frame(frame):
                let action = await server.handle(frame: frame)
                if let responseData = action.responseData {
                    await writer.write(responseData)
                }
                if action.shouldExit {
                    return true
                }
            case let .parseError(message):
                await writer.write(
                    HeadlessJSONRPC.errorResponse(
                        id: NSNull(),
                        code: -32700,
                        message: message
                    )
                )
            }
        }
        return false
    }
}
