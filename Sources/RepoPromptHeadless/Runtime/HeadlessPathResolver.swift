import Foundation

struct HeadlessPathResolver {
    let roots: [HeadlessAllowedRoot]
    let fileManager: FileManager

    init(roots: [HeadlessAllowedRoot], fileManager: FileManager = .default) {
        self.roots = roots
        self.fileManager = fileManager
    }

    func resolve(_ input: String, requireExists: Bool = true) throws -> HeadlessResolvedPath {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HeadlessCommandError("Path must not be empty.", exitCode: 2)
        }
        guard !roots.isEmpty else {
            throw HeadlessCommandError("No roots are bound to the active headless workspace.", exitCode: 2)
        }

        if trimmed.hasPrefix("/") {
            return try resolvedAbsolute(URL(fileURLWithPath: trimmed), requireExists: requireExists)
        }

        if let prefixed = try resolveRootPrefixed(trimmed, requireExists: requireExists) {
            return prefixed
        }

        var matches: [HeadlessResolvedPath] = []
        for root in roots {
            let candidate = URL(fileURLWithPath: root.path, isDirectory: true)
                .appendingPathComponent(trimmed, isDirectory: false)
            do {
                let resolved = try resolvedCandidate(candidate, root: root, requireExists: requireExists)
                if !requireExists || fileManager.fileExists(atPath: resolved.url.path) {
                    matches.append(resolved)
                }
            } catch let error as HeadlessCommandError {
                if requireExists, error.exitCode == 2 {
                    continue
                }
                throw error
            }
        }

        switch matches.count {
        case 1:
            return matches[0]
        case 0:
            throw HeadlessCommandError("Path is not available under the active workspace roots: \(trimmed)", exitCode: 2)
        default:
            let roots = matches.map(\.root.name).joined(separator: ", ")
            throw HeadlessCommandError("Ambiguous relative path '\(trimmed)' matches multiple roots: \(roots). Prefix with RootName/ to disambiguate.", exitCode: 2)
        }
    }

    func resolveMany(_ inputs: [String], requireExists: Bool = true) throws -> [HeadlessResolvedPath] {
        try inputs.map { try resolve($0, requireExists: requireExists) }
    }

    private func resolveRootPrefixed(_ input: String, requireExists: Bool) throws -> HeadlessResolvedPath? {
        let parts = input.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = parts.first else {
            return nil
        }
        let token = String(first)
        guard let root = roots.first(where: { root in
            root.name == token || root.id.uuidString.caseInsensitiveCompare(token) == .orderedSame
        }) else {
            return nil
        }
        let rest = parts.dropFirst().map(String.init).joined(separator: "/")
        let base = URL(fileURLWithPath: root.path, isDirectory: true)
        let candidate = rest.isEmpty ? base : base.appendingPathComponent(rest, isDirectory: false)
        return try resolvedCandidate(candidate, root: root, requireExists: requireExists)
    }

    private func resolvedAbsolute(_ url: URL, requireExists: Bool) throws -> HeadlessResolvedPath {
        let standardized = url.standardizedFileURL
        let resolvedPath = HeadlessRootAccessPolicy.resolvedPath(for: standardized)
        let containingRoots = roots.filter { root in
            HeadlessRootAccessPolicy.path(resolvedPath, isContainedInOrEqualTo: root.resolvedPath)
        }
        guard let root = containingRoots.sorted(by: { $0.resolvedPath.count > $1.resolvedPath.count }).first else {
            throw HeadlessCommandError("Path is outside the active headless allowed roots: \(url.path)", exitCode: 2)
        }
        return try resolvedCandidate(standardized, root: root, requireExists: requireExists)
    }

    private func resolvedCandidate(_ candidate: URL, root: HeadlessAllowedRoot, requireExists: Bool) throws -> HeadlessResolvedPath {
        let standardized = candidate.standardizedFileURL
        let resolvedURL = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard HeadlessRootAccessPolicy.path(resolvedURL.path, isContainedInOrEqualTo: root.resolvedPath) else {
            throw HeadlessCommandError("Path resolves outside allowed root '\(root.name)': \(candidate.path)", exitCode: 2)
        }
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory)
        guard exists || !requireExists else {
            throw HeadlessCommandError("Path does not exist: \(candidate.path)", exitCode: 2)
        }
        let resourceValues = try? standardized.resourceValues(forKeys: [.isRegularFileKey])
        let relativePath = Self.relativePath(forResolvedPath: resolvedURL.path, rootResolvedPath: root.resolvedPath)
        let displayPath = relativePath.isEmpty ? root.name : "\(root.name)/\(relativePath)"
        return HeadlessResolvedPath(
            root: root,
            url: standardized,
            resolvedURL: resolvedURL,
            relativePath: relativePath,
            displayPath: displayPath,
            isDirectory: exists ? isDirectory.boolValue : false,
            isRegularFile: resourceValues?.isRegularFile ?? false
        )
    }

    static func relativePath(forResolvedPath path: String, rootResolvedPath: String) -> String {
        let root = URL(fileURLWithPath: rootResolvedPath).standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        guard candidate != root else {
            return ""
        }
        let prefix = root.hasSuffix("/") ? root : "\(root)/"
        guard candidate.hasPrefix(prefix) else {
            return candidate
        }
        return String(candidate.dropFirst(prefix.count))
    }
}
