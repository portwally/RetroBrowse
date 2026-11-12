//
//  DiskImageLoader.swift
//  ProBrowse
//
//  Turns the bytes of a disk image or archive into a catalog: unwraps Binary II, ShrinkIt,
//  gzip, ZIP and DiskCopy 4.2, decodes WOZ, and tries the ProDOS, Pascal and DOS 3.3 parsers.
//  Used by the panes and by the Quick Look extensions, so it touches no UI.
//

import Foundation

struct LoadedDisk {
    let catalog: DiskCatalog
    /// True when the catalog was read from a copy (archive, WOZ, DiskCopy), so the file can't be written
    let isArchiveBacked: Bool
    var woz: WOZImage? = nil
    /// Archived files that could not be extracted
    var unreadable: [String] = []
}

struct DiskLoadError: Error {
    let title: String
    let message: String
}

enum DiskImageLoader {

    static func load(_ data: Data, filename: String) throws -> LoadedDisk {
        var originalData = data
        var extractedFromArchive = false
        var extractedFromNuFX = false

        let ext = (filename as NSString).pathExtension.lowercased()
        let isDSK = ext == "dsk"
        let isDO = ext == "do"
        let isVOL = ext == "vol"

        // Binary II (.bny, .bqy, .bii). Binary II can also wrap a ShrinkIt archive (.bxy).
        if ["bny", "bqy", "bii"].contains(ext) || BinaryIIArchive.isBinaryII(originalData) {
            if !NuFXArchive.isNuFXArchive(originalData) {
                let archive = BinaryIIArchive(data: originalData)
                var foundDiskImage = false
                if (try? archive.parse()) != nil {
                    // The first file that looks like a disk image
                    for entry in archive.entries {
                        if let extracted = archive.extractData(for: entry),
                           [143360, 163840, 819200, 1638400].contains(extracted.count) ||
                           entry.filename.lowercased().hasSuffix(".dsk") ||
                           entry.filename.lowercased().hasSuffix(".po") {
                            originalData = extracted
                            extractedFromArchive = true
                            foundDiskImage = true
                            break
                        }
                    }
                }

                // No disk image inside: show the archived files themselves
                if !foundDiskImage && !archive.entries.isEmpty {
                    let files = archive.entries.filter { $0.storageType != 0x0D }.map { entry in
                        ArchiveFile(path: entry.filename, separator: "/", fileType: entry.fileType, auxType: entry.auxType,
                                    data: archive.extractData(for: entry) ?? Data(), resourceFork: nil)
                    }
                    return LoadedDisk(catalog: DiskCatalog.fromArchive(name: filename, format: DiskCatalog.binaryIIArchiveFormat, files: files),
                                      isArchiveBacked: true)
                }
            }
        }

        // ShrinkIt (.sdk, .shk, .bxy)
        if ["sdk", "shk", "bxy"].contains(ext) || NuFXArchive.isNuFXArchive(originalData) {
            let archive = NuFXArchive(data: originalData)
            var foundDiskImage = false
            if (try? archive.parse()) != nil {
                // A disk image, or a file the size of one
                for record in archive.records {
                    if let diskThread = record.threads.first(where: { $0.isDiskImage }),
                       let extracted = try? archive.extractThread(diskThread, of: record) {
                        originalData = extracted
                        extractedFromArchive = true
                        extractedFromNuFX = true
                        foundDiskImage = true
                        break
                    } else if let dataThread = record.dataForkThread,
                              record.threads.first(where: { $0.isDiskImage }) == nil,
                              let extracted = try? archive.extractThread(dataThread, of: record),
                              [143360, 819200, 163840].contains(extracted.count) {
                        originalData = extracted
                        extractedFromArchive = true
                        foundDiskImage = true
                        break
                    }
                }
            }

            // No disk image inside: show the archived files themselves
            if !foundDiskImage && !archive.records.isEmpty {
                var files: [ArchiveFile] = []
                var unreadable: [String] = []
                for record in archive.records {
                    guard let data = try? archive.extractData(for: record) else {
                        unreadable.append(record.filename)
                        continue
                    }
                    let resourceFork = record.resourceForkThread.flatMap { try? archive.extractThread($0, of: record) }
                    let separator = record.separatorChar & 0x7F
                    files.append(ArchiveFile(path: record.filename,
                                             separator: Character(UnicodeScalar(separator < 0x20 ? 0x2F : separator)),
                                             fileType: UInt8(truncatingIfNeeded: record.fileType),
                                             auxType: UInt16(truncatingIfNeeded: record.auxType),
                                             data: data, resourceFork: resourceFork))
                }
                guard !files.isEmpty else {
                    throw DiskLoadError(title: "Could Not Open Archive",
                                        message: "Nothing in \(filename) could be extracted. The archive may be damaged.")
                }
                return LoadedDisk(catalog: DiskCatalog.fromArchive(name: filename, format: DiskCatalog.shrinkItArchiveFormat, files: files),
                                  isArchiveBacked: true, unreadable: unreadable)
            }
        }

        // gzip (.gz)
        if ext == "gz" || GzipArchive.isGzip(originalData) {
            if let decompressed = GzipArchive.decompress(originalData) {
                originalData = decompressed
                extractedFromArchive = true
            }
        }

        // ZIP: the first file that looks like a disk image
        if ext == "zip" || ZipArchive.isZip(originalData) {
            for entry in ZipArchive.parseEntries(from: originalData) where !entry.filename.hasSuffix("/") {
                let name = entry.filename.lowercased()
                if let extracted = ZipArchive.extractEntry(entry, from: originalData),
                   [143360, 163840, 819200, 1638400].contains(extracted.count) ||
                   [".dsk", ".po", ".2mg", ".do"].contains(where: { name.hasSuffix($0) }) {
                    originalData = extracted
                    extractedFromArchive = true
                    break
                }
            }
        }

        // WOZ: the bits of each track, decoded into sectors before any parser sees them
        if ext == "woz" || WOZImage.isWOZ(originalData) {
            return try loadWOZ(originalData, filename: filename)
        }

        // DiskCopy 4.2 (.img / .image): strip the 84-byte header. Changing the disk would
        // break DiskCopy's checksum, so these open read-only.
        if let userData = DiskImageParser.diskCopy42UserData(originalData) {
            originalData = userData
            extractedFromArchive = true
        }

        func loaded(_ catalog: DiskCatalog, archiveBacked: Bool? = nil) -> LoadedDisk {
            LoadedDisk(catalog: catalog, isArchiveBacked: archiveBacked ?? extractedFromArchive)
        }

        // .vol: UCSD Pascal first
        if isVOL, let catalog = try? UCSDPascalParser.parseUCSD(data: originalData, diskName: filename) {
            return loaded(catalog)
        }

        // .po, .2mg, .hdv: ProDOS
        if !isDSK && !isDO && !isVOL,
           let catalog = try? DiskImageParser.parseProDOS(data: originalData, diskName: filename) {
            return loaded(catalog)
        }

        // .dsk / .do: ProDOS, then Pascal, then DOS 3.3
        if isDSK || isDO {
            if let catalog = try? DiskImageParser.parseProDOS(data: originalData, diskName: filename) {
                return loaded(catalog)
            }
            if let catalog = try? UCSDPascalParser.parseUCSD(data: originalData, diskName: filename) {
                return loaded(catalog)
            }
            if let catalog = try? DiskImageParser.parseDOS33(data: originalData, diskName: filename) {
                return loaded(catalog)
            }
        }

        // ShrinkIt stores a disk in ProDOS block order. A Pascal volume reads as is;
        // a DOS 3.3 disk needs its sectors put back in DOS order first.
        if extractedFromNuFX {
            if let catalog = try? UCSDPascalParser.parseUCSD(data: originalData, diskName: filename) {
                return loaded(catalog, archiveBacked: true)
            }
            if let reordered = DiskImageParser.dosOrdered(fromProDOSOrder: originalData),
               let catalog = try? DiskImageParser.parseDOS33(data: reordered, diskName: filename) {
                return loaded(catalog, archiveBacked: true)
            }
        }

        // Last try: DOS 3.3
        if let catalog = try? DiskImageParser.parseDOS33(data: originalData, diskName: filename) {
            return loaded(catalog)
        }

        throw DiskLoadError(title: "Could Not Open Disk Image",
                            message: "\(filename) is not a disk image or archive that RetroBrowse can read.")
    }

    /// Decodes a WOZ image and reads the file system on it. Writing would mean encoding
    /// whole tracks again, so these are always read-only.
    private static func loadWOZ(_ data: Data, filename name: String) throws -> LoadedDisk {
        let title = "Could Not Open WOZ Image"
        let woz: WOZImage
        do {
            woz = try WOZImage(data: data)
        } catch {
            throw DiskLoadError(title: title, message: "\(name): \(error.localizedDescription)")
        }
        let decoded = "\(woz.sectorsDecoded) of \(woz.sectorsExpected) sectors could be read."
        if woz.kind == .disk525Sector13 {
            throw DiskLoadError(title: title, message: "\(name) is a 13-sector DOS 3.2 disk, which RetroBrowse cannot read yet. \(decoded)")
        }
        if let image = woz.sectorImage {
            var catalog = (try? DiskImageParser.parseProDOS(data: image, diskName: name)) ??
                          (try? UCSDPascalParser.parseUCSD(data: image, diskName: name))
            if catalog == nil && woz.kind == .disk525Sector16 {
                catalog = try? DiskImageParser.parseDOS33(data: image, diskName: name)
            }
            if let catalog = catalog {
                return LoadedDisk(catalog: catalog, isArchiveBacked: true, woz: woz)
            }
        }
        let damaged = woz.checksumMatches ? "" : " Its checksum does not match its contents either."
        if woz.sectorsDecoded == woz.sectorsExpected {
            throw DiskLoadError(title: title, message: "No ProDOS, DOS 3.3 or Pascal file system was found on \(name). \(decoded)\(damaged)")
        }
        throw DiskLoadError(title: title, message: "No standard file system was found on \(name). This disk may be copy-protected. \(decoded)\(damaged)")
    }
}
