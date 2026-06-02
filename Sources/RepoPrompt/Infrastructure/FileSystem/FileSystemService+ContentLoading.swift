import Cuchardet
import Foundation
import UniversalCharsetDetection

private extension String.Encoding {
    init(ianaCharsetName name: String) {
        let cfEnc = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        self.init(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
    }
}

// MARK: - Encoding detection helpers & priority tables

/// Run a streaming detector (Cuchardet) over the entire byte sequence.
/// Falls back to Foundation’s heuristic if the detector is unavailable.
private func detectEncodingFull(_ data: Data) -> String.Encoding {
    // 1) Primary - Cuchardet
    if let label = data.detectedCharacterEncoding { // DataProtocol extension from Cuchardet
        return .init(ianaCharsetName: label)
    }

    // 2) Fallback - Foundation heuristic
    var lossy = ObjCBool(false)
    let guess = NSString.stringEncoding(
        for: data,
        encodingOptions: [:],
        convertedString: nil,
        usedLossyConversion: &lossy
    )
    return guess != 0 ? .init(rawValue: guess) : .utf8
}

extension FileSystemService {
    func loadContent(ofRelativePath relativePath: String) async throws -> String? {
        let contentLoadState = EditFlowPerf.begin(EditFlowPerf.Stage.FileSystem.contentLoadActorBody)
        defer { EditFlowPerf.end(EditFlowPerf.Stage.FileSystem.contentLoadActorBody, contentLoadState) }

        // Early, no-IO short-circuit for known-binary extensions
        let relExt = ((relativePath as NSString).pathExtension).lowercased()
        if !relExt.isEmpty, Self.alwaysBinaryExtensions.contains(relExt) {
            return nil
        }

        let fm = fm // Cache for multiple calls in this method
        let fullPath = fullPath(forRelativePath: relativePath)
        guard fm.fileExists(atPath: fullPath, isDirectory: nil) else {
            throw FileSystemError.fileNotFound
        }

        let attrs = try fm.attributesOfItem(atPath: fullPath)
        let fileSize = attrs[.size] as? Int64 ?? 0
        let url = URL(fileURLWithPath: fullPath)
        let ext = url.pathExtension.lowercased()

        // (1) Whitelist → skip binary probe entirely
        let skipProbe = Self.alwaysTextExtensions.contains(ext)
            || (ext.isEmpty && Self.alwaysTextFilenames.contains(url.lastPathComponent.lowercased()))

        // (2) Optional heuristic probe on first 8 KB
        if !skipProbe {
            if let handle = try? FileHandle(forReadingFrom: url) {
                let probe = try handle.read(upToCount: 8192) ?? Data()
                try? handle.close()
                if Self.isProbablyBinary(probe) { return nil }
            }
        }

        // (3) Small files – read once, detect encoding
        if fileSize < 2_000_000 {
            let detected = try readDataAndDetectEncoding(fullPath)
            encodingMap[relativePath] = detected.encoding
            return detected.string
        }

        // (4) Larger files – streamed read
        return try await loadEntireFileContentOptimized(
            ofRelativePath: relativePath,
            chunkSize: 1_048_576, // 1 MB
            fileSizeLimit: 10_000_000 // 10 MB
        )
    }

    /// For backward compatibility - delegates to the new implementation
    func loadContent(of url: URL) async throws -> String? {
        let relativePath = url.relativePath(from: URL(fileURLWithPath: path))
        return try await loadContent(ofRelativePath: relativePath)
    }

    func loadContentWithDate(ofRelativePath relativePath: String) async throws -> (content: String?, modificationDate: Date) {
        // let _ = fullPath(forRelativePath: relativePath)
        async let content = loadContent(ofRelativePath: relativePath)
        async let modDate = getFileModificationDate(atRelativePath: relativePath)
        return try await (content, modDate)
    }

    /// Loads large files in chunks, detecting encoding on‑the‑fly.
    ///
    /// Order of precedence:
    ///   1. BOM (cheap, deterministic)
    ///   2. Cuchardet’s streaming detector
    ///   3. Default to UTF‑8          ← no further fall‑backs
    func loadEntireFileContentOptimized(
        ofRelativePath relativePath: String,
        chunkSize: Int = 1_048_576, // 1 MB
        fileSizeLimit: Int64 = 10_000_000 // 10 MB
    ) async throws -> String? {
        // Early, no-IO short-circuit for known-binary extensions
        let relExt = ((relativePath as NSString).pathExtension).lowercased()
        if !relExt.isEmpty, Self.alwaysBinaryExtensions.contains(relExt) {
            return nil
        }

        let fm = fm // Cache for multiple calls in this method

        let fullPath = fullPath(forRelativePath: relativePath)
        guard fm.fileExists(atPath: fullPath, isDirectory: nil) else {
            throw FileSystemError.fileNotFound
        }

        // Size guard
        let attrs = try fm.attributesOfItem(atPath: fullPath)
        let fileSize = attrs[.size] as? Int64 ?? 0
        if fileSize > fileSizeLimit {
            return "[File too large: \(fileSize) bytes]"
        }

        let url = URL(fileURLWithPath: fullPath)
        let ext = url.pathExtension.lowercased()
        let skipProbe = Self.alwaysTextExtensions.contains(ext)
            || (ext.isEmpty && Self.alwaysTextFilenames.contains(url.lastPathComponent.lowercased()))

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var fullData = Data()
        fullData.reserveCapacity(Int(fileSize))

        let detector = CharacterEncodingDetector()

        // First chunk
        let initialData = try handle.read(upToCount: chunkSize) ?? Data()
        if !skipProbe, Self.isProbablyBinary(initialData) { return nil }
        fullData.append(initialData)
        _ = detector.analyzeNextChunk(initialData)

        try Task.checkCancellation()

        // Subsequent chunks
        while true {
            let next = try handle.read(upToCount: chunkSize) ?? Data()
            if next.isEmpty { break } // EOF
            fullData.append(next)
            _ = detector.analyzeNextChunk(next)

            if fullData.count > 100_000_000 {
                fullData.append("\n[Truncated large file...]\n".data(using: .utf8)!)
                break
            }
            try Task.checkCancellation()
        }

        // Resolve encoding
        let encoding: String.Encoding = if let bom = Self.detectBOMEncoding(in: initialData) {
            bom
        } else if let label = detector.finish() {
            .init(ianaCharsetName: label)
        } else {
            .utf8 // no secondary heuristics
        }

        encodingMap[relativePath] = encoding
        return String(data: fullData, encoding: encoding) ?? "[Binary data or unknown encoding]"
    }

    /// Attempt to decode with all post‑UTF‑8 fall‑backs, including region‑specific ones.
    func tryDecodeWithFallbackEncodings(_ data: Data) -> String? {
        for enc in Self.orderedFallbackEncodings + Self.regionSpecificEncodings {
            if let s = String(data: data, encoding: enc) { return s }
        }
        return nil
    }

    /// Detect the most probable encoding from an initial data slice.
    ///
    /// Fast-path order:
    ///   1. Byte-order-mark (BOM)
    ///   2. Cuchardet on the same bytes
    ///   3. Strict UTF-8
    ///   4. Western single-byte fall-backs
    ///   5. Heuristic UTF-16 without BOM
    ///   6. Region-specific legacies
    func detectEncodingForInitialChunk(initialData: Data) throws -> String.Encoding {
        guard !initialData.isEmpty else { return .utf8 }

        // 1) Honor BOM immediately
        if let bomEncoding = Self.detectBOMEncoding(in: initialData) {
            return bomEncoding
        }

        // 2) Cuchardet (fast – O(n) on the *same* bytes)
        if let label = initialData.detectedCharacterEncoding {
            return .init(ianaCharsetName: label)
        }

        // 3) UTF-8 strict
        if String(data: initialData, encoding: .utf8) != nil {
            return .utf8
        }

        // 4) Western single-byte encodings
        for enc in Self.orderedFallbackEncodings where String(data: initialData, encoding: enc) != nil {
            return enc
        }

        // 5) Heuristic UTF-16 without BOM
        if Self.looksLikeUTF16(initialData) {
            for enc in [String.Encoding.utf16LittleEndian, .utf16BigEndian]
                where String(data: initialData, encoding: enc) != nil
            {
                return enc
            }
        }

        // 6) Region-specific encodings
        for enc in Self.regionSpecificEncodings where String(data: initialData, encoding: enc) != nil {
            return enc
        }

        // Fallback to UTF-8 with replacement
        return .utf8
    }

    /// Example approach if you want a standalone data-based detection
    func detectFileEncodingFromData(_ data: Data) async throws -> String.Encoding {
        // 1) BOM check
        if let bom = Self.detectBOMEncoding(in: data) { return bom }

        // 2) UTF‑8 strict
        if String(data: data, encoding: .utf8) != nil { return .utf8 }

        // 3–4) CP‑1252 / Mac Roman
        for enc in Self.orderedFallbackEncodings where String(data: data, encoding: enc) != nil {
            return enc
        }

        // 5) UTF‑16 heuristic without BOM
        if Self.looksLikeUTF16(data) {
            // fully qualify to String.Encoding
            for enc in [String.Encoding.utf16LittleEndian, String.Encoding.utf16BigEndian]
                where String(data: data, encoding: enc) != nil
            {
                return enc
            }
        }

        // 6) Region‑specific encodings
        for enc in Self.regionSpecificEncodings where String(data: data, encoding: enc) != nil {
            return enc
        }

        // Last‑resort default
        return .utf8
    }

    // MARK: - Binary detection helpers

    /// ─────────────────────────────────────────────────────────────────────────────
    /// Binary detection heuristic (Git-style, UTF-8 tolerant)
    ///
    /// • Any NUL byte → binary
    /// • Control bytes 0x00–0x1F **except** TAB/LF/CR
    /// • If ≥ 30 % of the bytes in the sample are control bytes → binary
    static func isProbablyBinary(_ data: Data, sampleSize: Int = 8192) -> Bool {
        guard !data.isEmpty else { return false }
        let sample = data.prefix(sampleSize)

        // Immediate NUL check
        if sample.contains(0) { return true }

        var ctrl = 0
        var printableOrUtf8 = 0

        for byte in sample {
            switch byte {
            case 0x09, 0x0A, 0x0D, 0x20 ... 0x7E: // HT, LF, CR, printable ASCII
                printableOrUtf8 += 1
            case 0x01 ... 0x08, 0x0B ... 0x0C, 0x0E ... 0x1F: // Other ASCII control chars
                ctrl += 1
            default: // 0x80–0xFF → UTF-8 part or extended ASCII
                printableOrUtf8 += 1
            }
        }

        let total = ctrl + printableOrUtf8
        guard total > 0 else { return false }
        return Double(ctrl) / Double(total) > 0.30
    }

    // MARK: - Encoding detection helpers & priority tables

    /// Encodings to try **after** UTF‑8 fails, in the exact order mandated
    /// by the research note: Windows‑1252 → Mac Roman → UTF‑16 (LE/BE)
    static let orderedFallbackEncodings: [String.Encoding] = [
        .windowsCP1252,
        .macOSRoman
    ]

    /// Optional, low‑priority locale‑specific single‑byte encodings
    static let regionSpecificEncodings: [String.Encoding] = [
        .shiftJIS, .japaneseEUC, .iso2022JP, // Japanese
        // Mainland‑China GB18030
        String.Encoding(
            rawValue:
            CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        ),
        // Traditional‑Chinese Big5
        String.Encoding(
            rawValue:
            CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue)
            )
        ),
        .windowsCP1251, .isoLatin2 // Cyrillic / Central‑Europe
    ]

    // MARK: - Extension / filename whitelists

    /// Extensions that are always treated as binary; we short-circuit before any filesystem queries.
    static let alwaysBinaryExtensions: Set<String> = [
        // ── Video ───────────────────────────────────────────────────
        "mp4", "m4v", "mov", "avi", "mkv", "webm", "flv", "wmv", "mpeg", "mpg", "m2ts", "mts", "3gp", "3g2", "ogv",
        "asf", "rm", "rmvb", "vob", "ogm", "f4v", "mpe", "m1v", "m2v", "divx", "xvid", "dv",
        // ── Audio ───────────────────────────────────────────────────
        "wav", "aiff", "aif", "flac", "ogg", "oga", "opus", "m4a", "aac", "mp3", "mid", "midi", "caf", "ape", "alac", "dsf", "dff",
        // ── Images ──────────────────────────────────────────────────
        "png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "ico", "icns", "psd", "ai", "eps", "heic", "heif",
        "raw", "cr2", "nef", "arw", "dng", "orf", "rw2", "svgz",
        // ── 3D / assets ─────────────────────────────────────────────
        "fbx", "blend", "blend1", "3ds", "dae", "glb",
        // ── Fonts ───────────────────────────────────────────────────
        "ttf", "otf", "ttc", "woff", "woff2",
        // ── Archives / packages / disk images ───────────────────────
        "zip", "rar", "7z", "7zip", "tar", "gz", "bz2", "bz", "xz", "zst", "tgz", "tbz", "tbz2", "dmg", "iso", "cab", "pkg", "msi", "crx",
        "jar", "war", "ear", "apk", "ipa",
        // ── Object / compiled / binaries ────────────────────────────
        "o", "a", "so", "dylib", "dll", "exe", "bin", "class", "wasm", "pdb", "lib", "obj",
        // ── Databases / data containers ─────────────────────────────
        "db", "sqlite", "sqlite3", "realm", "mdb", "accdb", "parquet", "feather", "arrow",
        // ── Documents (binary containers) ───────────────────────────
        "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "rtf", "sketch", "indd", "idml"
    ]

    /// Extensions that are **always** treated as plain-text – we skip the binary probe entirely.
    static let alwaysTextExtensions: Set<String> = [
        // ── General text / docs ─────────────────────────────────────
        "txt", "text", "md", "markdown", "rst", "mdx",
        // ── Data / config ───────────────────────────────────────────
        "json", "jsonc", "xml", "yaml", "yml", "toml", "ini", "cfg", "conf", "properties",
        "csv", "tsv", "proto",
        // ── Web assets ──────────────────────────────────────────────
        "html", "htm", "css", "scss", "sass", "less", "styl",
        "js", "mjs", "jsx", "ts", "tsx", "vue", "svelte", "astro", "pug", "jade",
        // ── Programming languages ──────────────────────────────────
        "swift", "c", "cpp", "cc", "h", "hpp", "m", "mm",
        "cs", "csx", // C-sharp
        "java", "kt", "kts", "groovy", "scala", "go", "rs", "dart", "zig", "nim",
        "py", "pyw", "pyx", "rb", "php", "phtml", "php5", "phps", "pl", "pm",
        "ex", "exs", "erl", "elixir", "clj", "cljs", "cljc", "coffee",
        "sh", "bash", "zsh", "fish", "cmd", "bat", "ps1", "psm1", "lua",
        "sql"
    ]

    /// Filenames with **no** extension that are always text.
    static let alwaysTextFilenames: Set<String> = [
        "makefile", "dockerfile", "readme", "license",
        "gitignore", ".gitignore", ".ignore", ".env",
        ".gitattributes", ".editorconfig"
    ]

    /// Detect a Unicode BOM and return the matching encoding, or `nil`.
    static func detectBOMEncoding(in data: Data) -> String.Encoding? {
        guard data.count >= 2 else { return nil }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8 } // UTF‑8 BOM
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return .utf32BigEndian }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return .utf32LittleEndian }
        if data.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        if data.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        return nil
    }

    /// Attempts to detect the file’s encoding and return the decoded text.
    /// The fast-path now uses the length-aware `String(data:encoding:)`
    /// instead of `String(validatingUTF8:)`, eliminating crashes caused by
    /// missing NUL-termination in `Data` buffers.
    func readDataAndDetectEncoding(_ fullPath: String) throws -> DetectedText {
        let data = try Data(contentsOf: URL(fileURLWithPath: fullPath))

        // 0 --> return empty string immediately  ✅
        if data.isEmpty {
            return DetectedText(string: "", encoding: .utf8)
        }

        // 1) Fast-path: strict UTF-8 validation over the *whole* buffer
        //    This is safe because the initializer is length-aware.
        if let utf8String = String(data: data, encoding: .utf8) {
            return DetectedText(string: utf8String, encoding: .utf8)
        }

        // 2) Charset detector (fallback)
        let enc = detectEncodingFull(data)
        guard let str = String(data: data, encoding: enc) else {
            throw FileSystemError.failedToReadFile
        }
        return DetectedText(string: str, encoding: enc)
    }

    /// Quick heuristic: UTF‑16 text usually contains many NUL bytes.
    static func looksLikeUTF16(_ data: Data) -> Bool {
        let sample = data.prefix(256)
        let zeroCount = sample.count(where: { $0 == 0 })
        return zeroCount > sample.count / 4 // > 25 % zeros ⇒ likely UTF‑16
    }

    // A minimal directory entry representation

    func detectFileEncoding(atRelativePath relativePath: String) async throws -> String.Encoding {
        let fullPath = fullPath(forRelativePath: relativePath)
        let url = URL(fileURLWithPath: fullPath)

        guard let data = try? Data(contentsOf: url) else {
            throw FileSystemError.failedToReadFile
        }

        var usedLossyConversion = ObjCBool(false)
        let encodingValue = NSString.stringEncoding(
            for: data,
            encodingOptions: [:],
            convertedString: nil,
            usedLossyConversion: &usedLossyConversion
        )
        if encodingValue != 0 {
            return String.Encoding(rawValue: encodingValue)
        }

        let encodings: [(String.Encoding, String)] = [
            (.utf8, "UTF-8"),
            (.macOSRoman, "Mac OS Roman"),
            (.ascii, "ASCII"),
            (.utf16, "UTF-16"),
            (.utf16BigEndian, "UTF-16 Big Endian"),
            (.utf16LittleEndian, "UTF-16 Little Endian"),
            (.utf32, "UTF-32"),
            (.utf32BigEndian, "UTF-32 Big Endian"),
            (.utf32LittleEndian, "UTF-32 Little Endian"),
            (.windowsCP1252, "Windows-1252"),
            (.isoLatin1, "ISO-8859-1"),
            (.unicode, "Unicode"),
            (.shiftJIS, "Shift JIS"),
            (.nonLossyASCII, "Non-Lossy ASCII")
        ]

        for (encoding, _) in encodings {
            if let _ = String(data: data, encoding: encoding) {
                return encoding
            }
        }

        return .utf8
    }
}
