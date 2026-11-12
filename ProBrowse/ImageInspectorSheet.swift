//
//  ImageInspectorSheet.swift
//  ProBrowse
//
//  Sheet for inspecting disk image properties
//

import SwiftUI
import Combine

struct ImageInspectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: DiskPaneViewModel
    
    @State private var verificationResult: String?
    @State private var isVerifying = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Disk Image Inspector")
                .font(.title2)
                .fontWeight(.semibold)
            
            if let catalog = viewModel.catalog, let imagePath = viewModel.diskImagePath {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Image Info
                        Group {
                            InfoRow(label: "Volume Name", value: catalog.diskName)
                            InfoRow(label: "Format", value: catalog.diskFormat)
                            InfoRow(label: "File", value: imagePath.lastPathComponent)
                            InfoRow(label: "Path", value: imagePath.path)
                            InfoRow(label: "Size", value: formatBytes(catalog.diskSize))
                        }
                    
                        Divider()

                        if let woz = viewModel.wozImage {
                            WOZDetails(woz: woz)
                            Divider()
                        }
                    
                        // Statistics
                        Group {
                            InfoRow(label: "Total Files", value: "\(catalog.totalFiles)")
                            InfoRow(label: "Image Files", value: "\(catalog.imageFiles)")
                            InfoRow(label: "Root Entries", value: "\(catalog.entries.count)")
                        }
                    
                        Divider()
                    
                        // Actions
                        VStack(alignment: .leading, spacing: 12) {
                            Button(action: verifyImage) {
                                HStack {
                                    if isVerifying {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                            .frame(width: 16, height: 16)
                                    } else {
                                        Image(systemName: "checkmark.shield")
                                    }
                                    Text("Verify Image Integrity")
                                }
                            }
                            .disabled(isVerifying)
                        
                            if let result = verificationResult {
                                Text(result)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(result.contains("✅") ? .green : .red)
                                    .padding(.leading, 24)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        
                            Button(action: {
                                NSWorkspace.shared.activateFileViewerSelecting([imagePath])
                            }) {
                                HStack {
                                    Image(systemName: "folder")
                                    Text("Show in Finder")
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No disk image loaded")
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            HStack {
                Spacer()
                
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .sheetFrame(width: 520, height: 600)
    }
    
    private func verifyImage() {
        guard let imagePath = viewModel.diskImagePath else { return }

        isVerifying = true
        verificationResult = nil

        // The view model belongs to the main thread; take what the check needs before leaving it
        let catalog = viewModel.catalog
        let isArchive = viewModel.isArchiveBacked

        DispatchQueue.global(qos: .userInitiated).async {
            let result = verifyDiskImage(at: imagePath, catalog: catalog, isArchive: isArchive)
            DispatchQueue.main.async {
                isVerifying = false
                verificationResult = result
            }
        }
    }

    /// Native disk image verification
    private func verifyDiskImage(at url: URL, catalog: DiskCatalog?, isArchive: Bool) -> String {
        // Check 1: File exists and is readable
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "❌ File not found"
        }

        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return "❌ File is not readable"
        }

        // Check 2: Read file data
        guard let data = try? Data(contentsOf: url) else {
            return "❌ Failed to read file data"
        }

        // Check 3: Validate file size
        let validSizes: [Int: String] = [
            143360: "140KB (5.25\" floppy)",
            819200: "800KB (3.5\" floppy)",
            1474560: "1.44MB (3.5\" HD floppy)",
            33553920: "32MB (ProDOS volume)"
        ]

        var sizeValid = false
        var sizeDescription = ""

        // An archive is as large as its compressed contents; only the image inside has a fixed size
        if isArchive {
            sizeValid = true
            sizeDescription = "archive, \(formatBytes(data.count))"
        } else if let desc = validSizes[data.count] {
            sizeValid = true
            sizeDescription = desc
        } else {
            // Check 2IMG container (variable header size)
            if data.count >= 64 && data.prefix(4) == Data([0x32, 0x49, 0x4D, 0x47]) {
                let headerSize = Int(data[8]) | (Int(data[9]) << 8)
                let innerSize = data.count - headerSize
                if let desc = validSizes[innerSize] {
                    sizeValid = true
                    sizeDescription = "2IMG container with \(desc)"
                } else if innerSize > 0 && innerSize % 512 == 0 {
                    sizeValid = true
                    sizeDescription = "2IMG container (\(innerSize / 1024)KB)"
                }
            }
            // Check if size is block-aligned (multiple of 512)
            else if data.count % 512 == 0 && data.count >= 143360 {
                sizeValid = true
                sizeDescription = "\(data.count / 1024)KB (block-aligned)"
            }
        }

        guard sizeValid else {
            return "❌ Invalid file size: \(data.count) bytes (not a recognized disk image format)"
        }

        // Check 4: Validate format-specific structure
        var formatChecks: [String] = []

        if data.count >= 64 && data.prefix(4) == Data([0x32, 0x49, 0x4D, 0x47]) {
            formatChecks.append("2IMG header present")
        }

        // Check for ProDOS volume header
        if let catalog = catalog {
            if catalog.diskFormat.contains("ProDOS") {
                formatChecks.append("ProDOS volume detected: \(catalog.diskName)")
                formatChecks.append("Format: \(catalog.diskFormat)")
                formatChecks.append("Files: \(catalog.totalFiles)")
            } else if catalog.diskFormat.contains("DOS 3.3") {
                formatChecks.append("DOS 3.3 volume detected")
                formatChecks.append("Files: \(catalog.totalFiles)")
            } else if catalog.diskFormat.contains("UCSD") {
                formatChecks.append("UCSD Pascal volume detected: \(catalog.diskName)")
                formatChecks.append("Files: \(catalog.totalFiles)")
            } else {
                formatChecks.append("Format: \(catalog.diskFormat)")
            }
        }

        // All checks passed
        var result = "✅ Image verified successfully\n"
        result += "   Size: \(sizeDescription)\n"
        for check in formatChecks {
            result += "   \(check)\n"
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label + ":")
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .leading)
            
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.body, design: .monospaced))
    }
}

#Preview {
    ImageInspectorSheet(viewModel: DiskPaneViewModel())
}

// MARK: - WOZ details

/// What a WOZ image says about itself: its INFO chunk, how much of it could be read,
/// and the title, publisher and other details from its META chunk
private struct WOZDetails: View {
    let woz: WOZImage

    /// META keys from the WOZ 2 reference, in a sensible reading order
    private static let metaLabels: [(key: String, label: String)] = [
        ("title", "Title"), ("subtitle", "Subtitle"), ("publisher", "Publisher"),
        ("developer", "Developer"), ("copyright", "Copyright"), ("version", "Version"),
        ("language", "Language"), ("requires_machine", "Requires"), ("requires_ram", "RAM"),
        ("notes", "Notes"), ("side", "Side"), ("side_name", "Side Name"),
        ("contributor", "Contributor"), ("image_date", "Imaged"),
    ]

    private var diskKind: String {
        switch woz.kind {
        case .disk525Sector16: return "5.25\" disk, 16 sectors"
        case .disk525Sector13: return "5.25\" disk, 13 sectors (DOS 3.2)"
        case .disk35: return "3.5\" disk"
        }
    }

    /// Tracks that held fewer readable sectors than they should, e.g. "1, 3, 5, 34"
    private var unreadTracks: String? {
        let tracks = woz.tracks.filter { $0.decoded < $0.expected }
        guard !tracks.isEmpty else { return nil }
        let names = tracks.map { woz.kind == .disk35 ? "\($0.track)/\($0.side)" : "\($0.track)" }
        return names.count > 20 ? names.prefix(20).joined(separator: ", ") + " … (\(names.count) tracks)"
                                : names.joined(separator: ", ")
    }

    var body: some View {
        Group {
            InfoRow(label: "WOZ", value: "Version \(woz.version), \(diskKind)")
            if !woz.info.creator.isEmpty {
                InfoRow(label: "Made With", value: woz.info.creator)
            }
            InfoRow(label: "Sectors Read", value: "\(woz.sectorsDecoded) of \(woz.sectorsExpected)")
            if let tracks = unreadTracks {
                InfoRow(label: "Unread Tracks", value: tracks)
            }
            InfoRow(label: "Checksum", value: woz.checksumMatches ? "OK" : "Does not match the contents")
            if woz.info.isWriteProtected {
                InfoRow(label: "Write Protected", value: "Yes")
            }
            let known = Set(Self.metaLabels.map(\.key))
            ForEach(Self.metaLabels.filter { !(woz.metadata[$0.key] ?? "").isEmpty }, id: \.key) { item in
                InfoRow(label: item.label, value: woz.metadata[item.key] ?? "")
            }
            ForEach(woz.metadata.keys.filter { !known.contains($0) && !(woz.metadata[$0] ?? "").isEmpty }.sorted(), id: \.self) { key in
                InfoRow(label: key.replacingOccurrences(of: "_", with: " ").capitalized, value: woz.metadata[key] ?? "")
            }
        }
    }
}
