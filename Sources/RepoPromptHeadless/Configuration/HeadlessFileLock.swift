import Darwin
import Foundation

final class HeadlessFileLock {
    private let path: URL
    private var descriptor: Int32 = -1

    init(path: URL) {
        self.path = path
    }

    func lock() throws {
        if descriptor >= 0 {
            return
        }
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let fd = Darwin.open(path.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw HeadlessCommandError("Unable to open lock file \(path.path): \(String(cString: strerror(errno)))", exitCode: 2)
        }
        if flock(fd, LOCK_EX) != 0 {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw HeadlessCommandError("Unable to lock \(path.path): \(message)", exitCode: 2)
        }
        descriptor = fd
    }

    func unlock() {
        guard descriptor >= 0 else {
            return
        }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        unlock()
    }

    static func withExclusiveLock<T>(path: URL, _ body: () throws -> T) throws -> T {
        let lock = HeadlessFileLock(path: path)
        try lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
