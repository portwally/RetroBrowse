//
//  DiskCatalogModels.swift
//  ProBrowse
//
//  Data models for disk catalog browsing
//

import Foundation

// MARK: - Disk Catalog Entry

struct DiskCatalogEntry: Identifiable, Codable {
    let id: UUID
    let name: String
    let fileType: UInt8
    let fileTypeString: String
    let auxType: UInt16
    let size: Int
    let blocks: Int?
    let loadAddress: Int?
    let length: Int?
    let data: Data
    let isImage: Bool
    let isDirectory: Bool
    let children: [DiskCatalogEntry]?
    let modificationDate: String?
    let creationDate: String?

    // Extended ProDOS metadata
    let storageType: UInt8?
    let keyPointer: Int?
    let accessFlags: UInt8?
    let version: UInt8?
    let minVersion: UInt8?
    let headerPointer: Int?  // VDH/SDH pointer for directories

    // Resource fork data (for extended files, storage type 5)
    let resourceForkData: Data?

    // Path of the directory that holds this entry, e.g. "/" or "/SYSTEM/"
    let parentPath: String

    // DOS 3.3 lock flag
    let isLocked: Bool

    /// Path of this entry when it is a directory, e.g. "/SYSTEM/"
    var directoryPath: String {
        return parentPath + name + "/"
    }

    init(id: UUID = UUID(), name: String, fileType: UInt8, fileTypeString: String, auxType: UInt16 = 0, size: Int, blocks: Int?, loadAddress: Int?, length: Int?, data: Data, isImage: Bool, isDirectory: Bool, children: [DiskCatalogEntry]?, modificationDate: String? = nil, creationDate: String? = nil, storageType: UInt8? = nil, keyPointer: Int? = nil, accessFlags: UInt8? = nil, version: UInt8? = nil, minVersion: UInt8? = nil, headerPointer: Int? = nil, resourceForkData: Data? = nil, parentPath: String = "/", isLocked: Bool = false) {
        self.id = id
        self.name = name
        self.fileType = fileType
        self.fileTypeString = fileTypeString
        self.auxType = auxType
        self.size = size
        self.blocks = blocks
        self.loadAddress = loadAddress
        self.length = length
        self.data = data
        self.isImage = isImage
        self.isDirectory = isDirectory
        self.children = children
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.storageType = storageType
        self.keyPointer = keyPointer
        self.accessFlags = accessFlags
        self.version = version
        self.minVersion = minVersion
        self.headerPointer = headerPointer
        self.resourceForkData = resourceForkData
        self.parentPath = parentPath
        self.isLocked = isLocked
    }

    // MARK: - Storage Type Descriptions

    var storageTypeDescription: String {
        guard let st = storageType else { return "Unknown" }
        switch st {
        case 0x00: return "Deleted"
        case 0x01: return "Seedling"
        case 0x02: return "Sapling"
        case 0x03: return "Tree"
        case 0x05: return "Extended"
        case 0x0D: return "Subdirectory"
        case 0x0E: return "Subdirectory Header"
        case 0x0F: return "Volume Directory Header"
        default: return String(format: "$%02X", st)
        }
    }

    // MARK: - Access Flags Description

    var accessFlagsDescription: String {
        guard let flags = accessFlags else { return "Unknown" }
        var parts: [String] = []
        if flags & 0x80 != 0 { parts.append("destroy") }
        if flags & 0x40 != 0 { parts.append("rename") }
        if flags & 0x20 != 0 { parts.append("changed") }
        if flags & 0x02 != 0 { parts.append("write") }
        if flags & 0x01 != 0 { parts.append("read") }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }
    
    var sizeString: String {
        if size < 1024 {
            return "\(size) B"
        } else if size < 1024 * 1024 {
            return String(format: "%.1f KB", Double(size) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(size) / (1024.0 * 1024.0))
        }
    }
    
    var fileTypeInfo: ProDOSFileTypeInfo {
        let aux = loadAddress.map { UInt16(clamping: $0) } ?? 0
        return ProDOSFileTypeInfo.getFileTypeInfo(fileType: fileType, auxType: aux)
    }
    
    var icon: String {
        if isDirectory { return "📁" }
        return fileTypeInfo.icon
    }
    
    var typeDescription: String {
        if isDirectory { return "Folder" }
        return fileTypeInfo.shortName
    }
}

// MARK: - Disk Catalog

struct DiskCatalog: Codable {
    let diskName: String
    let diskFormat: String
    let diskSize: Int
    let entries: [DiskCatalogEntry]
    
    var rootEntries: [DiskCatalogEntry] {
        return entries
    }
    
    var totalFiles: Int {
        countFiles(in: entries)
    }
    
    var imageFiles: Int {
        countImages(in: entries)
    }
    
    var allEntries: [DiskCatalogEntry] {
        return flattenEntries(entries)
    }
    
    private func countFiles(in entries: [DiskCatalogEntry]) -> Int {
        var count = 0
        for entry in entries {
            if !entry.isDirectory { count += 1 }
            if let children = entry.children {
                count += countFiles(in: children)
            }
        }
        return count
    }
    
    private func countImages(in entries: [DiskCatalogEntry]) -> Int {
        var count = 0
        for entry in entries {
            if entry.isImage { count += 1 }
            if let children = entry.children {
                count += countImages(in: children)
            }
        }
        return count
    }
    
    private func flattenEntries(_ entries: [DiskCatalogEntry]) -> [DiskCatalogEntry] {
        var result: [DiskCatalogEntry] = []
        for entry in entries {
            result.append(entry)
            if let children = entry.children {
                result.append(contentsOf: flattenEntries(children))
            }
        }
        return result
    }
}

// MARK: - Archive Catalogs

/// A file taken out of an archive, before it is placed in a catalog
struct ArchiveFile {
    /// Name, or a partial pathname using `separator`
    let path: String
    let separator: Character
    let fileType: UInt8
    let auxType: UInt16
    let data: Data
    let resourceFork: Data?
}

extension DiskCatalog {
    /// Builds a catalog from the files of an archive, turning pathnames into directories
    static func fromArchive(name: String, format: String, files: [ArchiveFile]) -> DiskCatalog {
        let items = files.map { file in
            (components: file.path.split(separator: file.separator).map(String.init), file: file)
        }.filter { !$0.components.isEmpty }
        
        return DiskCatalog(
            diskName: name,
            diskFormat: format,
            diskSize: files.reduce(0) { $0 + $1.data.count },
            entries: archiveEntries(items, parentPath: "/")
        )
    }
    
    private static func archiveEntries(_ items: [(components: [String], file: ArchiveFile)], parentPath: String) -> [DiskCatalogEntry] {
        var entries: [DiskCatalogEntry] = []
        var directoryNames: [String] = []
        var directoryItems: [String: [(components: [String], file: ArchiveFile)]] = [:]
        
        for item in items {
            let name = item.components[0]
            let file = item.file
            
            if item.components.count > 1 {
                if directoryItems[name] == nil { directoryNames.append(name) }
                directoryItems[name, default: []].append((Array(item.components.dropFirst()), file))
                continue
            }
            
            entries.append(DiskCatalogEntry(
                name: name,
                fileType: file.fileType,
                fileTypeString: ProDOSFileTypeInfo.getFileTypeInfo(fileType: file.fileType, auxType: file.auxType).shortName,
                auxType: file.auxType,
                size: file.data.count,
                blocks: nil,
                loadAddress: Int(file.auxType),
                length: file.data.count,
                data: file.data,
                isImage: [0x08, 0xC0, 0xC1].contains(file.fileType),
                isDirectory: false,
                children: nil,
                resourceForkData: file.resourceFork,
                parentPath: parentPath
            ))
        }
        
        for name in directoryNames {
            let children = archiveEntries(directoryItems[name] ?? [], parentPath: parentPath + name + "/")
            entries.append(DiskCatalogEntry(
                name: name,
                fileType: 0x0F,
                fileTypeString: "DIR",
                size: 0,
                blocks: nil,
                loadAddress: nil,
                length: nil,
                data: Data(),
                isImage: false,
                isDirectory: true,
                children: children,
                parentPath: parentPath
            ))
        }
        
        return entries
    }
}
