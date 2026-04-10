# Link Extractor

A native macOS app (Apple Silicon) that pulls every hyperlink out of a document and exports them to an Excel workbook — no subscriptions, no cloud, no external dependencies.

Drop in a `.pdf`, `.docx`, or `.pages` file (or several at once), review the extracted URLs, and export directly to `.xlsx` with one click.

---

## Features

- **Multi-file batch mode** — load several documents at once; each file becomes its own sheet in the exported workbook
- **Drag & drop or file picker** — drop files anywhere on the window, or use the file chooser
- **Live search / filter** — type to instantly narrow down hundreds of URLs
- **Duplicate removal** — optional global dedup across all loaded files
- **Clipboard copy** — copy selected URLs as newline-separated text with one click
- **Right-click context menu** — Copy URL or Open in Browser on any row
- **Excel export** — blue underlined hyperlink style, 90-unit column width, one sheet per source file
- **Zero dependencies** — only Apple frameworks (`SwiftUI`, `PDFKit`, `Foundation`, `AppKit`)

---

## Supported Formats

| Format | Extraction method |
|---|---|
| `.pdf` | PDFKit annotations (`PDFActionURL`) + page-text regex scan |
| `.docx` | Unzip → `word/_rels/document.xml.rels` hyperlinks + full XML regex scan |
| `.pages` | Unzip → embedded `preview.pdf` via PDFKit + binary regex scan of `.iwa` protobuf blobs |

All three share a common regex pass for raw URLs in text:

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

Compilation takes 15–30 seconds on first run.

---

## Usage

### Loading files

- **Drag and drop** — drag one or more `.pdf`, `.docx`, or `.pages` files anywhere onto the window
- **File picker** — click **Choose Files…** (or **Add Files…** once files are loaded) to open a multi-select panel

Each loaded file appears as a chip showing its name and link count. Click **×** on a chip to remove that file and its links.

### Reviewing URLs

- Check/uncheck individual rows to include or exclude them from export
- Use **All** / **None** to select or deselect everything visible
- Toggle **Remove duplicates** to deduplicate across all loaded files
- Type in the **search bar** to filter the list in real time — selection state is preserved for hidden rows
- **Right-click** any URL row for:
  - **Copy URL** — copies the single URL to the clipboard
  - **Open in Browser** — opens it in your default browser

### Exporting

| Action | Button |
|---|---|
| Export to Excel | **Export to Excel (.xlsx)…** — opens a Save panel; creates one sheet per file |
| Copy to clipboard | **Copy** — copies all selected *visible* URLs as newline-separated text |

When exporting multiple files, the workbook sheet names are derived from the source filenames (truncated to Excel's 31-character limit, deduplicated if filenames collide).

---

## Project Layout

```
linkextractor/
├── LinkExtractor.swift   ← entire app (~570 lines, single file)
└── build.sh              ← compiler script + app bundle assembly
```

### Architecture (all in `LinkExtractor.swift`)

```
Models
  ExtractedLink   { id: UUID, url: String }
  LoadedFile      { id: UUID, url: URL, name, type, links: [ExtractedLink] }

Extractors  (pure static structs)
  DocxExtractor   → unzip → parse .rels XML + regex scan
  PDFExtractor    → PDFKit annotations + page-text regex
  PagesExtractor  → preview.pdf via PDFKit + binary regex on .iwa blobs

XLSXWriter        → builds Office Open XML tree in temp dir → /usr/bin/zip → .xlsx

AppState          → ObservableObject; holds loadedFiles, selection, search, dedup
  loadFiles(_:)   → background extraction; appends LoadedFile per URL
  copySelected()  → NSPasteboard
  export()        → XLSXWriter, one sheet per LoadedFile

FileDrop          → DropDelegate; collects multiple dropped files via DispatchGroup
LinkRow           → checkbox row + context menu (Copy URL, Open in Browser)
DropZone          → dashed-border drop target shown when no files loaded
ContentView       → root view: file chips, search bar, URL list, export bar
AppDelegate       → NSWindow 560×620, hosts NSHostingView<ContentView>
```

---

## Apple Notes Workflow

Notes doesn't export hyperlinks cleanly. Best paths:

1. **Notes → PDF** *(quickest)*  
   File › Print › Save as PDF → drop into Link Extractor  
   *(works if links are clickable in Notes)*

2. **Notes → Pages → PDF**  
   Copy note content → paste into a new Pages doc → File › Export To › PDF → drop in

3. **Notes → HTML** *(best for bulk, macOS Sonoma+)*  
   File › Export All Notes → produces `.html` files  
   *(HTML support is a planned future upgrade)*

---

## Planned Upgrades

- [ ] Source column in xlsx (filename + page number for PDFs)
- [ ] Anchor text extraction for `.docx` hyperlinks
- [ ] HTML / `.htm` support (`<a href>` parsing)
- [ ] RTF support (`\fldinst HYPERLINK` patterns)
- [ ] PDF page number tracking
- [ ] Resizable window
- [ ] CSV export alternative
- [ ] Duplicate highlighting (color instead of remove)

---

## License

MIT — do whatever you like with it.
