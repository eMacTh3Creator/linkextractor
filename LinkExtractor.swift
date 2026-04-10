// LinkExtractor.swift
// Native Apple Silicon SwiftUI app
// Extracts hyperlinks from .docx / .pdf / .pages / .html / .rtf → exports to .xlsx or .csv
// No external dependencies. Compile with build.sh.

import AppKit
import SwiftUI
import Foundation
import PDFKit
import UniformTypeIdentifiers

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Models
// ═══════════════════════════════════════════════════════════════════════════

/// Lightweight link data used by extractors and writers.
struct RawLink {
    let url        : String
    let source     : String   // e.g. "report.pdf, Page 3"
    let anchorText : String   // display text of the hyperlink (empty if none)
}

/// UI model with identity for SwiftUI list / selection.
struct ExtractedLink: Identifiable, Hashable {
    let id         = UUID()
    let url        : String
    let source     : String
    let anchorText : String

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
// MARK: - URL Extractors — shared helpers
// ═══════════════════════════════════════════════════════════════════════════

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

private func decodeHtmlEntities(_ s: String) -> String {
    s.replacingOccurrences(of: "&amp;",  with: "&")
     .replacingOccurrences(of: "&lt;",   with: "<")
     .replacingOccurrences(of: "&gt;",   with: ">")
     .replacingOccurrences(of: "&quot;", with: "\"")
     .replacingOccurrences(of: "&#39;",  with: "'")
     .replacingOccurrences(of: "&apos;", with: "'")
}

// ── DOCX ─────────────────────────────────────────────────────────────────────

struct DocxExtractor {
    static func extract(from url: URL) throws -> [RawLink] {
        let fm  = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL  = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments      = ["-q", url.path, "-d", tmp.path]
        proc.standardOutput = Pipe()
        proc.standardError  = Pipe()
        try proc.run()
        proc.waitUntilExit()

        let filename = url.lastPathComponent
        var links: [RawLink] = []

        // 1. Build rId → URL map from rels
        var relMap: [String: String] = [:]
        let relsURL = tmp.appendingPathComponent("word/_rels/document.xml.rels")
        if let relsData = try? Data(contentsOf: relsURL),
           let relsStr  = String(data: relsData, encoding: .utf8) {
            relMap = parseRelsMap(relsStr)
        }

        // 2. Parse document.xml for hyperlinks with anchor text
        let docURL = tmp.appendingPathComponent("word/document.xml")
        if let docData = try? Data(contentsOf: docURL),
           let docStr  = String(data: docData, encoding: .utf8) {

            // Extract <w:hyperlink r:id="X"> with <w:t> text inside
            let hyperlinks = parseHyperlinks(docStr, relMap: relMap, filename: filename)
            var urlToAnchor: [String: String] = [:]
            for hl in hyperlinks where !hl.anchorText.isEmpty {
                urlToAnchor[hl.url] = hl.anchorText
            }

            // Add rels URLs (with anchor text if we found one)
            for (_, urlStr) in relMap {
                let anchor = urlToAnchor[urlStr] ?? ""
                links.append(RawLink(url: urlStr, source: filename, anchorText: anchor))
            }

            // Add any hyperlinks with inline URLs not covered by rels
            let relsURLs = Set(relMap.values)
            for hl in hyperlinks where !relsURLs.contains(hl.url) {
                links.append(hl)
            }

            // Raw URL scan of document.xml
            let existing = Set(links.map(\.url))
            for rawURL in extractURLsFromText(docStr) where !existing.contains(rawURL) {
                links.append(RawLink(url: rawURL, source: filename, anchorText: ""))
            }
        } else {
            // Fallback: just add rels URLs
            for (_, urlStr) in relMap {
                links.append(RawLink(url: urlStr, source: filename, anchorText: ""))
            }
        }

        // 3. Scan other XML files (headers, footers, endnotes)
        let existing2 = Set(links.map(\.url))
        if let enumerator = fm.enumerator(at: tmp, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                let p = fileURL.path
                guard p.hasSuffix(".xml") || p.hasSuffix(".rels"),
                      !p.contains("document.xml"),
                      !p.contains("document.xml.rels") else { continue }
                if let data = try? Data(contentsOf: fileURL),
                   let str  = String(data: data, encoding: .utf8) {
                    for rawURL in extractURLsFromText(str) where !existing2.contains(rawURL) {
                        links.append(RawLink(url: rawURL, source: filename, anchorText: ""))
                    }
                }
            }
        }

        return links
    }

    /// Build rId → URL map from a .rels file (attribute order–independent).
    private static func parseRelsMap(_ xml: String) -> [String: String] {
        var map: [String: String] = [:]
        let relPattern    = try! NSRegularExpression(pattern: #"<Relationship\s[^>]+>"#, options: [])
        let idPattern     = try! NSRegularExpression(pattern: #"Id="([^"]+)""#, options: [])
        let targetPattern = try! NSRegularExpression(pattern: #"Target="(https?://[^"]+)""#, options: [])
        let ns = xml as NSString
        for m in relPattern.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let tag   = ns.substring(with: m.range)
            let tagNS = tag as NSString
            let r     = NSRange(location: 0, length: tagNS.length)
            guard let idM = idPattern.firstMatch(in: tag, range: r),
                  let tM  = targetPattern.firstMatch(in: tag, range: r) else { continue }
            map[tagNS.substring(with: idM.range(at: 1))] = tagNS.substring(with: tM.range(at: 1))
        }
        return map
    }

    /// Extract <w:hyperlink r:id="X"> with inner <w:t> text.
    private static func parseHyperlinks(_ xml: String, relMap: [String: String], filename: String) -> [RawLink] {
        var results: [RawLink] = []
        let hlPattern   = try! NSRegularExpression(
            pattern: #"<w:hyperlink[^>]*r:id="([^"]+)"[^>]*>(.*?)</w:hyperlink>"#,
            options: [.dotMatchesLineSeparators])
        let textPattern = try! NSRegularExpression(
            pattern: #"<w:t[^>]*>(.*?)</w:t>"#,
            options: [.dotMatchesLineSeparators])
        let ns = xml as NSString
        for m in hlPattern.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges > 2 else { continue }
            let rId  = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2))
            guard let url = relMap[rId] else { continue }
            var texts: [String] = []
            let bodyNS = body as NSString
            for tm in textPattern.matches(in: body, range: NSRange(location: 0, length: bodyNS.length)) {
                if tm.numberOfRanges > 1 { texts.append(bodyNS.substring(with: tm.range(at: 1))) }
            }
            results.append(RawLink(url: url, source: filename, anchorText: texts.joined()))
        }
        return results
    }
}

// ── PDF ──────────────────────────────────────────────────────────────────────

struct PDFExtractor {
    static func extract(from url: URL) throws -> [RawLink] {
        guard let doc = PDFDocument(url: url) else {
            throw NSError(domain: "PDFExtractor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not open PDF."])
        }

        let filename = url.lastPathComponent
        var links: [RawLink] = []

        for pageIndex in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIndex) else { continue }
            let source = "\(filename), Page \(pageIndex + 1)"

            for annotation in page.annotations {
                if let dest = annotation.url {
                    let s = dest.absoluteString
                    if s.hasPrefix("http") { links.append(RawLink(url: s, source: source, anchorText: "")) }
                }
                if let action = annotation.action as? PDFActionURL,
                   let actionURL = action.url {
                    let s = actionURL.absoluteString
                    if s.hasPrefix("http") { links.append(RawLink(url: s, source: source, anchorText: "")) }
                }
            }

            if let text = page.string {
                for rawURL in extractURLsFromText(text) {
                    links.append(RawLink(url: rawURL, source: source, anchorText: ""))
                }
            }
        }

        return links
    }
}

// ── PAGES ────────────────────────────────────────────────────────────────────

struct PagesExtractor {
    static func extract(from url: URL) throws -> [RawLink] {
        let fm  = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL  = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments      = ["-q", url.path, "-d", tmp.path]
        proc.standardOutput = Pipe()
        proc.standardError  = Pipe()
        try proc.run()
        proc.waitUntilExit()

        let filename = url.lastPathComponent
        var links: [RawLink] = []

        // Strategy 1: preview.pdf — use PDFExtractor, re-source to .pages filename
        let previewPDF = tmp.appendingPathComponent("preview.pdf")
        if fm.fileExists(atPath: previewPDF.path) {
            let pdfLinks = (try? PDFExtractor.extract(from: previewPDF)) ?? []
            links += pdfLinks.map {
                RawLink(url: $0.url,
                        source: $0.source.replacingOccurrences(of: "preview.pdf", with: filename),
                        anchorText: $0.anchorText)
            }
        }

        // Strategy 2: Scan all files for URL byte patterns
        let existingURLs = Set(links.map(\.url))
        if let enumerator = fm.enumerator(at: tmp, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                guard !fileURL.hasDirectoryPath else { continue }
                guard let data = try? Data(contentsOf: fileURL) else { continue }

                if let text = String(data: data, encoding: .utf8) {
                    for rawURL in extractURLsFromText(text) where !existingURLs.contains(rawURL) {
                        links.append(RawLink(url: rawURL, source: filename, anchorText: ""))
                    }
                } else {
                    for rawURL in extractURLsFromBinaryData(data) where !existingURLs.contains(rawURL) {
                        links.append(RawLink(url: rawURL, source: filename, anchorText: ""))
                    }
                }
            }
        }

        return links
    }

    private static func extractURLsFromBinaryData(_ data: Data) -> [String] {
        let ascii = data.map { byte -> UInt8 in
            (byte >= 0x20 && byte < 0x7f) ? byte : 0x20
        }
        let str = String(bytes: ascii, encoding: .ascii) ?? ""
        return extractURLsFromText(str)
    }
}

// ── HTML ─────────────────────────────────────────────────────────────────────

struct HtmlExtractor {
    static func extract(from url: URL) throws -> [RawLink] {
        guard let data = try? Data(contentsOf: url) else {
            throw NSError(domain: "HtmlExtractor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not read HTML file."])
        }
        guard let html = String(data: data, encoding: .utf8)
                      ?? String(data: data, encoding: .isoLatin1) else {
            throw NSError(domain: "HtmlExtractor", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported text encoding."])
        }

        let filename = url.lastPathComponent
        var links: [RawLink] = []

        // 1. Parse <a href="url">text</a>
        let aPattern = try! NSRegularExpression(
            pattern: #"<a\s[^>]*href\s*=\s*["'](https?://[^"']+)["'][^>]*>(.*?)</a>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators])
        let ns = html as NSString
        for m in aPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges > 2 else { continue }
            let rawURL  = decodeHtmlEntities(ns.substring(with: m.range(at: 1)))
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)>\"'"))
            let rawText = ns.substring(with: m.range(at: 2))
            let anchor  = stripHtmlTags(rawText).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawURL.isEmpty {
                links.append(RawLink(url: rawURL, source: filename, anchorText: anchor))
            }
        }

        // 2. Raw URL scan for URLs not inside <a> tags
        let captured = Set(links.map(\.url))
        for rawURL in extractURLsFromText(html) where !captured.contains(rawURL) {
            links.append(RawLink(url: rawURL, source: filename, anchorText: ""))
        }

        return links
    }

    private static func stripHtmlTags(_ html: String) -> String {
        let pat = try! NSRegularExpression(pattern: "<[^>]+>", options: [])
        let stripped = pat.stringByReplacingMatches(
            in: html, range: NSRange(location: 0, length: (html as NSString).length), withTemplate: "")
        return decodeHtmlEntities(stripped)
    }
}

// ── RTF ──────────────────────────────────────────────────────────────────────

struct RtfExtractor {
    static func extract(from url: URL) throws -> [RawLink] {
        guard let data = try? Data(contentsOf: url) else {
            throw NSError(domain: "RtfExtractor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not read RTF file."])
        }

        let filename = url.lastPathComponent
        var links: [RawLink] = []
        var capturedURLs = Set<String>()

        // 1. NSAttributedString parses RTF natively and exposes .link attributes
        if let attrStr = NSAttributedString(rtf: data, documentAttributes: nil) {
            attrStr.enumerateAttribute(.link, in: NSRange(location: 0, length: attrStr.length)) { value, range, _ in
                var urlStr: String?
                if let u = value as? URL  { urlStr = u.absoluteString }
                if let s = value as? String { urlStr = s }
                guard let u = urlStr, u.hasPrefix("http") else { return }
                let text = attrStr.attributedSubstring(from: range).string
                links.append(RawLink(url: u, source: filename, anchorText: text))
                capturedURLs.insert(u)
            }

            // Scan plain text for raw URLs
            for rawURL in extractURLsFromText(attrStr.string) where !capturedURLs.contains(rawURL) {
                links.append(RawLink(url: rawURL, source: filename, anchorText: ""))
                capturedURLs.insert(rawURL)
            }
        }

        // 2. Regex fallback on raw RTF source (catches HYPERLINK fields NSAttributedString may miss)
        if let rtfStr = String(data: data, encoding: .ascii)
                     ?? String(data: data, encoding: .utf8) {
            let hlPattern = try! NSRegularExpression(
                pattern: #"HYPERLINK\s+"(https?://[^"]+)""#, options: [])
            let ns = rtfStr as NSString
            for m in hlPattern.matches(in: rtfStr, range: NSRange(location: 0, length: ns.length)) {
                guard m.numberOfRanges > 1 else { continue }
                let u = ns.substring(with: m.range(at: 1))
                if !capturedURLs.contains(u) {
                    links.append(RawLink(url: u, source: filename, anchorText: ""))
                    capturedURLs.insert(u)
                }
            }
        }

        return links
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

    /// sheets: array of (sheetName, [RawLink])
    /// Columns: A = URL (blue underline), B = Source, C = Anchor Text
    static func write(sheets: [(String, [RawLink])], to outputURL: URL) throws {
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

        // ── Shared string table ──────────────────────────────────────
        var stringIndex: [String: Int] = [:]
        var allStrings:  [String]      = []
        func addStr(_ s: String) {
            if stringIndex[s] == nil { stringIndex[s] = allStrings.count; allStrings.append(s) }
        }

        // Headers first
        addStr("URL"); addStr("Source"); addStr("Anchor Text")
        for (_, links) in sheets {
            for link in links {
                addStr(link.url)
                addStr(link.source)
                if !link.anchorText.isEmpty { addStr(link.anchorText) }
            }
        }

        // ── [Content_Types].xml ──────────────────────────────────────
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

        // ── _rels/.rels ──────────────────────────────────────────────
        try save(relsDir.appendingPathComponent(".rels"), """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>
""")

        // ── workbook.xml ─────────────────────────────────────────────
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

        // ── workbook.xml.rels ────────────────────────────────────────
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

        // ── sharedStrings.xml ────────────────────────────────────────
        let siEl = allStrings.map { s in
            "  <si><t xml:space=\"preserve\">\(xmlEscape(s))</t></si>"
        }.joined(separator: "\n")

        try save(xlDir.appendingPathComponent("sharedStrings.xml"), """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\(allStrings.count)" uniqueCount="\(allStrings.count)">
\(siEl)
</sst>
""")

        // ── styles.xml (3 cell formats: normal, blue-link, bold-header) ──
        try save(xlDir.appendingPathComponent("styles.xml"), """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <fonts count="3">
    <font><sz val="11"/><name val="Calibri"/></font>
    <font><sz val="11"/><u/><color rgb="FF0563C1"/><name val="Calibri"/></font>
    <font><sz val="11"/><b/><name val="Calibri"/></font>
  </fonts>
  <fills count="2">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
  </fills>
  <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
  <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
  <cellXfs count="3">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0"/>
  </cellXfs>
</styleSheet>
""")

        // ── Worksheets ───────────────────────────────────────────────
        for (i, (_, links)) in sheets.enumerated() {
            var rows: [String] = []

            // Header row (bold, s="2")
            let hURL = stringIndex["URL"]!
            let hSrc = stringIndex["Source"]!
            let hAnc = stringIndex["Anchor Text"]!
            rows.append("    <row r=\"1\"><c r=\"A1\" t=\"s\" s=\"2\"><v>\(hURL)</v></c>" +
                        "<c r=\"B1\" t=\"s\" s=\"2\"><v>\(hSrc)</v></c>" +
                        "<c r=\"C1\" t=\"s\" s=\"2\"><v>\(hAnc)</v></c></row>")

            // Data rows
            for (r, link) in links.enumerated() {
                let row = r + 2
                let uIdx = stringIndex[link.url]!
                let sIdx = stringIndex[link.source]!
                var xml  = "    <row r=\"\(row)\">"
                xml += "<c r=\"A\(row)\" t=\"s\" s=\"1\"><v>\(uIdx)</v></c>"
                xml += "<c r=\"B\(row)\" t=\"s\" s=\"0\"><v>\(sIdx)</v></c>"
                if !link.anchorText.isEmpty, let aIdx = stringIndex[link.anchorText] {
                    xml += "<c r=\"C\(row)\" t=\"s\" s=\"0\"><v>\(aIdx)</v></c>"
                }
                xml += "</row>"
                rows.append(xml)
            }

            try save(wsDir.appendingPathComponent("sheet\(i+1).xml"), """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <cols>
    <col min="1" max="1" width="80" customWidth="1"/>
    <col min="2" max="2" width="35" customWidth="1"/>
    <col min="3" max="3" width="50" customWidth="1"/>
  </cols>
  <sheetData>
\(rows.joined(separator: "\n"))
  </sheetData>
</worksheet>
""")
        }

        // ── Zip → .xlsx ─────────────────────────────────────────────
        try? fm.removeItem(at: outputURL)
        let zipProc = Process()
        zipProc.executableURL       = URL(fileURLWithPath: "/usr/bin/zip")
        zipProc.currentDirectoryURL = tmp
        zipProc.arguments           = ["-r", outputURL.path, "."]
        let ep = Pipe(); zipProc.standardError = ep
        try zipProc.run(); zipProc.waitUntilExit()
        guard zipProc.terminationStatus == 0 else {
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
// MARK: - CSV Writer
// ═══════════════════════════════════════════════════════════════════════════

struct CSVWriter {
    static func write(sheets: [(String, [RawLink])], to outputURL: URL) throws {
        var lines: [String] = [csvLine(["URL", "Source", "Anchor Text", "File"])]
        for (sheetName, links) in sheets {
            for link in links {
                lines.append(csvLine([link.url, link.source, link.anchorText, sheetName]))
            }
        }
        try lines.joined(separator: "\n").write(to: outputURL, atomically: true, encoding: .utf8)
    }

    private static func csvLine(_ fields: [String]) -> String {
        fields.map { f in
            (f.contains(",") || f.contains("\"") || f.contains("\n"))
                ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                : f
        }.joined(separator: ",")
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
            links = links.filter {
                $0.url.localizedCaseInsensitiveContains(searchText) ||
                $0.source.localizedCaseInsensitiveContains(searchText) ||
                $0.anchorText.localizedCaseInsensitiveContains(searchText)
            }
        }
        return links
    }

    /// Number of extra duplicate occurrences across all links.
    var dupeCount: Int {
        var seen = Set<String>()
        let unique = allLinks.filter { seen.insert($0.url).inserted }.count
        return allLinks.count - unique
    }

    /// URLs that appear more than once (for highlight mode).
    var duplicateURLs: Set<String> {
        var counts = [String: Int]()
        for link in allLinks { counts[link.url, default: 0] += 1 }
        return Set(counts.filter { $0.value > 1 }.keys)
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
        if loadedFiles.isEmpty { statusMsg = ""; searchText = "" }
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
                    let rawLinks: [RawLink]
                    switch url.pathExtension.lowercased() {
                    case "docx":         rawLinks = try DocxExtractor.extract(from: url)
                    case "pdf":          rawLinks = try PDFExtractor.extract(from: url)
                    case "pages":        rawLinks = try PagesExtractor.extract(from: url)
                    case "html", "htm":  rawLinks = try HtmlExtractor.extract(from: url)
                    case "rtf":          rawLinks = try RtfExtractor.extract(from: url)
                    default:             rawLinks = []
                    }

                    let links = rawLinks.map {
                        ExtractedLink(url: $0.url, source: $0.source, anchorText: $0.anchorText)
                    }
                    newFiles.append(LoadedFile(
                        url: url, name: url.lastPathComponent,
                        type: url.pathExtension.lowercased(), links: links
                    ))
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async {
                self.loadedFiles.append(contentsOf: newFiles)
                self.isLoading = false
                self.selected  = Set(self.displayedLinks.map(\.id))

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
        let urls = displayedLinks.filter { selected.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { statusMsg = "No URLs selected."; statusOK = false; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.joined(separator: "\n"), forType: .string)
        statusMsg = "\u{2713}  \(urls.count) URL\(urls.count == 1 ? "" : "s") copied to clipboard."
        statusOK  = true
    }

    // ── Shared sheet builder (used by xlsx & csv export) ─────────────
    private func buildSheets() -> [(String, [RawLink])] {
        let selectedIDs = selected
        let dedup = deduplicate
        var sheets: [(String, [RawLink])] = []
        var usedNames = Set<String>()

        for file in loadedFiles {
            var links = file.links.filter { selectedIDs.contains($0.id) }
            if dedup {
                var seen = Set<String>()
                links = links.filter { seen.insert($0.url).inserted }
            }
            let rawLinks = links.map { RawLink(url: $0.url, source: $0.source, anchorText: $0.anchorText) }
            guard !rawLinks.isEmpty else { continue }

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
            sheets.append((sheetName, rawLinks))
        }
        return sheets
    }

    func export() {
        guard !selected.isEmpty else { statusMsg = "No URLs selected."; statusOK = false; return }

        let defaultName = loadedFiles.count == 1
            ? URL(fileURLWithPath: loadedFiles[0].name).deletingPathExtension().lastPathComponent + "_links.xlsx"
            : "links_batch.xlsx"

        let panel = NSSavePanel()
        panel.title                = "Save Excel Workbook"
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes  = [UTType(filenameExtension: "xlsx")!]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let sheets = buildSheets()
        guard !sheets.isEmpty else { statusMsg = "No URLs to export."; statusOK = false; return }

        isLoading = true; statusMsg = ""

        DispatchQueue.global(qos: .userInitiated).async {
            do {
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

    func exportCSV() {
        guard !selected.isEmpty else { statusMsg = "No URLs selected."; statusOK = false; return }

        let defaultName = loadedFiles.count == 1
            ? URL(fileURLWithPath: loadedFiles[0].name).deletingPathExtension().lastPathComponent + "_links.csv"
            : "links_batch.csv"

        let panel = NSSavePanel()
        panel.title                = "Save CSV File"
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes  = [UTType(filenameExtension: "csv")!]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let sheets = buildSheets()
        guard !sheets.isEmpty else { statusMsg = "No URLs to export."; statusOK = false; return }

        isLoading = true; statusMsg = ""

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try CSVWriter.write(sheets: sheets, to: dest)
                let total = sheets.reduce(0) { $0 + $1.1.count }
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.statusMsg = "\u{2713}  \(total) URL\(total == 1 ? "" : "s") exported as CSV."
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
    let allowed = ["docx","pdf","pages","html","htm","rtf"]

    init(state: AppState, isTargeted: Binding<Bool>? = nil) {
        self.state      = state
        self.isTargeted = isTargeted
    }

    func dropEntered(info: DropInfo)  { isTargeted?.wrappedValue = true  }
    func dropExited(info: DropInfo)   { isTargeted?.wrappedValue = false }

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
                if self.allowed.contains(url.pathExtension.lowercased()) {
                    collected.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            if !collected.isEmpty { self.state.loadFiles(collected) }
        }
        return true
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Link Row
// ═══════════════════════════════════════════════════════════════════════════

struct LinkRow: View {
    let link        : ExtractedLink
    @Binding var isOn: Bool
    let isDuplicate : Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(link.url)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(red: 0.05, green: 0.4, blue: 0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    if !link.source.isEmpty {
                        Text(link.source)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    if !link.anchorText.isEmpty {
                        Text("\u{2014} \(link.anchorText)")
                            .font(.system(size: 10))
                            .foregroundColor(Color(red: 0.35, green: 0.35, blue: 0.35))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isDuplicate {
                Text("dupe")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .foregroundColor(.orange)
                    .clipShape(Capsule())
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .contextMenu {
            Button { pasteboard(link.url) } label: { Label("Copy URL", systemImage: "doc.on.doc") }
            if !link.anchorText.isEmpty {
                Button { pasteboard(link.anchorText) } label: { Label("Copy Anchor Text", systemImage: "text.quote") }
            }
            Divider()
            Button {
                if let url = URL(string: link.url) { NSWorkspace.shared.open(url) }
            } label: { Label("Open in Browser", systemImage: "safari") }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(isDuplicate ? Color.orange.opacity(0.06) : Color.clear)
    }

    private func pasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
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
                Text("Drop .pdf, .docx, .pages, .html, or .rtf files here")
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
        case "pdf":          return .red
        case "docx":         return Color(red: 0.1, green: 0.4, blue: 0.85)
        case "pages":        return Color(red: 1.0, green: 0.55, blue: 0.0)
        case "html", "htm":  return Color(red: 0.0, green: 0.6, blue: 0.5)
        case "rtf":          return Color(red: 0.5, green: 0.3, blue: 0.7)
        default:             return .secondary
        }
    }

    private func fileIcon(_ ext: String) -> String {
        switch ext {
        case "pdf":          return "doc.richtext"
        case "docx":         return "doc.text"
        case "pages":        return "doc.text.image"
        case "html", "htm":  return "globe"
        case "rtf":          return "doc.plaintext"
        default:             return "doc"
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
                    Text("Extract hyperlinks from .pdf \u{00B7} .docx \u{00B7} .pages \u{00B7} .html \u{00B7} .rtf \u{2192} Excel / CSV")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.6))

            Divider()

            // ── Drop Zone / File Chips ──────────────────────────────────
            VStack(alignment: .leading, spacing: 10) {
                if !state.hasFile {
                    DropZone(isTargeted: $dropTargeted) { openFile() }
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(state.loadedFiles) { file in fileChip(file) }
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

            // ── URL List section (flexible height) ──────────────────────
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Extracted URLs")
                        .font(.system(size: 13, weight: .semibold))

                    if !state.allLinks.isEmpty {
                        Badge(
                            text: "\(state.displayedLinks.count) URL\(state.displayedLinks.count == 1 ? "" : "s")",
                            color: accent
                        )
                        if state.dupeCount > 0 {
                            Badge(
                                text: state.deduplicate
                                    ? "\(state.dupeCount) dupes removed"
                                    : "\(state.dupeCount) duplicate\(state.dupeCount == 1 ? "" : "s")",
                                color: .orange
                            )
                        }
                    }

                    Spacer()

                    if !state.displayedLinks.isEmpty {
                        Toggle(state.deduplicate ? "Remove duplicates" : "Highlight duplicates",
                               isOn: Binding(
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

                // ── Search Bar ──────────────────────────────────────────
                if !state.allLinks.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                        TextField("Search\u{2026}", text: $state.searchText)
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

                // ── URL list / empty state ──────────────────────────────
                if state.isLoading {
                    HStack { Spacer(); ProgressView("Scanning\u{2026}"); Spacer() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let dupes = state.deduplicate ? Set<String>() : state.duplicateURLs
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
                                    ),
                                    isDuplicate: dupes.contains(link.url)
                                )
                                Divider().padding(.leading, 34)
                            }
                        }
                    }
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.5))

                    let selDisp = state.displayedLinks.filter { state.selected.contains($0.id) }.count
                    Text("\(selDisp) of \(state.displayedLinks.count) selected")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .frame(maxHeight: .infinity)

            Divider()

            // ── Export Bar ───────────────────────────────────────────────
            HStack(spacing: 10) {
                Button { state.export() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "tablecells")
                        Text("Export .xlsx\u{2026}")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(green)
                .controlSize(.large)
                .disabled(!state.hasFile || state.selectedCount == 0 || state.isLoading)

                Button { state.exportCSV() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                        Text("Export .csv\u{2026}")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!state.hasFile || state.selectedCount == 0 || state.isLoading)

                Button { state.copySelected() } label: {
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
        .frame(minWidth: 520, minHeight: 480)
        .onDrop(of: [UTType.fileURL], delegate: FileDrop(state: state, isTargeted: $dropTargeted))
    }

    // ── File Chip ────────────────────────────────────────────────────
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

    private func openFile() {
        let panel = NSOpenPanel()
        panel.title                   = "Select Documents"
        panel.message                 = "Choose .pdf, .docx, .pages, .html, or .rtf files"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories    = false
        panel.allowedContentTypes     = [
            UTType(filenameExtension: "pdf")!,
            UTType(filenameExtension: "docx")!,
            UTType(filenameExtension: "pages")!,
            UTType(filenameExtension: "html")!,
            UTType(filenameExtension: "htm")!,
            UTType(filenameExtension: "rtf")!,
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
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable],
            backing:     .buffered,
            defer:       false
        )
        window.title       = "Link Extractor"
        window.minSize     = NSSize(width: 520, height: 480)
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
