// LinkExtractor.swift
// Native Apple Silicon SwiftUI app
// Extracts hyperlinks from .docx / .pdf / .pages → exports to .xlsx
// No external dependencies. Compile with build.sh.

import AppKit
import SwiftUI
import Foundation
import PDFKit
import UniformTypeIdentifiers

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Models
// ═══════════════════════════════════════════════════════════════════════════

struct ExtractedLink: Identifiable, Hashable {
    let id  = UUID()
    let url : String

    func hash(into hasher: inout Hasher) { hasher.combine(url) }
    static func == (a: ExtractedLink, b: ExtractedLink) -> Bool { a.url == b.url }
}

struct LoadedFile: Identifiable {
    let id    = UUID()
    let url   : URL
    let name  : String
    let type  : String
    let links : [ExtractedLink]
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - URL Extractors
// ═══════════════════════════════════════════════════════════════════════════

// Regex that matches http(s):// URLs — used for .pages and fallback
private let urlPattern = try! NSRegularExpression(
    pattern: #"https?://[^\s<>"'\]\[}{|\\^`\x00-\x1F]+"#,
    options: []
)

private func extractURLsFromText(_ text: String) -> [String] {
    let ns  = text as NSString
    let len = ns.length
    return urlPattern
        .matches(in: text, range: NSRange(location: 0, length: len))
        .map { ns.substring(with: $0.range) }
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)>\"'")) }
        .filter { !$0.isEmpty }
}

// ── DOCX ─────────────────────────────────────────────────────────────────────

struct DocxExtractor {
    static func extract(from url: URL) throws -> [String] {
        let fm  = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // Unzip using /usr/bin/unzip
        let proc = Process()
        proc.executableURL       = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments           = ["-q", url.path, "-d", tmp.path]
        proc.standardOutput      = Pipe()
        proc.standardError       = Pipe()
        try proc.run()
        proc.waitUntilExit()

        var links: [String] = []

        // 1. Parse word/_rels/document.xml.rels for explicit hyperlinks
        let relsURL = tmp.appendingPathComponent("word/_rels/document.xml.rels")
        if let relsData = try? Data(contentsOf: relsURL),
           let relsStr  = String(data: relsData, encoding: .utf8) {
            links += parseRels(relsStr)
        }

        // 2. Also scan word/document.xml for any raw URLs in text runs
        let docURL = tmp.appendingPathComponent("word/document.xml")
        if let docData = try? Data(contentsOf: docURL),
           let docStr  = String(data: docData, encoding: .utf8) {
            links += extractURLsFromText(docStr)
        }

        // 3. Scan all other XML files (headers, footers, endnotes, etc.)
        if let enumerator = fm.enumerator(at: tmp, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                let p = fileURL.path
                guard p.hasSuffix(".xml") || p.hasSuffix(".rels"),
                      !p.contains("document.xml"),
                      !p.contains("document.xml.rels") else { continue }
                if let data = try? Data(contentsOf: fileURL),
                   let str  = String(data: data, encoding: .utf8) {
                    links += extractURLsFromText(str)
                }
            }
        }

        return links
    }

    // Parse Target="http..." from a .rels XML file
    private static func parseRels(_ xml: String) -> [String] {
        var results: [String] = []
        let pattern = try! NSRegularExpression(
            pattern: #"Target="(https?://[^"]+)""#, options: [])
        let ns = xml as NSString
        for match in pattern.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            if match.numberOfRanges > 1 {
                let range = match.range(at: 1)
                let url   = ns.substring(with: range)
                results.append(url)
            }
        }
        return results
    }
}

// ── PDF ──────────────────────────────────────────────────────────────────────

struct PDFExtractor {
    static func extract(from url: URL) throws -> [String] {
        guard let doc = PDFDocument(url: url) else {
            throw NSError(domain: "PDFExtractor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not open PDF."])
        }

        var links: [String] = []

        for pageIndex in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIndex) else { continue }

            // 1. Named annotations with URLs
            for annotation in page.annotations {
                if let dest = annotation.url {
                    let s = dest.absoluteString
                    if s.hasPrefix("http") { links.append(s) }
                }
                // Some PDFs store URLs as action strings
                if let action = annotation.action as? PDFActionURL,
                   let actionURL = action.url {
                    let s = actionURL.absoluteString
                    if s.hasPrefix("http") { links.append(s) }
                }
            }

            // 2. Scan page text for raw URLs (covers text-as-hyperlink PDFs)
            if let text = page.string {
                links += extractURLsFromText(text)
            }
        }

        return links
    }
}

// ── PAGES ────────────────────────────────────────────────────────────────────

struct PagesExtractor {
    static func extract(from url: URL) throws -> [String] {
        let fm  = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // Unzip the .pages bundle
        let proc = Process()
        proc.executableURL  = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments      = ["-q", url.path, "-d", tmp.path]
        proc.standardOutput = Pipe()
        proc.standardError  = Pipe()
        try proc.run()
        proc.waitUntilExit()

        var links: [String] = []

        // Strategy 1: If there's a preview.pdf inside, use PDFExtractor on it
        let previewPDF = tmp.appendingPathComponent("preview.pdf")
        if fm.fileExists(atPath: previewPDF.path) {
            links += (try? PDFExtractor.extract(from: previewPDF)) ?? []
        }

        // Strategy 2: Scan ALL files (including .iwa protobuf blobs) for URL byte patterns
        // URLs are stored as UTF-8 strings inside protobuf, readable via regex
        if let enumerator = fm.enumerator(at: tmp, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                guard !fileURL.hasDirectoryPath else { continue }
                guard let data = try? Data(contentsOf: fileURL) else { continue }

                // Try as UTF-8 text
                if let text = String(data: data, encoding: .utf8) {
                    links += extractURLsFromText(text)
                } else {
                    // Scan binary data for UTF-8 URL sequences
                    links += extractURLsFromBinaryData(data)
                }
            }
        }

        return links
    }

    // Finds ASCII URL strings embedded in binary data (protobuf blobs)
    private static func extractURLsFromBinaryData(_ data: Data) -> [String] {
        // Convert printable ASCII bytes to a lossy string and scan
        let ascii = data.map { byte -> UInt8 in
            (byte >= 0x20 && byte < 0x7f) ? byte : 0x20  // replace non-printable with space
        }
        let str = String(bytes: ascii, encoding: .ascii) ?? ""
        return extractURLsFromText(str)
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - XLSX Writer
// ═══════════════════════════════════════════════════════════════════════════

struct XLSXWriter {

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&",  with: "&amp;")
         .replacingOccurrences(of: "<",  with: "&lt;")
         .replacingOccurrences(of: ">",  with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'",  with: "&apos;")
    }

    /// sheets: array of (sheetName, [url])
    static func write(sheets: [(String, [String])], to outputURL: URL) throws {
        let fm  = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }

        let xlDir   = tmp.appendingPathComponent("xl")
        let wsDir   = xlDir.appendingPathComponent("worksheets")
        let relsDir = tmp.appendingPathComponent("_rels")
        let xlRels  = xlDir.appendingPathComponent("_rels")

        for d in [wsDir, relsDir, xlRels] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }

        let n = sheets.count

        // Shared string table
        var stringIndex: [String: Int] = [:]
        var allStrings:  [String]      = []
        for (_, urls) in sheets {
            for url in urls {
                if stringIndex[url] == nil {
                    stringIndex[url] = allStrings.count
                    allStrings.append(url)
                }
            }
        }

        // [Content_Types].xml
        let sheetCT = (0..<n).map { i in
            "  <Override PartName=\"/xl/worksheets/sheet\(i+1).xml\" " +
            "ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }.joined(separator: "\n")

        try save(tmp.appendingPathComponent("[Content_Types].xml"), """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml"  ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
\(sheetCT)
  <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
  <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
</Types>
""")

        // _rels/.rels
        try save(relsDir.appendingPathComponent(".rels"), """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>
""")

        // workbook.xml
        let sheetsEl = (0..<n).map { i in
            let name = xmlEscape(String(sheets[i].0.prefix(31)))
            return "    <sheet name=\"\(name)\" sheetId=\"\(i+1)\" r:id=\"rId\(i+1)\"/>"
        }.joined(separator: "\n")

        try save(xlDir.appendingPathComponent("workbook.xml"), """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets>
\(sheetsEl)
  </sheets>
</workbook>
""")

        // workbook.xml.rels
        var relsEntries = (0..<n).map { i in
            "  <Relationship Id=\"rId\(i+1)\" " +
            "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" " +
            "Target=\"worksheets/sheet\(i+1).xml\"/>"
        }.joined(separator: "\n")
        relsEntries += "\n  <Relationship Id=\"rId\(n+1)\" " +
            "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" " +
            "Target=\"sharedStrings.xml\"/>"

        try save(xlRels.appendingPathComponent("workbook.xml.rels"), """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
\(relsEntries)
</Relationships>
""")

        // sharedStrings.xml
        let siEl = allStrings.map { s in
            "  <si><t xml:space=\"preserve\">\(xmlEscape(s))</t></si>"
        }.joined(separator: "\n")

        try save(xlDir.appendingPathComponent("sharedStrings.xml"), """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\(allStrings.count)" uniqueCount="\(allStrings.count)">
\(siEl)
</sst>
""")

        // styles.xml
        try save(xlDir.appendingPathComponent("styles.xml"), """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <fonts count="2">
    <font><sz val="11"/><name val="Calibri"/></font>
    <font><sz val="11"/><u/><color rgb="FF0563C1"/><name val="Calibri"/></font>
  </fonts>
  <fills count="2">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
  </fills>
  <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
  <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
  <cellXfs count="2">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0"/>
  </cellXfs>
</styleSheet>
""")

        // Worksheets
        for (i, (_, urls)) in sheets.enumerated() {
            let rows = urls.enumerated().map { (r, url) -> String in
                let idx = stringIndex[url]!
                return "    <row r=\"\(r+1)\"><c r=\"A\(r+1)\" t=\"s\" s=\"1\"><v>\(idx)</v></c></row>"
            }.joined(separator: "\n")

            try save(wsDir.appendingPathComponent("sheet\(i+1).xml"), """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <cols><col min="1" max="1" width="90" customWidth="1"/></cols>
  <sheetData>
\(rows)
  </sheetData>
</worksheet>
""")
        }

        // Zip it all up
        try? fm.removeItem(at: outputURL)
        let proc = Process()
        proc.executableURL       = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = tmp
        proc.arguments           = ["-r", outputURL.path, "."]
        let ep = Pipe(); proc.standardError = ep
        try proc.run(); proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: ep.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "XLSX", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "zip failed: \(msg)"])
        }
    }

    private static func save(_ url: URL, _ content: String) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - App State
// ═══════════════════════════════════════════════════════════════════════════

class AppState: ObservableObject {
    @Published var loadedFiles : [LoadedFile]  = []
    @Published var selected    : Set<UUID>     = []
    @Published var searchText  : String        = ""
    @Published var statusMsg   : String        = ""
    @Published var statusOK    : Bool          = true
    @Published var isLoading   : Bool          = false
    @Published var deduplicate : Bool          = true

    var allLinks: [ExtractedLink] {
        loadedFiles.flatMap { $0.links }
    }

    var displayedLinks: [ExtractedLink] {
        var links = allLinks
        if deduplicate {
            var seen = Set<String>()
            links = links.filter { seen.insert($0.url).inserted }
        }
        if !searchText.isEmpty {
            links = links.filter { $0.url.localizedCaseInsensitiveContains(searchText) }
        }
        return links
    }

    var dupesRemoved: Int {
        guard deduplicate else { return 0 }
        var seen = Set<String>()
        let uniqueCount = allLinks.filter { seen.insert($0.url).inserted }.count
        return allLinks.count - uniqueCount
    }

    var hasFile      : Bool { !loadedFiles.isEmpty }
    var selectedCount: Int  { selected.count }

    func selectAll() {
        let ids = Set(displayedLinks.map(\.id))
        selected.formUnion(ids)
    }

    func selectNone() {
        let ids = Set(displayedLinks.map(\.id))
        selected.subtract(ids)
    }

    func toggleDedup() {
        deduplicate.toggle()
        selected = Set(displayedLinks.map(\.id))
    }

    func removeFile(_ file: LoadedFile) {
        let linkIDs = Set(file.links.map(\.id))
        selected.subtract(linkIDs)
        loadedFiles.removeAll { $0.id == file.id }
        if loadedFiles.isEmpty {
            statusMsg  = ""
            searchText = ""
        }
    }

    func loadFiles(_ urls: [URL]) {
        let existingPaths = Set(loadedFiles.map(\.url.path))
        let newURLs = urls.filter { !existingPaths.contains($0.path) }
        guard !newURLs.isEmpty else { return }

        isLoading = true
        statusMsg = ""

        DispatchQueue.global(qos: .userInitiated).async {
            var newFiles: [LoadedFile] = []
            var errors: [String] = []

            for url in newURLs {
                do {
                    let rawURLs: [String]
                    switch url.pathExtension.lowercased() {
                    case "docx": rawURLs = try DocxExtractor.extract(from: url)
                    case "pdf":  rawURLs = try PDFExtractor.extract(from: url)
                    case "pages":rawURLs = try PagesExtractor.extract(from: url)
                    default:     rawURLs = []
                    }

                    let links = rawURLs.map { ExtractedLink(url: $0) }
                    newFiles.append(LoadedFile(
                        url: url,
                        name: url.lastPathComponent,
                        type: url.pathExtension.lowercased(),
                        links: links
                    ))
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async {
                self.loadedFiles.append(contentsOf: newFiles)
                self.isLoading = false

                // Select all new links (respecting current dedup/search)
                self.selected = Set(self.displayedLinks.map(\.id))

                if !errors.isEmpty {
                    self.statusMsg = "Failed: " + errors.joined(separator: "; ")
                    self.statusOK  = false
                } else if self.allLinks.isEmpty && !self.loadedFiles.isEmpty {
                    self.statusMsg = "No URLs found in the loaded files."
                    self.statusOK  = false
                } else if !newFiles.isEmpty {
                    self.statusMsg = ""
                }
            }
        }
    }

    func copySelected() {
        let urls = displayedLinks
            .filter { selected.contains($0.id) }
            .map(\.url)
        guard !urls.isEmpty else {
            statusMsg = "No URLs selected."
            statusOK  = false
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.joined(separator: "\n"), forType: .string)
        statusMsg = "\u{2713}  \(urls.count) URL\(urls.count == 1 ? "" : "s") copied to clipboard."
        statusOK  = true
    }

    func export() {
        let selectedIDs = selected
        guard !selectedIDs.isEmpty else {
            statusMsg = "No URLs selected."
            statusOK  = false
            return
        }

        let defaultName: String
        if loadedFiles.count == 1 {
            defaultName = URL(fileURLWithPath: loadedFiles[0].name)
                .deletingPathExtension().lastPathComponent + "_links.xlsx"
        } else {
            defaultName = "links_batch.xlsx"
        }

        let panel = NSSavePanel()
        panel.title                = "Save Excel Workbook"
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes  = [UTType(filenameExtension: "xlsx")!]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        isLoading = true
        statusMsg = ""

        let dedup = deduplicate
        let files = loadedFiles

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var sheets: [(String, [String])] = []
                var usedNames = Set<String>()

                for file in files {
                    var links = file.links.filter { selectedIDs.contains($0.id) }
                    if dedup {
                        var seen = Set<String>()
                        links = links.filter { seen.insert($0.url).inserted }
                    }
                    let urlStrings = links.map(\.url)
                    guard !urlStrings.isEmpty else { continue }

                    // Ensure unique sheet names (xlsx limit: 31 chars)
                    let baseName = URL(fileURLWithPath: file.name)
                        .deletingPathExtension().lastPathComponent
                    var sheetName = String(baseName.prefix(31))
                    var counter = 2
                    while usedNames.contains(sheetName) {
                        let suffix = " (\(counter))"
                        sheetName = String(baseName.prefix(31 - suffix.count)) + suffix
                        counter += 1
                    }
                    usedNames.insert(sheetName)
                    sheets.append((sheetName, urlStrings))
                }

                guard !sheets.isEmpty else {
                    DispatchQueue.main.async {
                        self.isLoading = false
                        self.statusMsg = "No URLs to export."
                        self.statusOK  = false
                    }
                    return
                }

                try XLSXWriter.write(sheets: sheets, to: dest)
                let total = sheets.reduce(0) { $0 + $1.1.count }
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.statusMsg = "\u{2713}  \(total) URL\(total == 1 ? "" : "s") exported across \(sheets.count) sheet\(sheets.count == 1 ? "" : "s")."
                    self.statusOK  = true
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.statusMsg = "Export failed: \(error.localizedDescription)"
                    self.statusOK  = false
                }
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Drop Delegate
// ═══════════════════════════════════════════════════════════════════════════

struct FileDrop: DropDelegate {
    let state: AppState
    let isTargeted: Binding<Bool>?
    let allowed = ["docx","pdf","pages"]

    init(state: AppState, isTargeted: Binding<Bool>? = nil) {
        self.state      = state
        self.isTargeted = isTargeted
    }

    func dropEntered(info: DropInfo) {
        isTargeted?.wrappedValue = true
    }

    func dropExited(info: DropInfo) {
        isTargeted?.wrappedValue = false
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL])
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted?.wrappedValue = false
        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else { return false }

        var collected: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                defer { group.leave() }
                guard let d = data as? Data,
                      let url = URL(dataRepresentation: d, relativeTo: nil) else { return }
                let ext = url.pathExtension.lowercased()
                guard self.allowed.contains(ext) else { return }
                collected.append(url)
            }
        }

        group.notify(queue: .main) {
            if !collected.isEmpty {
                self.state.loadFiles(collected)
            }
        }
        return true
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Link Row
// ═══════════════════════════════════════════════════════════════════════════

struct LinkRow: View {
    let link : ExtractedLink
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()

            Text(link.url)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(red: 0.05, green: 0.4, blue: 0.85))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.url, forType: .string)
            } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }
            Button {
                if let url = URL(string: link.url) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Drop Zone View
// ═══════════════════════════════════════════════════════════════════════════

struct DropZone: View {
    @Binding var isTargeted: Bool
    let action: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted
                        ? Color(red: 0.45, green: 0.65, blue: 1.0)
                        : Color(NSColor.separatorColor),
                    style: StrokeStyle(lineWidth: 2, dash: [6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isTargeted
                              ? Color(red: 0.45, green: 0.65, blue: 1.0).opacity(0.07)
                              : Color(NSColor.controlBackgroundColor))
                )

            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 36))
                    .foregroundColor(isTargeted
                                     ? Color(red: 0.45, green: 0.65, blue: 1.0)
                                     : .secondary)
                Text("Drop .pages, .pdf, or .docx files here")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isTargeted ? .primary : .secondary)
                Text("or")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Button("Choose Files\u{2026}") { action() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.45, green: 0.65, blue: 1.0))
                    .controlSize(.regular)
            }
        }
        .frame(height: 160)
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Badge
// ═══════════════════════════════════════════════════════════════════════════

struct Badge: View {
    let text  : String
    let color : Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Content View
// ═══════════════════════════════════════════════════════════════════════════

struct ContentView: View {
    @StateObject private var state   = AppState()
    @State private var dropTargeted  = false

    private let accent = Color(red: 0.45, green: 0.65, blue: 1.0)
    private let green  = Color(red: 0.13, green: 0.7, blue: 0.45)

    private func fmtColor(_ ext: String) -> Color {
        switch ext {
        case "pdf":   return .red
        case "docx":  return Color(red: 0.1, green: 0.4, blue: 0.85)
        case "pages": return Color(red: 1.0, green: 0.55, blue: 0.0)
        default:      return .secondary
        }
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ──────────────────────────────────────────────────
            HStack(spacing: 12) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 28))
                    .foregroundColor(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Link Extractor")
                        .font(.system(size: 18, weight: .bold))
                    Text("Extract all hyperlinks from .pages \u{00B7} .pdf \u{00B7} .docx \u{2192} Excel")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.6))

            Divider()

            ScrollView {
                VStack(spacing: 0) {

                    // ── Drop Zone / File Chips ──────────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        if !state.hasFile {
                            DropZone(isTargeted: $dropTargeted) { openFile() }
                        } else {
                            // File chips with horizontal scroll
                            HStack(alignment: .top, spacing: 10) {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(state.loadedFiles) { file in
                                            fileChip(file)
                                        }
                                    }
                                }
                                Button("Add Files\u{2026}") { openFile() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)

                    Divider()

                    // ── URL List ─────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("Extracted URLs")
                                .font(.system(size: 13, weight: .semibold))

                            if !state.allLinks.isEmpty {
                                Badge(
                                    text: "\(state.displayedLinks.count) URL\(state.displayedLinks.count == 1 ? "" : "s")",
                                    color: accent
                                )
                                if state.dupesRemoved > 0 {
                                    Badge(
                                        text: "\(state.dupesRemoved) dupes removed",
                                        color: .orange
                                    )
                                }
                            }

                            Spacer()

                            if !state.displayedLinks.isEmpty {
                                // Dedup toggle
                                Toggle("Remove duplicates", isOn: Binding(
                                    get: { state.deduplicate },
                                    set: { _ in state.toggleDedup() }
                                ))
                                .toggleStyle(.checkbox)
                                .font(.system(size: 11))
                                .controlSize(.small)

                                Divider().frame(height: 14)

                                Button("All")  { state.selectAll()  }.controlSize(.mini)
                                Button("None") { state.selectNone() }.controlSize(.mini)
                            }
                        }
                        .buttonStyle(.bordered)

                        // ── Search Bar ──────────────────────────────────
                        if !state.allLinks.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 12))
                                TextField("Filter URLs\u{2026}", text: $state.searchText)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12))
                                if !state.searchText.isEmpty {
                                    Button(action: { state.searchText = "" }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                            .font(.system(size: 12))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(8)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
                        }

                        if state.isLoading {
                            HStack { Spacer(); ProgressView("Scanning\u{2026}"); Spacer() }
                                .frame(height: 200)
                        } else if state.displayedLinks.isEmpty {
                            HStack {
                                Spacer()
                                Text(state.hasFile
                                     ? (state.searchText.isEmpty
                                        ? (state.statusMsg.isEmpty ? "No URLs found." : state.statusMsg)
                                        : "No URLs match your search.")
                                     : "Open a file to see extracted URLs here\u{2026}")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 12))
                                Spacer()
                            }
                            .frame(height: 200)
                        } else {
                            ScrollView(.vertical, showsIndicators: true) {
                                LazyVStack(spacing: 0) {
                                    ForEach(state.displayedLinks) { link in
                                        LinkRow(
                                            link: link,
                                            isOn: Binding(
                                                get: { state.selected.contains(link.id) },
                                                set: { on in
                                                    if on { state.selected.insert(link.id) }
                                                    else  { state.selected.remove(link.id) }
                                                }
                                            )
                                        )
                                        Divider().padding(.leading, 34)
                                    }
                                }
                            }
                            .frame(height: 280)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5))

                            let selectedDisplayed = state.displayedLinks.filter { state.selected.contains($0.id) }.count
                            Text("\(selectedDisplayed) of \(state.displayedLinks.count) selected")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)

                    Divider()

                    // ── Export Bar ───────────────────────────────────────
                    HStack(spacing: 14) {
                        Button {
                            state.export()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "tablecells")
                                Text("Export to Excel (.xlsx)\u{2026}")
                                    .fontWeight(.semibold)
                            }
                            .frame(minWidth: 210)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(green)
                        .controlSize(.large)
                        .disabled(!state.hasFile || state.selectedCount == 0 || state.isLoading)

                        Button {
                            state.copySelected()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.on.doc")
                                Text("Copy")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(!state.hasFile || state.selectedCount == 0 || state.isLoading)

                        if !state.statusMsg.isEmpty {
                            Text(state.statusMsg)
                                .font(.system(size: 12))
                                .foregroundColor(state.statusOK ? green : .red)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                }
            }
        }
        .frame(width: 560)
        .onDrop(of: [UTType.fileURL], delegate: FileDrop(state: state, isTargeted: $dropTargeted))
    }

    // ── File Chip ───────────────────────────────────────────────────────
    private func fileChip(_ file: LoadedFile) -> some View {
        HStack(spacing: 6) {
            Image(systemName: fileIcon(file.type))
                .foregroundColor(fmtColor(file.type))
                .font(.system(size: 12))
            Text(file.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150)
            Badge(text: "\(file.links.count)", color: fmtColor(file.type))
            Button(action: { state.removeFile(file) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(fmtColor(file.type).opacity(0.4), lineWidth: 1))
    }

    private func fileIcon(_ ext: String) -> String {
        switch ext {
        case "pdf":   return "doc.richtext"
        case "docx":  return "doc.text"
        case "pages": return "doc.text.image"
        default:      return "doc"
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.title                   = "Select Documents"
        panel.message                 = "Choose .pages, .pdf, or .docx files"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories    = false
        panel.allowedContentTypes     = [
            UTType(filenameExtension: "pdf")!,
            UTType(filenameExtension: "docx")!,
            UTType(filenameExtension: "pages")!,
        ]
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            state.loadFiles(panel.urls)
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Entry Point
// ═══════════════════════════════════════════════════════════════════════════

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask:   [.titled, .closable, .miniaturizable],
            backing:     .buffered,
            defer:       false
        )
        window.title       = "Link Extractor"
        window.contentView = NSHostingView(rootView: ContentView())
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
