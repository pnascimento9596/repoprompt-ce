import Foundation

final class HeadlessStdioTransport {
    private let server: HeadlessMCPServer
    private let writer: HeadlessStdoutWriter
    private let maximumFrameBytes = 1024 * 1024

    init(server: HeadlessMCPServer, writer: HeadlessStdoutWriter) {
        self.server = server
        self.writer = writer
    }

    func run() async throws {
        var buffer = Data()
        while true {
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty {
                if !buffer.isEmpty {
                    _ = try await handleLine(buffer)
                }
                return
            }
            buffer.append(chunk)
            guard buffer.count <= maximumFrameBytes else {
                await writer.write(HeadlessJSONRPC.errorResponse(id: NSNull(), code: -32700, message: "JSON-RPC frame exceeds headless maximum of \(maximumFrameBytes) bytes."))
                return
            }
            while let newlineRange = buffer.firstRange(of: Data([0x0A])) {
                let line = Data(buffer[..<newlineRange.lowerBound])
                buffer.removeSubrange(..<newlineRange.upperBound)
                if try await handleLine(line) {
                    return
                }
            }
        }
    }

    private func handleLine(_ rawLine: Data) async throws -> Bool {
        let line = normalizedLine(rawLine)
        guard !line.isEmpty else {
            return false
        }
        let action = await server.handle(frame: line)
        if let responseData = action.responseData {
            await writer.write(responseData)
        }
        return action.shouldExit
    }

    private func normalizedLine(_ rawLine: Data) -> Data {
        guard rawLine.last == 0x0D else {
            return rawLine
        }
        return rawLine.dropLast()
    }
}
