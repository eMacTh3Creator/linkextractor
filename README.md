# Link Extractor

A native macOS app (Apple Silicon) that pulls every hyperlink out of a document and exports them to Excel or CSV — no subscriptions, no cloud, no external dependencies.

Drop in `.pdf`, `.docx`, `.pages`, `.html`, or `.rtf` files (or several at once), review the extracted URLs with source info and anchor text, and export with one click.

---

## Features

- **5 file formats** — PDF, Word (.docx), Pages, HTML, and RTF
- **Multi-file batch mode** — load several documents at once; each file becomes its own sheet in the exported workbook
- **Source tracking** — every URL shows which file (and page number for PDFs) it came from
- **Anchor text extraction** — for `.docx` and `.html` files, captures the display text of each hyperlink
- **Dual export** — Excel (.xlsx) with bold headers and blue hyperlink styling, or CSV with a File column
- **Duplicate highlighting** — toggle between removing duplicates or highlighting them in orange
- **Live search** — filter by URL, source, or anchor text in real time
- **Right-click context menu** — Copy URL, Copy Anchor Text, Open in Browser
- **Clipboard copy** — copy all selected URLs as newline-separated text
- **Resizable window** — drag to resize; minimum 520x480, default 620x680
- **Drag & drop** — drop files anywhere on the window
- **Zero dependencies** — only Apple frameworks (`SwiftUI`, `PDFKit`, `Foundation`, `AppKit`)

---

## Supported Formats

| Format | Extraction method | Source tracking | Anchor text |
|---|---|---|---|
| `.pdf` | PDFKit annotations + page-text regex | Filename + page number | -- |
| `.docx` | Unzip -> `document.xml.rels` hyperlinks + `<w:hyperlink>` parsing | Filename | Display text from `<w:t>` elements |
| `.pages` | Unzip -> embedded `preview.pdf` + binary regex on `.iwa` blobs | Filename + page number | -- |
| `.html` / `.htm` | `<a href>` tag parsing + raw URL regex | Filename | Inner text of `<a>` tags |
| `.rtf` | `NSAttributedString` `.link` attributes + `HYPERLINK` regex fallback | Filename | Link display text |

All formats share a common regex pass for raw URLs:

```
https?://[^\s<>"'\]\[}{|\\^`\x00-\x1F]+
```

Trailing punctuation (`,` `.` `;` `:` `)` `>` `"` `'`) is stripped automatically.

---

## Requirements

| | |
|---|---|
| **Platform** | macOS 12 Monterey or later |
| **Architecture** | Apple Silicon (arm64) |
| **Toolchain** | Xcode Command Line Tools |

> Intel Macs are not supported — the binary targets `arm64-apple-macos12.0` explicitly.

---

## Build

```bash
# 1. Install Xcode Command Line Tools if needed
xcode-select --install

# 2. Clone the repo
git clone https://github.com/eMacTh3Creator/linkextractor.git
cd linkextractor

# 3. Build
chmod +x build.sh
./build.sh
```

The script:
1. Compiles `LinkExtractor.swift` with `swiftc -O -framework PDFKit`
2. Assembles the `.app` bundle under `LinkExtractor.app/`
3. Writes `Info.plist` and strips the quarantine attribute
4. Prompts to launch immediately

Compilation takes 15-30 seconds on first run.

---

## Usage

### Loading files

- **Drag and drop** — drag one or more supported files anywhere onto the window
- **File picker** — click **Choose Files...** (or **Add Files...** once files are loaded) to open a multi-select panel

Each loaded file appears as a chip showing its name, format color, and link count. Click **x** on a chip to remove it.

### Reviewing URLs

Each row displays:
- The URL (blue monospace)
- Source info (filename, page number for PDFs)
- Anchor text when available (the display text of the original hyperlink)

Controls:
- **Check/uncheck** rows to include or exclude them from export
- **All / None** buttons to bulk-select or deselect visible links
- **Remove duplicates** toggle — ON removes dupes globally; OFF highlights them with an orange "dupe" badge and tinted background
- **Search bar** — filters by URL, source, or anchor text; selection state is preserved for hidden rows

Right-click any row for:
- **Copy URL** — single URL to clipboard
- **Copy Anchor Text** — if the link has display text
- **Open in Browser** — opens in your default browser

### Exporting

| Action | Button | Output |
|---|---|---|
| Excel export | **Export .xlsx...** | One sheet per file, 3 columns: URL (blue hyperlink), Source, Anchor Text |
| CSV export | **Export .csv...** | All links in one file, 4 columns: URL, Source, Anchor Text, File |
| Clipboard | **Copy** | Selected visible URLs, newline-separated |

Excel workbook sheet names are derived from source filenames (truncated to 31 chars, auto-deduplicated on collision).

---

## Excel Output Format

Each sheet includes:
- **Row 1** — Bold headers: URL | Source | Anchor Text
- **Column A** — URLs in blue underlined Calibri 11pt (width: 80)
- **Column B** — Source reference (width: 35)
- **Column C** — Anchor text when available (width: 50)

---

## Project Layout

```
linkextractor/
├── LinkExtractor.swift   ← entire app (~830 lines, single file)
└── build.sh              ← compiler script + app bundle assembly
```

### Architecture (all in `LinkExtractor.swift`)

```
Models
  RawLink           { url, source, anchorText }        — extractor/writer interchange
  ExtractedLink     { id, url, source, anchorText }    — UI model with UUID
  LoadedFile        { id, url, name, type, links }

Extractors  (pure static structs, return [RawLink])
  DocxExtractor     → unzip → rId map + <w:hyperlink> anchor text + regex scan
  PDFExtractor      → PDFKit annotations + page-text regex (with page numbers)
  PagesExtractor    → preview.pdf via PDFExtractor + binary regex on .iwa blobs
  HtmlExtractor     → <a href> tag parsing + entity decoding + raw URL scan
  RtfExtractor      → NSAttributedString .link attrs + HYPERLINK regex fallback

Writers
  XLSXWriter        → Office Open XML with 3 columns, headers, 3 cell styles
  CSVWriter          → RFC 4180 CSV with 4 columns (URL, Source, Anchor Text, File)

AppState            → ObservableObject; loadedFiles, selection, search, dedup
  loadFiles(_:)     → background extraction → [LoadedFile]
  export()          → XLSXWriter, one sheet per file
  exportCSV()       → CSVWriter, all files in one CSV
  copySelected()    → NSPasteboard
  buildSheets()     → shared sheet builder for both export paths

Views
  FileDrop          → DropDelegate; multi-file collection via DispatchGroup
  LinkRow           → URL + source + anchor text + dupe highlight + context menu
  DropZone          → dashed-border drop target
  Badge             → colored pill label
  ContentView       → file chips, search bar, URL list, export bar (resizable)
  AppDelegate       → NSWindow 620x680, resizable, min 520x480
```

---

## Apple Notes Workflow

Notes doesn't export hyperlinks cleanly. Best paths:

1. **Notes -> PDF** *(quickest)*
   File > Print > Save as PDF -> drop into Link Extractor

2. **Notes -> Pages -> PDF**
   Copy note content -> paste into a new Pages doc -> File > Export To > PDF -> drop in

3. **Notes -> HTML** *(best for bulk, macOS Sonoma+)*
   File > Export All Notes -> produces `.html` files -> drop them directly into Link Extractor

---

## Changelog

### v2.0
- HTML (.html, .htm) and RTF (.rtf) format support
- Source column in exports (filename + page number for PDFs)
- Anchor text extraction for .docx and .html hyperlinks
- RTF extraction via NSAttributedString + HYPERLINK regex
- CSV export alternative alongside Excel
- Duplicate highlighting with orange badges when dedup is off
- Resizable window (min 520x480, default 620x680)
- 3-column Excel output with bold headers (URL, Source, Anchor Text)
- Search now covers URL, source, and anchor text fields

### v1.0
- Initial release with PDF, Word, and Pages support
- Multi-file batch mode, search/filter, clipboard copy
- Right-click context menu, drag and drop

---

## License

MIT — do whatever you like with it.
