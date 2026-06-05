import Foundation

struct HeadlessSearchResult {
    var summary: String
    var structured: [String: Any]
}

final class HeadlessSearchService {
    private let catalog: HeadlessFileCatalog
    private let secureFileAccess: HeadlessSecureFileAccess
    private let maxCatalogEntries: Int
    private let maxReadableBytes = 2 * 1024 * 1024

    init(
        catalog: HeadlessFileCatalog = HeadlessFileCatalog(),
        secureFileAccess: HeadlessSecureFileAccess = HeadlessSecureFileAccess(),
        maxCatalogEntries: Int = 20000
    ) {
        self.catalog = catalog
        self.secureFileAccess = secureFileAccess
        self.maxCatalogEntries = max(0, maxCatalogEntries)
    }

    func search(roots: [HeadlessAllowedRoot], resolver: HeadlessPathResolver, arguments: [String: Any]) throws -> HeadlessSearchResult {
        let pattern = try HeadlessToolArguments.requiredString(arguments, key: "pattern")
        let mode = HeadlessToolArguments.string(arguments, key: "mode") ?? "auto"
        let countOnly = HeadlessToolArguments.bool(arguments, key: "count_only") ?? false
        let maxResults = max(1, min(HeadlessToolArguments.int(arguments, key: "max_results") ?? 50, 1000))
        let contextLines = max(0, min(HeadlessToolArguments.int(arguments, key: "context_lines") ?? 0, 5))
        let wholeWord = HeadlessToolArguments.bool(arguments, key: "whole_word") ?? false
        let regexFlag = HeadlessToolArguments.bool(arguments, key: "regex")
        let useRegex = regexFlag ?? Self.looksLikeRegex(pattern)
        let filter = arguments["filter"] as? [String: Any] ?? [:]
        let extensions = Set((HeadlessToolArguments.stringArray(filter, key: "extensions") ?? []).map { ext in
            ext.hasPrefix(".") ? ext.lowercased() : ".\(ext.lowercased())"
        })
        let exclude = HeadlessToolArguments.stringArray(filter, key: "exclude") ?? []
        let filterPaths = (HeadlessToolArguments.stringArray(filter, key: "paths") ?? []) + (HeadlessToolArguments.string(arguments, key: "path").map { [$0] } ?? [])

        var searchEntries: [HeadlessCatalogEntry] = []
        let catalogEntryLimit = maxCatalogEntries
        var catalogScanCount = 0
        var catalogWasTruncated = false
        var catalogSkippedEntries = 0
        if filterPaths.isEmpty {
            let scanResult = try catalog.scan(roots: roots, maxEntries: maxCatalogEntries)
            searchEntries = scanResult.entries
            catalogScanCount = 1
            catalogWasTruncated = scanResult.wasTruncated
            catalogSkippedEntries = scanResult.skippedEntryCount
        } else {
            var seenEntries: Set<String> = []
            for filterPath in filterPaths {
                guard searchEntries.count < maxCatalogEntries else {
                    catalogWasTruncated = true
                    break
                }
                let resolved = try resolver.resolve(filterPath)
                let scanResult = try catalog.scan(roots: [resolved.root], under: resolved, maxEntries: maxCatalogEntries)
                catalogScanCount += 1
                catalogWasTruncated = catalogWasTruncated || scanResult.wasTruncated
                catalogSkippedEntries += scanResult.skippedEntryCount
                for entry in scanResult.entries {
                    let key = "\(entry.root.id.uuidString):\(entry.relativePath)"
                    guard seenEntries.insert(key).inserted else { continue }
                    guard searchEntries.count < maxCatalogEntries else {
                        catalogWasTruncated = true
                        break
                    }
                    searchEntries.append(entry)
                }
            }
        }

        let matcher = try Matcher(pattern: pattern, regex: useRegex, wholeWord: wholeWord)
        let effectiveMode = mode == "auto" ? "both" : mode
        guard ["path", "content", "both"].contains(effectiveMode) else {
            throw HeadlessCommandError("Unsupported file_search mode '\(mode)'. Expected auto, path, content, or both.", exitCode: 2)
        }

        var pathMatches: [[String: Any]] = []
        var contentMatches: [[String: Any]] = []
        var totalPathMatches = 0
        var totalContentMatches = 0
        var returnedMatches = 0
        var contentFilesScanned = 0
        var contentFilesSkipped = 0
        for entry in searchEntries where !entry.relativePath.isEmpty {
            if shouldSkip(entry: entry, extensions: extensions, exclude: exclude) {
                continue
            }
            if effectiveMode == "path" || effectiveMode == "both" {
                if matcher.matches(entry.displayPath) || matcher.matches(entry.relativePath) {
                    totalPathMatches += 1
                    if !countOnly, returnedMatches < maxResults {
                        pathMatches.append(["path": entry.displayPath, "relative_path": entry.relativePath, "root": entry.root.name])
                        returnedMatches += 1
                    }
                }
            }
            guard !entry.isDirectory, effectiveMode == "content" || effectiveMode == "both" else {
                continue
            }
            guard let byteCount = entry.byteCount, byteCount <= maxReadableBytes else {
                contentFilesSkipped += 1
                continue
            }
            guard let text = try? readTextFile(entry) else {
                contentFilesSkipped += 1
                continue
            }
            contentFilesScanned += 1
            let lines = text.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where matcher.matches(line) {
                totalContentMatches += 1
                if !countOnly, returnedMatches < maxResults {
                    let start = max(0, index - contextLines)
                    let end = min(lines.count - 1, index + contextLines)
                    let context = (start ... end).map { lineIndex in
                        ["line": lineIndex + 1, "text": lines[lineIndex]] as [String: Any]
                    }
                    contentMatches.append([
                        "path": entry.displayPath,
                        "relative_path": entry.relativePath,
                        "root": entry.root.name,
                        "line": index + 1,
                        "text": line,
                        "context": context
                    ])
                    returnedMatches += 1
                }
            }
        }

        let totalMatches = totalPathMatches + totalContentMatches
        let omitted = max(0, totalMatches - maxResults)
        let includesPathSearch = effectiveMode == "path" || effectiveMode == "both"
        let includesContentSearch = effectiveMode == "content" || effectiveMode == "both"
        let catalogComplete = !catalogWasTruncated && catalogSkippedEntries == 0
        let pathTotalsComplete = !includesPathSearch || catalogComplete
        let contentTotalsComplete = !includesContentSearch || (catalogComplete && contentFilesSkipped == 0)
        let totalsComplete = pathTotalsComplete && contentTotalsComplete
        let totalDisplay = totalsComplete ? "\(totalMatches)" : "\(totalMatches) (lower bound)"
        var lines: [String] = [
            "## Search Results ✅",
            "- **Pattern**: `\(pattern)`",
            "- **Mode**: `\(mode)`",
            "- **Total matches**: \(totalDisplay)",
            "- **Path matches**: \(totalPathMatches)",
            "- **Content matches**: \(totalContentMatches)",
            "- **Returned matches**: \(returnedMatches)",
            "- **Omitted by max_results**: \(omitted)",
            "- **Catalog entries scanned**: \(searchEntries.count)",
            "- **Catalog entry limit**: \(catalogEntryLimit) across \(catalogScanCount) scan(s)"
        ]
        if countOnly {
            lines.append("- **Count only**: true")
        } else {
            if !pathMatches.isEmpty {
                lines.append("\n### Path Matches")
                for match in pathMatches {
                    lines.append("- `\(match["path"] as? String ?? "")`")
                }
            }
            if !contentMatches.isEmpty {
                lines.append("\n### Content Matches")
                for match in contentMatches {
                    let path = match["path"] as? String ?? ""
                    let line = match["line"] as? Int ?? 0
                    let text = match["text"] as? String ?? ""
                    lines.append("- `\(path):\(line)` \(text)")
                }
            }
            if omitted > 0 {
                lines.append("\n_Omitted \(omitted) match(es) after max_results=\(maxResults)._")
            }
        }
        if catalogWasTruncated {
            lines.append("\n⚠️ Catalog entry limit reached; eligible entries remain unscanned, so totals are lower bounds.")
        }
        if catalogSkippedEntries > 0 {
            lines.append("\n⚠️ Skipped \(catalogSkippedEntries) catalog entry or traversal error(s); totals are lower bounds.")
        }
        if includesContentSearch, contentFilesSkipped > 0 {
            lines.append("\n⚠️ Skipped \(contentFilesSkipped) unreadable, non-UTF-8, binary, or oversized content file(s); content totals are lower bounds.")
        }

        return HeadlessSearchResult(summary: lines.joined(separator: "\n"), structured: [
            "pattern": pattern,
            "mode": mode,
            "regex": useRegex,
            "whole_word": wholeWord,
            "total_matches": totalMatches,
            "total_path_matches": totalPathMatches,
            "total_content_matches": totalContentMatches,
            "returned_matches": returnedMatches,
            "count_only": countOnly,
            "path_matches": pathMatches,
            "content_matches": contentMatches,
            "omitted": omitted,
            "catalog_entries_scanned": searchEntries.count,
            "catalog_entries_considered": searchEntries.count,
            "catalog_entry_limit": catalogEntryLimit,
            "catalog_scan_count": catalogScanCount,
            "catalog_truncated": catalogWasTruncated,
            "catalog_skipped_entries": catalogSkippedEntries,
            "content_files_scanned": contentFilesScanned,
            "content_files_skipped": contentFilesSkipped,
            "path_totals_complete": pathTotalsComplete,
            "content_totals_complete": contentTotalsComplete,
            "totals_complete": totalsComplete,
            "totals_are_lower_bounds": !totalsComplete,
            "total_matches_is_lower_bound": !totalsComplete,
            "omitted_is_lower_bound": !totalsComplete
        ])
    }

    private func shouldSkip(entry: HeadlessCatalogEntry, extensions: Set<String>, exclude: [String]) -> Bool {
        if !extensions.isEmpty, !entry.isDirectory {
            let ext = ".\(entry.url.pathExtension.lowercased())"
            if !extensions.contains(ext) {
                return true
            }
        }
        return exclude.contains { token in
            entry.relativePath.localizedCaseInsensitiveContains(token) || entry.displayPath.localizedCaseInsensitiveContains(token)
        }
    }

    private func readTextFile(_ entry: HeadlessCatalogEntry) throws -> String {
        let data = try secureFileAccess.readRegularFile(
            root: entry.root,
            relativePath: entry.relativePath,
            maximumBytes: maxReadableBytes
        ).data
        guard !data.contains(0) else {
            throw HeadlessCommandError("Binary file skipped: \(entry.displayPath)", exitCode: 2)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw HeadlessCommandError("File is not valid UTF-8: \(entry.displayPath)", exitCode: 2)
        }
        return text
    }

    private static func looksLikeRegex(_ pattern: String) -> Bool {
        pattern.range(of: #"[.\[\]()*+?{}|^$]"#, options: .regularExpression) != nil
    }

    private struct Matcher {
        let pattern: String
        let regex: NSRegularExpression?

        init(pattern: String, regex: Bool, wholeWord: Bool) throws {
            self.pattern = pattern
            if regex || wholeWord {
                let source = regex ? pattern : NSRegularExpression.escapedPattern(for: pattern)
                let wrapped = wholeWord ? "\\b(?:\(source))\\b" : source
                self.regex = try NSRegularExpression(pattern: wrapped)
            } else {
                self.regex = nil
            }
        }

        func matches(_ text: String) -> Bool {
            if let regex {
                let range = NSRange(text.startIndex ..< text.endIndex, in: text)
                return regex.firstMatch(in: text, range: range) != nil
            }
            return text.localizedCaseInsensitiveContains(pattern)
        }
    }
}
