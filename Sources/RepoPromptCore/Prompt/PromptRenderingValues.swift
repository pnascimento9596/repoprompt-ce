import Foundation

package struct PromptRenderingFileValue: Equatable {
    package let displayPath: String
    package let fileName: String
    package let content: String?
    package let ranges: [LineRange]?
    package let codemapText: String?

    package init(
        displayPath: String,
        fileName: String,
        content: String?,
        ranges: [LineRange]? = nil,
        codemapText: String? = nil
    ) {
        self.displayPath = displayPath
        self.fileName = fileName
        self.content = content
        self.ranges = ranges
        self.codemapText = codemapText
    }
}

package struct PromptRenderingDiffValue: Equatable {
    package let content: String?
    package let ranges: [LineRange]?

    package init(content: String?, ranges: [LineRange]? = nil) {
        self.content = content
        self.ranges = ranges
    }
}

package enum PromptRenderedFileBlockKind: Equatable {
    case codemap
    case content
}

package struct PromptRenderedFileBlock: Equatable {
    package let inputIndex: Int
    package let text: String
    package let kind: PromptRenderedFileBlockKind

    package init(inputIndex: Int, text: String, kind: PromptRenderedFileBlockKind) {
        self.inputIndex = inputIndex
        self.text = text
        self.kind = kind
    }
}

package struct PromptPartitionedFileBlocks: Equatable {
    package let codemapBlocks: [String]
    package let contentBlocks: [String]

    package init(codemapBlocks: [String], contentBlocks: [String]) {
        self.codemapBlocks = codemapBlocks
        self.contentBlocks = contentBlocks
    }
}

package struct PromptRenderedFactualSnippets: Equatable {
    package let fileMap: String?
    package let fileContents: String?
    package let gitDiff: String?

    package init(fileMap: String?, fileContents: String?, gitDiff: String?) {
        self.fileMap = fileMap
        self.fileContents = fileContents
        self.gitDiff = gitDiff
    }
}
