import CoreServices
import Foundation

final class WorkspaceRootCreationReceiptCoordinator: @unchecked Sendable {
    final class Session: @unchecked Sendable {
        fileprivate let recorder: Recorder
        fileprivate let stream: FSEventStreamRef?
        fileprivate let queue: DispatchQueue
        fileprivate let startedAtUptimeNanoseconds: UInt64
        fileprivate let startEventID: FSEventStreamEventId
        fileprivate let streamStarted: Bool

        fileprivate init(
            recorder: Recorder,
            stream: FSEventStreamRef?,
            queue: DispatchQueue,
            startedAtUptimeNanoseconds: UInt64,
            startEventID: FSEventStreamEventId,
            streamStarted: Bool
        ) {
            self.recorder = recorder
            self.stream = stream
            self.queue = queue
            self.startedAtUptimeNanoseconds = startedAtUptimeNanoseconds
            self.startEventID = startEventID
            self.streamStarted = streamStarted
        }
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private let standardizedDestinationPath: String
        private var relativePaths = Set<String>()
        private var affectedDirectories = Set<String>()
        private var latestEventID: UInt64 = 0
        private var hadGap = false
        private var hadDrop = false
        private var overflowed = false

        init(destinationPath: String) {
            standardizedDestinationPath = StandardizedPath.absolute(destinationPath)
        }

        func accept(path rawPath: String, flags: FSEventStreamEventFlags, eventID: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            // Stream-wide and parent/root gap flags invalidate the interval even
            // when their reported path is outside the destination subtree.
            latestEventID = max(latestEventID, eventID)
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
                || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0
                || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
            {
                hadGap = true
            }
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0
                || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0
            {
                hadDrop = true
            }
            let path = StandardizedPath.absolute(rawPath)
            guard path == standardizedDestinationPath || path.hasPrefix(standardizedDestinationPath + "/") else {
                return
            }
            let relativePath = path == standardizedDestinationPath
                ? ""
                : String(path.dropFirst(standardizedDestinationPath.count + 1))
            let standardizedRelativePath = StandardizedPath.relative(relativePath)
            if !relativePaths.contains(standardizedRelativePath),
               relativePaths.count >= GitWorktreeCreationWitnessCoverage.maximumEventCount
            {
                overflowed = true
                return
            }
            relativePaths.insert(standardizedRelativePath)
            let rawDirectory = relativePath.isEmpty ? "" : (relativePath as NSString).deletingLastPathComponent
            let directory = rawDirectory == "." ? "" : StandardizedPath.relative(rawDirectory)
            if !affectedDirectories.contains(directory),
               affectedDirectories.count >= GitWorktreeCreationWitnessCoverage.maximumAffectedDirectoryCount
            {
                overflowed = true
                return
            }
            affectedDirectories.insert(directory)
        }

        func snapshot() -> (
            paths: [String],
            directories: [String],
            latestEventID: UInt64,
            hadGap: Bool,
            hadDrop: Bool,
            overflowed: Bool
        ) {
            lock.lock()
            defer { lock.unlock() }
            return (
                relativePaths.sorted(),
                affectedDirectories.sorted(),
                latestEventID,
                hadGap,
                hadDrop,
                overflowed
            )
        }
    }

    func start(destinationURL: URL) -> Session {
        let destination = destinationURL.standardizedFileURL
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        let recorder = Recorder(destinationPath: destination.path)
        let queue = DispatchQueue(label: "com.repoprompt.worktree-creation-witness.\(UUID().uuidString)")
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(recorder).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info, count > 0 else { return }
            let recorder = Unmanaged<Recorder>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue()
            let safeCount = min(Int(count), CFArrayGetCount(array))
            for index in 0 ..< safeCount {
                guard let raw = CFArrayGetValueAtIndex(array, index) else { continue }
                let value = unsafeBitCast(raw, to: CFTypeRef.self)
                guard CFGetTypeID(value) == CFStringGetTypeID() else { continue }
                let path = unsafeBitCast(raw, to: CFString.self) as String
                recorder.accept(path: path, flags: flags[index], eventID: ids[index])
            }
        }
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [parent.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.01,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagNoDefer
            )
        ) else {
            return Session(
                recorder: recorder,
                stream: nil,
                queue: queue,
                startedAtUptimeNanoseconds: startedAt,
                startEventID: 0,
                streamStarted: false
            )
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        let started = FSEventStreamStart(stream)
        if started {
            FSEventStreamFlushSync(stream)
        }
        return Session(
            recorder: recorder,
            stream: stream,
            queue: queue,
            startedAtUptimeNanoseconds: startedAt,
            startEventID: started ? FSEventStreamGetLatestEventId(stream) : 0,
            streamStarted: started
        )
    }

    func finish(_ session: Session) -> GitWorktreeCreationWitnessCoverage {
        let endedAt = DispatchTime.now().uptimeNanoseconds
        let endEventID: UInt64
        if let stream = session.stream {
            if session.streamStarted {
                FSEventStreamFlushSync(stream)
                session.queue.sync {}
                endEventID = FSEventStreamGetLatestEventId(stream)
                FSEventStreamStop(stream)
            } else {
                endEventID = 0
            }
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        } else {
            endEventID = 0
        }
        let snapshot = session.recorder.snapshot()
        let maximumLifetimeNanoseconds = UInt64(60 * NSEC_PER_SEC)
        let exceededLifetime = endedAt < session.startedAtUptimeNanoseconds
            || endedAt - session.startedAtUptimeNanoseconds > maximumLifetimeNanoseconds
        return GitWorktreeCreationWitnessCoverage(
            startedAtUptimeNanoseconds: session.startedAtUptimeNanoseconds,
            endedAtUptimeNanoseconds: endedAt,
            startEventID: session.startEventID,
            endEventID: max(session.startEventID, max(endEventID, snapshot.latestEventID)),
            destinationRelativePaths: snapshot.paths,
            affectedDestinationRelativeDirectories: snapshot.directories,
            streamStartedBeforeMutation: session.streamStarted,
            streamEndedAfterInitialization: session.streamStarted,
            hadGap: snapshot.hadGap || exceededLifetime,
            hadDrop: snapshot.hadDrop,
            overflowed: snapshot.overflowed
        )
    }
}
