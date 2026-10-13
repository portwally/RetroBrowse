//
//  FileInfoSheet.swift
//  ProBrowse
//
//  Sheet for inspecting individual file/directory properties
//

import SwiftUI

struct FileInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: DiskCatalogEntry
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(entry.isDirectory ? "📂 Directory Info" : "📄 File Info")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Divider()
            
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Basic Info
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Basic Information")
                        
                        InfoRow(label: "Name", value: entry.name)
                        InfoRow(label: "Type", value: entry.isDirectory ? "Directory" : entry.fileTypeString)
                        InfoRow(label: "Size", value: formatBytes(entry.size))
                        
                        if !entry.isDirectory, let blocks = entry.blocks {
                            InfoRow(label: "Blocks Used", value: "\(blocks)")
                        }
                    }
                    
                    Divider()
                    
                    // Technical Details
                    if !entry.isDirectory {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Technical Details")
                            
                            InfoRow(label: "File Type", value: String(format: "$%02X", entry.fileType))
                            InfoRow(label: "Aux Type", value: String(format: "$%04X", entry.auxType))
                            
                            if let description = fileTypeDescription {
                                InfoRow(label: "Description", value: description)
                            }
                        }
                        
                        Divider()
                    }
                    
                    // Dates
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Dates")
                        
                        if let created = entry.creationDate {
                            InfoRow(label: "Created", value: created)
                        } else {
                            InfoRow(label: "Created", value: "—")
                        }
                        
                        if let modified = entry.modificationDate {
                            InfoRow(label: "Modified", value: modified)
                        } else {
                            InfoRow(label: "Modified", value: "—")
                        }
                    }
                    
                    // Directory Info
                    if entry.isDirectory {
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Directory Contents")
                            
                            let childCount = entry.children?.count ?? 0
                            InfoRow(label: "Items", value: "\(childCount)")
                            
                            if let children = entry.children, !children.isEmpty {
                                let files = children.filter { !$0.isDirectory }.count
                                let dirs = children.filter { $0.isDirectory }.count
                                
                                InfoRow(label: "Files", value: "\(files)")
                                InfoRow(label: "Subdirectories", value: "\(dirs)")
                                
                                let totalSize = children.reduce(0) { $0 + $1.size }
                                InfoRow(label: "Total Size", value: formatBytes(totalSize))
                            }
                        }
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Footer
            HStack {
                Spacer()
                
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 500, height: 600)
    }
    
    private var fileTypeDescription: String? {
        // Get human-readable description for common file types
        switch entry.fileType {
        case 0x04: return "Text File"
        case 0x06: return "Binary File"
        case 0x0F: return "Directory"
        case 0x19: return "AppleWorks Database"
        case 0x1A: return "AppleWorks Word Processor"
        case 0x1B: return "AppleWorks Spreadsheet"
        case 0xB0: return "Source Code (SRC)"
        case 0xC0: return "Packed Picture (PNT)"
        case 0xC1: return "Picture (PIC)"
        case 0xEF: return "Pascal Area"
        case 0xF0: return "Command File"
        case 0xFA: return "Integer BASIC"
        case 0xFC: return "Applesoft BASIC"
        case 0xFD: return "Variables File"
        case 0xFE: return "Relocatable Code"
        case 0xFF: return "System File (SYS)"
        default: return nil
        }
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) bytes"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        }
    }
}

// MARK: - Supporting Views

struct SectionHeader: View {
    let title: String
    
    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundColor(.primary)
    }
}

#Preview {
    FileInfoSheet(entry: DiskCatalogEntry(
        name: "EXAMPLE.TXT",
        fileType: 0x04,
        fileTypeString: "TXT",
        auxType: 0x0000,
        size: 2048,
        blocks: 4,
        loadAddress: nil,
        length: nil,
        data: Data(),
        isImage: false,
        isDirectory: false,
        children: nil,
        modificationDate: "12/29/2025 10:30 AM",
        creationDate: "12/20/2025 9:15 AM"
    ))
}
