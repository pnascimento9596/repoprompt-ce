import Foundation

package enum PromptRenderingService {
    @inline(__always)
    package static func codeFenceStart(for fileName: String) -> String {
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension
        return fileExtension.isEmpty ? "```" : "```\(fileExtension)"
    }

    package static func renderFileBlocks(
        _ values: [PromptRenderingFileValue]
    ) -> [PromptRenderedFileBlock] {
        var blocks: [PromptRenderedFileBlock] = []
        blocks.reserveCapacity(values.count)

        for (index, value) in values.enumerated() {
            if let codemapText = value.codemapText {
                blocks.append(
                    PromptRenderedFileBlock(
                        inputIndex: index,
                        text: codemapText,
                        kind: .codemap
                    )
                )
                continue
            }

            guard let content = value.content else { continue }
            let assembly = SliceAssemblyBuilder.build(from: content, ranges: value.ranges)
            let startFence = codeFenceStart(for: value.fileName)
            let text = if assembly.isFullFile {
                renderFullFileBlock(
                    displayPath: value.displayPath,
                    startFence: startFence,
                    content: assembly.combinedText
                )
            } else {
                renderSliceFileBlock(
                    displayPath: value.displayPath,
                    startFence: startFence,
                    segments: assembly.segments
                )
            }
            blocks.append(
                PromptRenderedFileBlock(
                    inputIndex: index,
                    text: text,
                    kind: .content
                )
            )
        }

        return blocks
    }

    package static func renderPartitionedFileBlocks(
        _ values: [PromptRenderingFileValue]
    ) -> PromptPartitionedFileBlocks {
        let blocks = renderFileBlocks(values)
        var codemapBlocks: [String] = []
        var contentBlocks: [String] = []
        codemapBlocks.reserveCapacity(blocks.count)
        contentBlocks.reserveCapacity(blocks.count)

        for block in blocks where !block.text.isEmpty {
            switch block.kind {
            case .codemap:
                codemapBlocks.append(block.text)
            case .content:
                contentBlocks.append(block.text)
            }
        }

        return PromptPartitionedFileBlocks(
            codemapBlocks: codemapBlocks,
            contentBlocks: contentBlocks
        )
    }

    package static func renderDiffParts(
        _ values: [PromptRenderingDiffValue]
    ) -> [String] {
        var parts: [String] = []
        parts.reserveCapacity(values.count)

        for value in values {
            guard let content = value.content, !content.isEmpty else { continue }
            let assembly = SliceAssemblyBuilder.build(from: content, ranges: value.ranges)
            let text = assembly.isFullFile
                ? assembly.combinedText
                : assembly.segments.map(\.text).joined(separator: "\n")
            if !text.isEmpty {
                parts.append(text)
            }
        }

        return parts
    }

    package static func renderSelectedDiffText(
        _ values: [PromptRenderingDiffValue]
    ) -> String? {
        let parts = renderDiffParts(values)
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    package static func renderFactualSnippets(
        fileTreeContent: String?,
        codemapBlocks: [String],
        contentBlocks: [String],
        gitDiff: String?
    ) -> PromptRenderedFactualSnippets {
        let codemapText = codemapBlocks.joined(separator: "\n\n")
        let hasTree = fileTreeContent != nil && !fileTreeContent!.isEmpty
        let hasCodemaps = !codemapText.isEmpty
        let fileMap: String? = if hasTree || hasCodemaps {
            """
            <file_map>
            \([fileTreeContent ?? "", codemapText].filter { !$0.isEmpty }.joined(separator: "\n\n"))
            </file_map>

            """
        } else {
            nil
        }

        let fileContents: String? = if !contentBlocks.isEmpty {
            """
            <file_contents>
            \(contentBlocks.joined(separator: "\n\n"))
            </file_contents>

            """
        } else {
            nil
        }

        let gitDiffSnippet: String? = if let gitDiff, !gitDiff.isEmpty {
            """
            <git_diff>
            \(gitDiff)
            </git_diff>

            """
        } else {
            nil
        }

        return PromptRenderedFactualSnippets(
            fileMap: fileMap,
            fileContents: fileContents,
            gitDiff: gitDiffSnippet
        )
    }

    private static func renderFullFileBlock(
        displayPath: String,
        startFence: String,
        content: String
    ) -> String {
        """
        File: \(displayPath)
        \(startFence)
        \(content)
        ```
        """
    }

    private static func renderSliceFileBlock(
        displayPath: String,
        startFence: String,
        segments: [WorkspaceSliceSegment]
    ) -> String {
        var lines = ["File: \(displayPath)"]
        for (index, segment) in segments.enumerated() {
            let rangeLabel = segment.range.start == segment.range.end
                ? "\(segment.range.start)"
                : "\(segment.range.start)-\(segment.range.end)"
            if let description = segment.range.description, !description.isEmpty {
                lines.append("(lines \(rangeLabel): \(description))")
            } else {
                lines.append("(lines \(rangeLabel))")
            }
            lines.append(startFence)
            lines.append(segment.text)
            lines.append("```")
            if index != segments.count - 1 {
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }
}
