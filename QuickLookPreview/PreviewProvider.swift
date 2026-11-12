//
//  PreviewProvider.swift
//  QuickLookPreview
//
//  The Space-bar preview in the Finder for Apple II disk images and archives: the volume,
//  its format and size, and every file with its type, size and date.
//

import Cocoa
import Quartz
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let filename = url.lastPathComponent
        let html: String
        do {
            html = CatalogPage.html(for: try DiskImageLoader.load(data, filename: filename), filename: filename)
        } catch let error as DiskLoadError {
            // Some of these extensions belong to other files too, such as Stata .do scripts
            if let text = CatalogPage.plainText(data) {
                return QLPreviewReply(dataOfContentType: .plainText, contentSize: CGSize(width: 720, height: 600)) { _ in
                    Data(text.utf8)
                }
            }
            html = CatalogPage.html(error: error, filename: filename)
        }
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 760, height: 620)) { reply in
            reply.title = filename
            return Data(html.utf8)
        }
    }
}

enum CatalogPage {

    /// Files listed at most; a 32 MB hard disk rarely has more
    static let maximumRows = 3000

    static func html(for disk: LoadedDisk, filename: String) -> String {
        let catalog = disk.catalog
        var facts = [catalog.diskFormat, sizeText(catalog.diskSize)]
        let fileCount = catalog.totalFiles
        facts.append(fileCount == 1 ? "1 file" : "\(fileCount) files")

        var notes: [String] = []
        if let woz = disk.woz {
            facts.append("WOZ \(woz.version)")
            let meta = woz.metadata
            let about = ["title", "subtitle", "publisher", "developer", "copyright"]
                .compactMap { meta[$0]?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !about.isEmpty { notes.append(about.joined(separator: " · ")) }
            if woz.sectorsDecoded < woz.sectorsExpected {
                notes.append("⚠️ \(woz.sectorsDecoded) of \(woz.sectorsExpected) sectors read. The disk may be copy-protected; some files may be incomplete.")
            }
            if !woz.checksumMatches {
                notes.append("⚠️ The checksum of the image does not match its contents.")
            }
        }
        if !disk.unreadable.isEmpty {
            notes.append("⚠️ Could not extract: " + disk.unreadable.joined(separator: ", "))
        }

        var rows: [String] = []
        appendRows(catalog.entries, depth: 0, to: &rows)
        if rows.count > maximumRows {
            let hidden = rows.count - maximumRows
            rows = Array(rows.prefix(maximumRows))
            rows.append("<tr><td colspan=5 class=more>… and \(hidden) more</td></tr>")
        }

        let name = disk.displayName(filename: filename)
        let subtitle = name == filename ? "" : "<div class=file>\(escape(filename))</div>"
        let body = rows.isEmpty
            ? "<p class=empty>This disk has no files.</p>"
            : """
              <table>
              <thead><tr><th>Name</th><th>Type</th><th class=num>Aux</th><th class=num>Size</th><th>Modified</th></tr></thead>
              <tbody>\(rows.joined(separator: "\n"))</tbody>
              </table>
              """
        return page("""
            <header>
              <div class=icon>\(icon(for: disk.medium))</div>
              <div>
                <h1>\(escape(name))</h1>
                \(subtitle)
                <div class=facts>\(facts.map(escape).joined(separator: " · "))</div>
                \(notes.map { "<div class=note>\(escape($0))</div>" }.joined())
              </div>
            </header>
            \(body)
            """)
    }

    static func html(error: DiskLoadError, filename: String) -> String {
        page("""
            <header>
              <div class=icon>💾</div>
              <div>
                <h1>\(escape(filename))</h1>
                <div class=facts>\(escape(error.title))</div>
                <div class=note>\(escape(error.message))</div>
              </div>
            </header>
            """)
    }

    /// The file as text, when it is text and not a disk
    static func plainText(_ data: Data) -> String? {
        guard !data.isEmpty, data.count < 4 * 1024 * 1024,
              !data.prefix(4096).contains(0),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    // MARK: - Pieces

    private static func appendRows(_ entries: [DiskCatalogEntry], depth: Int, to rows: inout [String]) {
        for entry in entries {
            guard rows.count <= maximumRows else { return }
            let indent = depth == 0 ? "" : " style=\"padding-left:\(8 + depth * 18)px\""
            if entry.isDirectory {
                rows.append("<tr class=dir><td\(indent)>📁 \(escape(entry.name))</td><td>Folder</td><td></td><td></td><td>\(escape(entry.modificationDate ?? ""))</td></tr>")
                appendRows(entry.children ?? [], depth: depth + 1, to: &rows)
            } else {
                let aux = String(format: "$%04X", entry.auxType)
                rows.append("<tr><td\(indent)>\(escape(entry.name))</td><td>\(escape(entry.typeDescription))</td><td class=num>\(aux)</td><td class=num>\(escape(sizeText(entry.size)))</td><td>\(escape(entry.modificationDate ?? ""))</td></tr>")
            }
        }
    }

    private static func icon(for medium: LoadedDisk.Medium) -> String {
        switch medium {
        case .floppy525, .floppy35: return "💾"
        case .hardDisk: return "🗄️"
        case .archive: return "📦"
        }
    }

    /// Apple II sizes in 1024-byte kilobytes, so a 5.25" disk reads 140 KB
    static func sizeText(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func page(_ content: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
        :root { color-scheme: light dark; --text: #1d1d1f; --dim: #6e6e73; --line: #e5e5ea; --stripe: #f5f5f7; --warn: #b25000; }
        @media (prefers-color-scheme: dark) {
          :root { --text: #f5f5f7; --dim: #a1a1a6; --line: #3a3a3c; --stripe: #232325; --warn: #ffb340; }
        }
        body { font: 13px -apple-system, sans-serif; color: var(--text); margin: 20px 24px; }
        header { display: flex; gap: 16px; align-items: flex-start; margin-bottom: 18px; }
        .icon { font-size: 44px; line-height: 1; }
        h1 { font-size: 20px; margin: 2px 0 2px; font-family: ui-monospace, Menlo, monospace; }
        .file, .facts { color: var(--dim); }
        .note { color: var(--warn); margin-top: 6px; }
        table { border-collapse: collapse; width: 100%; }
        th { text-align: left; font-weight: 600; color: var(--dim); border-bottom: 1px solid var(--line); padding: 4px 8px; }
        td { padding: 3px 8px; white-space: nowrap; }
        td:first-child { font-family: ui-monospace, Menlo, monospace; }
        tbody tr:nth-child(even) { background: var(--stripe); }
        .num { text-align: right; font-variant-numeric: tabular-nums; }
        .dir td:first-child { font-weight: 600; }
        .more, .empty { color: var(--dim); }
        </style></head>
        <body>\(content)</body></html>
        """
    }
}
