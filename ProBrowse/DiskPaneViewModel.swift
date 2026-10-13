//
//  DiskPaneViewModel.swift
//  ProBrowse
//
//  ViewModel for managing disk pane state and operations
//

import SwiftUI
import Foundation
import Combine

class DiskPaneViewModel: ObservableObject {
    @Published var catalog: DiskCatalog?
    @Published var diskImagePath: URL?
    @Published var selectedEntries: Set<UUID> = []
    @Published var expandAllTrigger = false
    @Published var showingFilePicker = false
    @Published var showingFileInfo = false
    @Published var fileInfoEntry: DiskCatalogEntry?
    @Published var showingChangeFileType = false
    @Published var changeFileTypeEntry: DiskCatalogEntry?
    @Published var showingInspector = false
    @Published var inspectorEntry: DiskCatalogEntry?

    // Navigation state
    @Published var currentDirectory: DiskCatalogEntry?
    @Published var navigationPath: [DiskCatalogEntry] = []
    
    /// True when the catalog came from an image extracted out of an archive
    /// (.shk, .bny, .gz, .zip). The file on disk is then not a raw image and must not be written to.
    @Published private(set) var isArchiveBacked = false
    
    /// Size of the opened file on disk, for the pane header
    @Published private(set) var diskImageFileSize: Int?
    
    private var lastSelectedEntry: DiskCatalogEntry?
    
    var isAllSelected: Bool {
        guard let catalog = catalog else { return false }
        let allIds = Set(catalog.allEntries.map { $0.id })
        return !allIds.isEmpty && selectedEntries == allIds
    }
    
    var canGoBack: Bool {
        return !navigationPath.isEmpty
    }

    /// Find an entry by its UUID
    func findEntry(by id: UUID) -> DiskCatalogEntry? {
        return catalog?.allEntries.first { $0.id == id }
    }

    /// Check if a single non-directory file is selected for inspection
    var canInspect: Bool {
        guard selectedEntries.count == 1 else { return false }
        guard let selectedId = selectedEntries.first,
              let entry = findEntry(by: selectedId) else { return false }
        return !entry.isDirectory
    }

    /// Show inspector for the given entry
    func showInspector(_ entry: DiskCatalogEntry) {
        guard !entry.isDirectory else { return }
        inspectorEntry = entry
        showingInspector = true
    }

    /// Show inspector for the currently selected file
    func inspectSelectedFile() {
        guard selectedEntries.count == 1,
              let selectedId = selectedEntries.first,
              let entry = findEntry(by: selectedId),
              !entry.isDirectory else { return }
        showInspector(entry)
    }

    // MARK: - Filesystem Detection Properties
    
    /// Check if the current disk is DOS 3.3 format
    var isDOS33: Bool {
        return catalog?.diskFormat.contains("DOS 3.3") ?? false
    }
    
    /// Check if the current disk is UCSD Pascal format
    var isUCSDPascal: Bool {
        return catalog?.diskFormat.contains("UCSD Pascal") ?? false
    }
    
    // MARK: - Load Disk Image
    
    /// File extensions that open as a disk image or archive rather than being imported as a file
    static let openableExtensions = ["po", "2mg", "hdv", "dsk", "do", "vol",
                                     "shk", "sdk", "bxy", "bny", "bqy", "bii", "gz", "zip"]
    
    func loadDiskImage(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            print("Failed to access security scoped resource")
            return
        }

        defer { url.stopAccessingSecurityScopedResource() }

        do {
            var originalData = try Data(contentsOf: url)
            var extractedFromArchive = false
            var extractedFromNuFX = false

            let ext = url.pathExtension.lowercased()
            let isDSK = ext == "dsk"
            let isDO = ext == "do"
            let isVOL = ext == "vol"

            // Check for Binary II archives (.bny, .bqy, .bii)
            // Note: Binary II can also wrap NuFX archives (.bxy)
            if ["bny", "bqy", "bii"].contains(ext) || BinaryIIArchive.isBinaryII(originalData) {
                // Check if it's a Binary II wrapping NuFX (common .bxy pattern)
                if !NuFXArchive.isNuFXArchive(originalData) {
                    print("📦 Detected Binary II archive: \(url.lastPathComponent)")

                    let archive = BinaryIIArchive(data: originalData)
                    var foundDiskImage = false
                    do {
                        try archive.parse()
                        print("   Found \(archive.entries.count) entries")

                        // Extract first disk image-like file
                        for entry in archive.entries {
                            if let extracted = archive.extractData(for: entry) {
                                // Check if it's a plausible disk image
                                if [143360, 163840, 819200, 1638400].contains(extracted.count) ||
                                   entry.filename.lowercased().hasSuffix(".dsk") ||
                                   entry.filename.lowercased().hasSuffix(".po") {
                                    print("✅ Extracted disk image: \(entry.filename) (\(extracted.count) bytes)")
                                    originalData = extracted
                                    extractedFromArchive = true
                                    foundDiskImage = true
                                    break
                                }
                            }
                        }
                    } catch {
                        print("❌ Binary II extraction failed: \(error)")
                    }
                    
                    // No disk image inside: show the archived files themselves
                    if !foundDiskImage && !archive.entries.isEmpty {
                        let files = archive.entries.filter { $0.storageType != 0x0D }.map { entry in
                            ArchiveFile(path: entry.filename, separator: "/", fileType: entry.fileType, auxType: entry.auxType,
                                        data: archive.extractData(for: entry) ?? Data(), resourceFork: nil)
                        }
                        finishLoading(DiskCatalog.fromArchive(name: url.lastPathComponent, format: "Binary II Archive", files: files),
                                      from: url, isArchiveBacked: true)
                        return
                    }
                }
            }

            // Check for NuFX archives (.sdk, .shk, .bxy)
            let isNuFXExtension = ["sdk", "shk", "bxy"].contains(ext)
            if isNuFXExtension || NuFXArchive.isNuFXArchive(originalData) {
                print("📦 Detected NuFX archive: \(url.lastPathComponent)")

                // Parse the archive
                let archive = NuFXArchive(data: originalData)
                var foundDiskImage = false
                do {
                    try archive.parse()

                    // Find disk image or first data file
                    for record in archive.records {
                        if let diskThread = record.threads.first(where: { $0.isDiskImage }),
                           let extracted = try? archive.extractThread(diskThread, of: record) {
                            print("✅ Extracted disk image: \(record.filename) (\(extracted.count) bytes)")
                            originalData = extracted
                            extractedFromArchive = true
                            foundDiskImage = true
                            extractedFromNuFX = true
                            break
                        } else if let dataThread = record.dataForkThread,
                                  record.threads.first(where: { $0.isDiskImage }) == nil {
                            // No disk image thread, but has data - try extracting first file
                            if let extracted = try? archive.extractThread(dataThread, of: record) {
                                // Check if it looks like a disk image (140K, 800K, etc.)
                                if [143360, 819200, 163840].contains(extracted.count) {
                                    print("✅ Extracted data as disk image: \(record.filename) (\(extracted.count) bytes)")
                                    originalData = extracted
                                    extractedFromArchive = true
                                    foundDiskImage = true
                                    break
                                }
                            }
                        }
                    }

                    if archive.records.isEmpty {
                        print("❌ NuFX archive contains no records")
                    }
                } catch {
                    print("❌ NuFX extraction failed: \(error)")
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
                        showError("Could Not Open Archive", "Nothing in \(url.lastPathComponent) could be extracted. The archive may be damaged.")
                        return
                    }
                    finishLoading(DiskCatalog.fromArchive(name: url.lastPathComponent, format: "ShrinkIt Archive", files: files),
                                  from: url, isArchiveBacked: true)
                    reportFailures("Some Files Could Not Be Extracted", unreadable)
                    return
                }
            }

            // Check for gzip compressed files (.gz)
            if ext == "gz" || GzipArchive.isGzip(originalData) {
                print("📦 Detected gzip archive: \(url.lastPathComponent)")
                if let decompressed = GzipArchive.decompress(originalData) {
                    print("✅ Decompressed gzip: \(decompressed.count) bytes")
                    originalData = decompressed
                    extractedFromArchive = true
                } else {
                    print("❌ Gzip decompression failed")
                }
            }

            // Check for ZIP archives (.zip)
            if ext == "zip" || ZipArchive.isZip(originalData) {
                print("📦 Detected ZIP archive: \(url.lastPathComponent)")
                let entries = ZipArchive.parseEntries(from: originalData)
                print("   Found \(entries.count) entries")

                // Find first disk image-like file
                for entry in entries {
                    if !entry.filename.hasSuffix("/") {
                        if let extracted = ZipArchive.extractEntry(entry, from: originalData) {
                            // Check if it's a plausible disk image size
                            if [143360, 163840, 819200, 1638400].contains(extracted.count) ||
                               entry.filename.lowercased().hasSuffix(".dsk") ||
                               entry.filename.lowercased().hasSuffix(".po") ||
                               entry.filename.lowercased().hasSuffix(".2mg") ||
                               entry.filename.lowercased().hasSuffix(".do") {
                                print("✅ Extracted disk image: \(entry.filename) (\(extracted.count) bytes)")
                                originalData = extracted
                                extractedFromArchive = true
                                break
                            }
                        }
                    }
                }
            }

            // For .vol files - try UCSD Pascal first
            if isVOL {
                print("📀 Loading .vol file: \(url.lastPathComponent)")
                if let catalog = try? UCSDPascalParser.parseUCSD(data: originalData, diskName: url.lastPathComponent) {
                    print("✅ Parsed as UCSD Pascal")
                    finishLoading(catalog, from: url, isArchiveBacked: extractedFromArchive)
                    return
                }
            }
            
            // For .po, .2mg, .hdv, .woz - try directly as ProDOS
            if !isDSK && !isDO && !isVOL {
                if let catalog = try? DiskImageParser.parseProDOS(data: originalData, diskName: url.lastPathComponent) {
                    finishLoading(catalog, from: url, isArchiveBacked: extractedFromArchive)
                    return
                }
            }
            
            // For .dsk/.do files - try all three filesystems
            if isDSK || isDO {
                print("📀 Loading .dsk file: \(url.lastPathComponent)")
                
                // Try ProDOS first
                if let catalog = try? DiskImageParser.parseProDOS(data: originalData, diskName: url.lastPathComponent) {
                    print("✅ Parsed as ProDOS")
                    finishLoading(catalog, from: url, isArchiveBacked: extractedFromArchive)
                    return
                }
                
                // Try UCSD Pascal second
                if let catalog = try? UCSDPascalParser.parseUCSD(data: originalData, diskName: url.lastPathComponent) {
                    print("✅ Parsed as UCSD Pascal")
                    finishLoading(catalog, from: url, isArchiveBacked: extractedFromArchive)
                    return
                }
                
                // Try DOS 3.3 last
                if let catalog = try? DiskImageParser.parseDOS33(data: originalData, diskName: url.lastPathComponent) {
                    print("✅ Parsed as DOS 3.3")
                    finishLoading(catalog, from: url, isArchiveBacked: extractedFromArchive)
                    return
                }
                
                print("❌ Could not parse .dsk file")
            }
            
            // ShrinkIt stores a disk in ProDOS block order. A Pascal volume reads as is;
            // a DOS 3.3 disk needs its sectors put back in DOS order first.
            if extractedFromNuFX {
                if let catalog = try? UCSDPascalParser.parseUCSD(data: originalData, diskName: url.lastPathComponent) {
                    finishLoading(catalog, from: url, isArchiveBacked: true)
                    return
                }
                if let reordered = DiskImageParser.dosOrdered(fromProDOSOrder: originalData),
                   let catalog = try? DiskImageParser.parseDOS33(data: reordered, diskName: url.lastPathComponent) {
                    finishLoading(catalog, from: url, isArchiveBacked: true)
                    return
                }
            }
            
            // Fallback: Try as DOS 3.3
            if let catalog = try? DiskImageParser.parseDOS33(data: originalData, diskName: url.lastPathComponent) {
                finishLoading(catalog, from: url, isArchiveBacked: extractedFromArchive)
                return
            }
            
            print("Unknown disk format")
            showError("Could Not Open Disk Image",
                      "\(url.lastPathComponent) is not a disk image or archive that ProBrowse can read.")
            
        } catch {
            print("Error loading disk image: \(error)")
            showError("Could Not Open Disk Image", error.localizedDescription)
        }
    }
    
    /// Adopts a successfully parsed catalog. Nothing is changed when a load fails,
    /// so the path and the catalog always describe the same file.
    private func finishLoading(_ newCatalog: DiskCatalog, from url: URL, isArchiveBacked: Bool) {
        // Stay in the same directory when the same image is reloaded after a change
        let openPath = (url == diskImagePath) ? currentDirectory?.directoryPath : nil
        
        diskImagePath = url
        catalog = newCatalog
        self.isArchiveBacked = isArchiveBacked
        diskImageFileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        lastSelectedEntry = nil
        navigateToRoot()
        
        if let openPath = openPath, let directory = directories(alongPath: openPath).last {
            navigateInto(directory)
        }
    }
    
    // MARK: - Write Helpers
    
    /// Shows an error to the user. Replaceable so the view model can be tested without a window.
    var presentError: (_ title: String, _ message: String) -> Void = { title, message in
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
    
    private func showError(_ title: String, _ message: String) {
        presentError(title, message)
    }
    
    /// Asks the user to confirm a destructive action. Replaceable for the same reason as `presentError`.
    var confirmAction: (_ title: String, _ message: String, _ button: String) -> Bool = { title, message, button in
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    
    /// Shows one alert listing the items that failed, if any
    private func reportFailures(_ title: String, _ failures: [String]) {
        guard !failures.isEmpty else { return }
        var lines = Array(failures.prefix(10))
        if failures.count > lines.count {
            lines.append("…and \(failures.count - lines.count) more")
        }
        showError(title, lines.joined(separator: "\n"))
    }
    
    /// Why this disk cannot be modified, or nil if it can
    private var writeBlockedReason: String? {
        if isUCSDPascal {
            return "UCSD Pascal disks are read-only."
        }
        if isArchiveBacked {
            return "This was opened from an archive and is read-only. Copy the files to a disk image to change them."
        }
        return nil
    }
    
    /// Checks that the disk can be modified, telling the user why not otherwise
    private func canWrite(_ action: String) -> Bool {
        if let reason = writeBlockedReason {
            showError("Cannot \(action)", reason)
            return false
        }
        return true
    }
    
    /// Path of the directory shown in this pane, e.g. "/" or "/SYSTEM/"
    var currentDirectoryPath: String {
        return currentDirectory?.directoryPath ?? "/"
    }
    
    /// Drops entries that sit inside a directory which is itself in the list,
    /// so a directory and its contents are handled once
    private func topLevelEntries(_ entries: [DiskCatalogEntry]) -> [DiskCatalogEntry] {
        let directoryPaths = entries.filter { $0.isDirectory }.map { $0.directoryPath }
        return entries.filter { entry in
            !directoryPaths.contains { entry.parentPath.hasPrefix($0) }
        }
    }
    
    /// The directories named by a path, outermost first. Empty if any part is missing.
    private func directories(alongPath path: String) -> [DiskCatalogEntry] {
        var result: [DiskCatalogEntry] = []
        var entries = catalog?.entries ?? []
        for name in path.split(separator: "/") {
            guard let directory = entries.first(where: { $0.isDirectory && $0.name == name }) else { return [] }
            result.append(directory)
            entries = directory.children ?? []
        }
        return result
    }
    
    // MARK: - Find Volume Header in .dsk
    
    private struct VolumeHeaderLocation {
        let offset: Int
        let track: Int
        let sector: Int
    }
    
    private func findVolumeHeaderInDSK(_ data: Data) -> VolumeHeaderLocation? {
        // Scan entire disk for ProDOS Volume Directory Header signature
        // Looking for: Storage Type 0xF, valid name length, entry_length=0x27, entries_per_block=0x0D
        
        let sectorSize = 256
        
        // Check every sector as potential start of a 512-byte block
        for offset in stride(from: 0, to: data.count - 512, by: sectorSize) {
            let blockData = data[offset..<(offset + 512)]
            
            guard offset + 4 < blockData.endIndex else { continue }
            
            let storageAndName = blockData[blockData.startIndex + 4]
            let storageType = (storageAndName & 0xF0) >> 4
            let nameLength = storageAndName & 0x0F
            
            // Check for Volume Directory Header signature
            if storageType == 0x0F && nameLength >= 1 && nameLength <= 15 {
                // Verify entry structure
                guard offset + 0x24 < blockData.endIndex else { continue }
                
                let entryLength = blockData[blockData.startIndex + 0x23]
                let entriesPerBlock = blockData[blockData.startIndex + 0x24]
                
                if entryLength == 0x27 && entriesPerBlock == 0x0D {
                    let track = offset / 4096
                    let sector = (offset % 4096) / sectorSize
                    
                    return VolumeHeaderLocation(offset: offset, track: track, sector: sector)
                }
            }
        }
        
        return nil
    }
    
    // MARK: - DOS to ProDOS Sector Order Conversion
    
    private func convertDOStoProDOSOrder(_ data: Data) -> Data? {
        let sectorSize = 256
        let sectorsPerTrack = 16
        let tracks = 35
        let expectedSize = tracks * sectorsPerTrack * sectorSize
        
        guard data.count == expectedSize else {
            print("   ⚠️ File size mismatch: \(data.count) != \(expectedSize)")
            return nil
        }
        
        // DOS to ProDOS sector mapping
        // Each ProDOS block consists of 2 DOS sectors in this order
        let dosToProDOSMap: [Int] = [0, 8, 1, 9, 2, 10, 3, 11, 4, 12, 5, 13, 6, 14, 7, 15]
        
        var converted = Data(count: expectedSize)
        var destOffset = 0
        
        // Process each track
        for track in 0..<tracks {
            let trackOffset = track * sectorsPerTrack * sectorSize
            
            // Process each block in track (8 blocks per track)
            for blockInTrack in 0..<8 {
                // Get the two sector indices for this block
                let lowerSectorIdx = dosToProDOSMap[blockInTrack * 2]
                let upperSectorIdx = dosToProDOSMap[blockInTrack * 2 + 1]
                
                // Read from DOS order
                let lowerOffset = trackOffset + (lowerSectorIdx * sectorSize)
                let upperOffset = trackOffset + (upperSectorIdx * sectorSize)
                
                // Write to ProDOS order (linear)
                converted.replaceSubrange(destOffset..<(destOffset + sectorSize),
                                        with: data[lowerOffset..<(lowerOffset + sectorSize)])
                destOffset += sectorSize
                
                converted.replaceSubrange(destOffset..<(destOffset + sectorSize),
                                        with: data[upperOffset..<(upperOffset + sectorSize)])
                destOffset += sectorSize
            }
        }
        
        print("   ✅ Conversion complete: \(converted.count) bytes")
        
        // Verify Block 2
        let block2Offset = 2 * 512
        let storageType = (converted[block2Offset + 4] & 0xF0) >> 4
        print("   Verification: Block 2 StorageType = 0x\(String(storageType, radix: 16))")
        
        return converted
    }
    
    // MARK: - Selection
    
    func isSelected(_ entry: DiskCatalogEntry) -> Bool {
        return selectedEntries.contains(entry.id)
    }
    
    func toggleSelection(_ entry: DiskCatalogEntry, commandPressed: Bool = false, shiftPressed: Bool = false) {
        print("🔘 Toggle selection for: \(entry.name)")
        print("   Current selected count: \(selectedEntries.count)")
        print("   Command: \(commandPressed), Shift: \(shiftPressed)")
        
        if shiftPressed {
            // Shift: Range selection from last selected to this one
            handleRangeSelection(entry)
        } else if commandPressed {
            // Command: Toggle individual item
            if selectedEntries.contains(entry.id) {
                selectedEntries.remove(entry.id)
                print("   ➖ Deselected")
            } else {
                selectedEntries.insert(entry.id)
                print("   ➕ Selected")
            }
        } else {
            // No modifier: Replace selection with this item
            selectedEntries.removeAll()
            selectedEntries.insert(entry.id)
            print("   ➕ Selected (cleared others)")
        }
        
        print("   New selected count: \(selectedEntries.count)")
        lastSelectedEntry = entry
    }
    
    private func handleRangeSelection(_ entry: DiskCatalogEntry) {
        guard let catalog = catalog, let lastSelected = lastSelectedEntry else {
            selectedEntries.insert(entry.id)
            return
        }
        
        // A range runs between two entries of the same directory, so it never
        // reaches into folders that may be collapsed on screen
        guard lastSelected.parentPath == entry.parentPath else {
            selectedEntries.insert(entry.id)
            return
        }
        let allEntries = flattenEntries(catalog.entries).filter { $0.parentPath == entry.parentPath }
        
        guard let startIndex = allEntries.firstIndex(where: { $0.id == lastSelected.id }),
              let endIndex = allEntries.firstIndex(where: { $0.id == entry.id }) else {
            return
        }
        
        let range = min(startIndex, endIndex)...max(startIndex, endIndex)
        for i in range {
            selectedEntries.insert(allEntries[i].id)
        }
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
    
    private func selectRecursive(_ entry: DiskCatalogEntry) {
        selectedEntries.insert(entry.id)
        if let children = entry.children {
            for child in children {
                selectRecursive(child)
            }
        }
    }
    
    private func deselectRecursive(_ entry: DiskCatalogEntry) {
        selectedEntries.remove(entry.id)
        if let children = entry.children {
            for child in children {
                deselectRecursive(child)
            }
        }
    }
    
    func toggleSelectAll() {
        guard let catalog = catalog else { return }
        
        if isAllSelected {
            selectedEntries = []
        } else {
            selectedEntries = Set(catalog.allEntries.map { $0.id })
        }
    }
    
    func expandAll() {
        expandAllTrigger.toggle()
    }
    
    // MARK: - Directory Navigation
    
    func navigateInto(_ directory: DiskCatalogEntry) {
        guard directory.isDirectory else { return }
        
        // The path back is the directory's ancestors, wherever it was opened from
        let ancestors = directories(alongPath: directory.parentPath)
        if directory.parentPath == "/" || !ancestors.isEmpty {
            navigationPath = ancestors
        } else if let current = currentDirectory {
            navigationPath.append(current)
        }
        
        // Set new current directory
        currentDirectory = directory
        
        // Clear selection
        selectedEntries = []
        
        print("📂 Navigated into: \(directory.name)")
    }
    
    func navigateBack() {
        guard !navigationPath.isEmpty else {
            // Already at root
            currentDirectory = nil
            return
        }
        
        // Pop last directory from path
        currentDirectory = navigationPath.popLast()
        
        // Clear selection
        selectedEntries = []
        
        if let current = currentDirectory {
            print("📂 Navigated back to: \(current.name)")
        } else {
            print("📂 Navigated back to root")
        }
    }
    
    func navigateToRoot() {
        navigationPath = []
        currentDirectory = nil
        selectedEntries = []
        print("📂 Navigated to root")
    }
    
    func getSelectedEntries() -> [DiskCatalogEntry] {
        guard let catalog = catalog else {
            print("⚠️ getSelectedEntries: No catalog")
            return []
        }
        
        let result = catalog.allEntries.filter { selectedEntries.contains($0.id) }
        print("📋 getSelectedEntries: \(result.count) of \(selectedEntries.count) IDs")
        for entry in result {
            print("   - \(entry.name)")
        }
        return result
    }
    
    // MARK: - Export to Finder
    
    func exportSelectedToFinder() {
        let entriesToExport = getSelectedEntries()  // Include directories!
        
        guard !entriesToExport.isEmpty else { return }
        
        // Use proper Downloads directory
        guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            print("Could not find Downloads folder")
            return
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        
        let diskName = catalog?.diskName ?? "Disk"
        let exportFolderName = "\(diskName)_export_\(timestamp)"
        let exportFolder = downloadsURL.appendingPathComponent(exportFolderName)
        
        print("📂 Exporting to: \(exportFolder.path)")
        
        do {
            try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
            
            var exportedCount = 0
            for entry in entriesToExport {
                exportedCount += exportEntry(entry, to: exportFolder)
            }
            
            print("🎉 Export completed: \(exportedCount) files")
            NSWorkspace.shared.activateFileViewerSelecting([exportFolder])
            
        } catch {
            print("❌ Export error: \(error)")
        }
    }
    
    // MARK: - Recursive Export Helper
    
    private func exportEntry(_ entry: DiskCatalogEntry, to parentFolder: URL) -> Int {
        var count = 0
        
        if entry.isDirectory {
            // Create subdirectory
            let subfolderURL = parentFolder.appendingPathComponent(entry.name)
            do {
                try FileManager.default.createDirectory(at: subfolderURL, withIntermediateDirectories: true)
                print("📁 Created directory: \(entry.name)")
                
                // Recursively export children
                if let children = entry.children {
                    for child in children {
                        count += exportEntry(child, to: subfolderURL)
                    }
                }
            } catch {
                print("❌ Failed to create directory \(entry.name): \(error)")
            }
        } else {
            // Export file
            var filename = entry.name
            
            // Add extension if missing
            if !filename.contains(".") {
                switch entry.fileType {
                case 0x00, 0x01: filename += ".txt"
                case 0x02: filename += ".bas"
                case 0x04, 0x06: filename += ".bin"
                case 0xFA, 0xFC: filename += ".bas"
                default: filename += ".dat"
                }
            }
            
            let fileURL = parentFolder.appendingPathComponent(filename)
            do {
                try entry.data.write(to: fileURL)
                print("✅ Exported: \(filename)")
                count = 1
            } catch {
                print("❌ Failed to export \(filename): \(error)")
            }
        }
        
        return count
    }
    
    // MARK: - Import Files
    
    /// ProDOS file type for a file imported from the Mac, judged by its extension
    static func importFileType(forExtension ext: String) -> UInt8 {
        switch ext.lowercased() {
        case "txt", "text", "s", "asm", "src", "bas":
            return 0x04  // TXT (BASIC arrives as source text, not tokenized)
        default:
            return 0x06  // BIN
        }
    }
    
    func importFile(from url: URL) {
        importFiles(from: [url])
    }
    
    /// Imports files from the Mac into the directory shown in this pane, one at a time
    func importFiles(from urls: [URL]) {
        guard catalog != nil, let imagePath = diskImagePath, !urls.isEmpty else { return }
        guard canWrite("Import") else { return }
        
        importNextFile(urls, index: 0, failures: []) { failures in
            self.loadDiskImage(from: imagePath)
            self.reportFailures("Some Files Could Not Be Imported", failures)
        }
    }
    
    private func importNextFile(_ urls: [URL], index: Int, failures: [String], completion: @escaping ([String]) -> Void) {
        guard index < urls.count else {
            completion(failures)
            return
        }
        
        let url = urls[index]
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        
        guard let fileData = try? Data(contentsOf: url) else {
            importNextFile(urls, index: index + 1, failures: failures + ["\(url.lastPathComponent): could not be read"], completion: completion)
            return
        }
        
        addImportedFile(fileData, filename: url.lastPathComponent,
                        fileType: Self.importFileType(forExtension: url.pathExtension), auxType: 0x0000) { failure in
            self.importNextFile(urls, index: index + 1, failures: failures + (failure.map { [$0] } ?? []), completion: completion)
        }
    }

    /// Import raw data as a file into the directory shown in this pane
    func importRawData(_ data: Data, filename: String, fileType: UInt8, auxType: UInt16) {
        guard catalog != nil,
              let imagePath = diskImagePath else {
            print("❌ No disk loaded")
            return
        }

        guard canWrite("Import") else { return }

        addImportedFile(data, filename: filename, fileType: fileType, auxType: auxType) { failure in
            if let failure = failure {
                self.showError("Import Failed", failure)
            } else {
                self.loadDiskImage(from: imagePath)
            }
        }
    }
    
    /// Writes one file into the directory shown in this pane.
    /// The completion receives a message if it failed, nil if it worked.
    private func addImportedFile(_ data: Data, filename: String, fileType: UInt8, auxType: UInt16, completion: @escaping (String?) -> Void) {
        guard let imagePath = diskImagePath else { return }

        // Sanitize filename for ProDOS/DOS 3.3
        var sanitizedName = filename.uppercased()
            .replacingOccurrences(of: " ", with: ".")
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }

        if sanitizedName.isEmpty {
            sanitizedName = "IMPORTED"
        }

        // Truncate to max length
        let maxLen = isDOS33 ? 30 : 15
        sanitizedName = String(sanitizedName.prefix(maxLen))

        print("📋 Importing as: \(sanitizedName) (\(data.count) bytes, type $\(String(format: "%02X", fileType)))")

        let writerCompletion: (Bool, String) -> Void = { success, message in
            completion(success ? nil : "\(sanitizedName): \(message)")
        }

        if isDOS33 {
            DOS33Writer.shared.addFile(
                diskImagePath: imagePath,
                fileName: sanitizedName,
                fileData: data,
                fileType: fileType,
                auxType: auxType,
                completion: writerCompletion
            )
        } else {
            ProDOSWriter.shared.addFile(
                diskImagePath: imagePath,
                fileName: sanitizedName,
                fileData: data,
                fileType: fileType,
                auxType: auxType,
                parentPath: currentDirectoryPath,
                completion: writerCompletion
            )
        }
    }

    /// Copies entries dragged from the other pane into the directory shown in this pane
    func importEntries(_ entries: [DiskCatalogEntry], from sourceVM: DiskPaneViewModel) {
        guard let targetImagePath = diskImagePath,
              sourceVM.diskImagePath != nil else { return }
        
        guard canWrite("Copy Files") else { return }
        
        copyEntries(topLevelEntries(entries), to: targetImagePath, parentPath: currentDirectoryPath) { _, failures in
            self.loadDiskImage(from: targetImagePath)
            self.reportFailures("Some Items Could Not Be Copied", failures)
        }
    }
    
    // MARK: - Copy Entries
    
    /// Copies entries onto this pane's disk one at a time, recreating directories on ProDOS
    /// and flattening them on DOS 3.3.
    /// - Parameters:
    ///   - completion: Receives the entries of `entries` that were copied completely
    ///     (for a directory, including everything inside it) and a message for each failure.
    private func copyEntries(_ entries: [DiskCatalogEntry], to targetImagePath: URL, parentPath: String,
                             index: Int = 0, copied: [DiskCatalogEntry] = [], failures: [String] = [],
                             completion: @escaping (_ copied: [DiskCatalogEntry], _ failures: [String]) -> Void) {
        guard index < entries.count else {
            completion(copied, failures)
            return
        }
        
        let entry = entries[index]
        let targetIsDOS33 = isDOS33
        
        // Records the outcome for this entry and moves on to the next one
        let next: (Bool, [String]) -> Void = { success, newFailures in
            self.copyEntries(entries, to: targetImagePath, parentPath: parentPath,
                             index: index + 1, copied: success ? copied + [entry] : copied, failures: failures + newFailures,
                             completion: completion)
        }
        
        if entry.isDirectory {
            let children = entry.children ?? []
            
            // DOS 3.3 doesn't support directories - copy the contents flat
            if targetIsDOS33 {
                copyEntries(children, to: targetImagePath, parentPath: parentPath) { childrenCopied, childFailures in
                    next(childrenCopied.count == children.count, childFailures)
                }
                return
            }
            
            ProDOSWriter.shared.createDirectory(diskImagePath: targetImagePath, directoryName: entry.name, parentPath: parentPath) { success, message in
                guard success else {
                    next(false, ["\(entry.name): \(message)"])
                    return
                }
                self.copyEntries(children, to: targetImagePath, parentPath: parentPath + entry.name + "/") { childrenCopied, childFailures in
                    next(childrenCopied.count == children.count, childFailures)
                }
            }
            return
        }
        
        let writerCompletion: (Bool, String) -> Void = { success, message in
            next(success, success ? [] : ["\(entry.name): \(message)"])
        }
        
        if targetIsDOS33 {
            // DOS33Writer converts the ProDOS file type itself
            DOS33Writer.shared.addFile(
                diskImagePath: targetImagePath,
                fileName: entry.name,
                fileData: entry.data,
                fileType: entry.fileType,
                auxType: entry.auxType,
                locked: false,
                completion: writerCompletion
            )
        } else {
            ProDOSWriter.shared.addFile(
                diskImagePath: targetImagePath,
                fileName: entry.name,
                fileData: entry.data,
                fileType: entry.fileType,
                auxType: entry.auxType,
                parentPath: parentPath,
                completion: writerCompletion
            )
        }
    }
    
    // MARK: - Delete Files
    
    func deleteSelected() {
        guard let diskImagePath = diskImagePath else {
            print("❌ No disk image loaded")
            return
        }
        
        guard canWrite("Delete") else { return }
        
        let entriesToDelete = topLevelEntries(getSelectedEntries())
        guard !entriesToDelete.isEmpty else { return }
        
        // Deleting cannot be undone, and a directory goes with everything inside it
        let what = entriesToDelete.count == 1 ? "“\(entriesToDelete[0].name)”" : "\(entriesToDelete.count) items"
        let hasDirectory = entriesToDelete.contains { $0.isDirectory }
        guard confirmAction("Delete \(what)?",
                            (hasDirectory ? "Directories are deleted with everything inside them. " : "") + "This cannot be undone.",
                            "Delete") else { return }
        
        deleteEntries(entriesToDelete, from: diskImagePath, isDOS33: isDOS33) { failures in
            self.selectedEntries.removeAll()
            self.loadDiskImage(from: diskImagePath)
            self.reportFailures("Some Items Could Not Be Deleted", failures)
        }
    }
    
    /// Deletes entries from a disk image one at a time. Each delete rewrites the whole
    /// image, so they must never run concurrently.
    private func deleteEntries(_ entries: [DiskCatalogEntry], from diskImagePath: URL, isDOS33: Bool,
                               index: Int = 0, failures: [String] = [],
                               completion: @escaping (_ failures: [String]) -> Void) {
        guard index < entries.count else {
            completion(failures)
            return
        }
        
        let entry = entries[index]
        let name = entry.name
        
        let writerCompletion: (Bool, String) -> Void = { success, message in
            self.deleteEntries(entries, from: diskImagePath, isDOS33: isDOS33, index: index + 1,
                               failures: success ? failures : failures + ["\(name): \(message)"],
                               completion: completion)
        }
        
        if isDOS33 {
            DOS33Writer.shared.deleteFile(diskImagePath: diskImagePath, fileName: name, completion: writerCompletion)
        } else {
            ProDOSWriter.shared.deleteFile(diskImagePath: diskImagePath, fileName: name, parentPath: entry.parentPath, completion: writerCompletion)
        }
    }
    
    // MARK: - Create Directory
    
    func showCreateDirectoryDialog() {
        guard let diskImagePath = diskImagePath else {
            print("❌ No disk image loaded")
            return
        }
        
        guard canWrite("Create Directory") else { return }
        
        guard !isDOS33 else {
            showError("Cannot Create Directory", "DOS 3.3 disks do not support directories.")
            return
        }
        
        let alert = NSAlert()
        alert.messageText = "Create New Directory"
        alert.informativeText = "Enter a name for the new directory:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.placeholderString = "Directory name"
        alert.accessoryView = textField
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            let directoryName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard !directoryName.isEmpty else {
                print("❌ Directory name cannot be empty")
                return
            }
            
            let parentPath = currentDirectoryPath
            
            print("📁 Creating directory '\(directoryName)' in '\(parentPath)'")
            
            ProDOSWriter.shared.createDirectory(
                diskImagePath: diskImagePath,
                directoryName: directoryName,
                parentPath: parentPath
            ) { success, message in
                if success {
                    print("✅ Directory '\(directoryName)' created successfully")
                    // Reload disk image to show new directory
                    self.loadDiskImage(from: diskImagePath)
                } else {
                    print("❌ Failed to create directory: \(message)")
                    self.showError("Failed to Create Directory", message)
                }
            }
        }
    }
    
    // MARK: - Eject Disk
    
    func ejectDisk() {
        print("💿 Ejecting disk image")
        
        // Clear all state
        catalog = nil
        diskImagePath = nil
        isArchiveBacked = false
        diskImageFileSize = nil
        selectedEntries.removeAll()
        currentDirectory = nil
        navigationPath.removeAll()
        lastSelectedEntry = nil
        
        print("✅ Disk ejected")
    }
    
    // MARK: - Rename Entry
    
    func renameEntry(_ entry: DiskCatalogEntry) {
        guard let diskImagePath = diskImagePath else {
            print("❌ No disk image loaded")
            return
        }
        
        guard canWrite("Rename") else { return }
        
        let oldName = entry.name
        
        let alert = NSAlert()
        alert.messageText = "Rename \(entry.isDirectory ? "Directory" : "File")"
        alert.informativeText = "Enter a new name:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.placeholderString = "New name"
        textField.stringValue = oldName
        alert.accessoryView = textField
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard !newName.isEmpty else {
                print("❌ Name cannot be empty")
                return
            }
            
            guard newName != oldName else {
                print("❌ Name unchanged")
                return
            }
            
            print("✏️ Renaming '\(oldName)' to '\(newName)'")
            
            let completion: (Bool, String) -> Void = { success, message in
                if success {
                    print("✅ Renamed to '\(newName)'")
                    // Reload disk image to show new name
                    self.loadDiskImage(from: diskImagePath)
                } else {
                    print("❌ Failed to rename: \(message)")
                    self.showError("Failed to Rename", message)
                }
            }
            
            if isDOS33 {
                DOS33Writer.shared.renameFile(diskImagePath: diskImagePath, oldName: oldName, newName: newName, completion: completion)
            } else {
                ProDOSWriter.shared.renameFile(diskImagePath: diskImagePath, oldName: oldName, newName: newName, parentPath: entry.parentPath, completion: completion)
            }
        }
    }
    
    // MARK: - Show File Info
    
    func showFileInfo(_ entry: DiskCatalogEntry) {
        fileInfoEntry = entry
        showingFileInfo = true
    }

    // MARK: - Change File Type

    func showChangeFileType(_ entry: DiskCatalogEntry) {
        // Only allow changing file type for non-directories on ProDOS disks
        guard !entry.isDirectory else {
            print("Cannot change file type for directories")
            return
        }

        guard !isDOS33 && !isUCSDPascal else {
            print("File type change only supported on ProDOS disks")
            return
        }

        changeFileTypeEntry = entry
        showingChangeFileType = true
    }

    func changeFileType(entry: DiskCatalogEntry, newFileType: UInt8, newAuxType: UInt16) {
        guard let diskImagePath = diskImagePath else {
            print("No disk image loaded")
            return
        }

        guard canWrite("Change File Type") else { return }

        ProDOSWriter.shared.setFileType(
            diskImagePath: diskImagePath,
            fileName: entry.name,
            parentPath: entry.parentPath,
            fileType: newFileType,
            auxType: newAuxType
        ) { success, message in
            if success {
                print("File type changed to $\(String(format: "%02X", newFileType)), aux $\(String(format: "%04X", newAuxType))")
                // Reload disk image to show new file type
                self.loadDiskImage(from: diskImagePath)
            } else {
                print("Failed to change file type: \(message)")
                self.showError("Failed to Change File Type", message)
            }
        }
    }

    // MARK: - Copy/Cut/Paste
    
    func copySelected() {
        let entries = getSelectedEntries()
        guard !entries.isEmpty else {
            print("❌ Nothing selected to copy")
            return
        }
        
        guard let sourcePath = diskImagePath else {
            print("❌ No disk loaded")
            return
        }
        
        FocusManager.shared.copyToClipboard(entries: entries, operation: .copy, sourcePath: sourcePath, source: self)
    }
    
    func cutSelected() {
        let entries = getSelectedEntries()
        guard !entries.isEmpty else {
            print("❌ Nothing selected to cut")
            return
        }
        
        guard let sourcePath = diskImagePath else {
            print("❌ No disk loaded")
            return
        }
        
        FocusManager.shared.copyToClipboard(entries: entries, operation: .cut, sourcePath: sourcePath, source: self)
    }
    
    /// Pastes the clipboard into the directory shown in this pane.
    /// After a cut, only the entries that were copied completely are removed from the source.
    func pasteClipboard() {
        let clipboard = FocusManager.shared
        
        guard clipboard.hasClipboard(),
              let sourceDiskPath = clipboard.clipboardSourcePath else {
            print("❌ Clipboard is empty")
            return
        }
        
        guard let targetDiskPath = diskImagePath else {
            print("❌ No target disk loaded")
            return
        }
        
        guard canWrite("Paste") else { return }
        
        let isCut = clipboard.clipboardOperation == .cut
        let sourceIsDOS33 = clipboard.clipboardSourceIsDOS33
        let sourceVM = clipboard.clipboardSourceVM
        let targetPath = currentDirectoryPath
        let isSameDisk = sourceDiskPath == targetDiskPath
        
        var failures: [String] = []
        var entries: [DiskCatalogEntry] = []
        for entry in topLevelEntries(clipboard.clipboardEntries) {
            if isSameDisk && entry.isDirectory && targetPath.hasPrefix(entry.directoryPath) {
                failures.append("\(entry.name): a directory cannot be pasted into itself")
            } else if isSameDisk && isCut && entry.parentPath == targetPath {
                // Moving an entry to where it already is
                continue
            } else {
                entries.append(entry)
            }
        }
        
        print("📋 Pasting \(entries.count) items into \(targetPath) (\(clipboard.clipboardOperation))")
        
        copyEntries(entries, to: targetDiskPath, parentPath: targetPath) { copied, copyFailures in
            failures += copyFailures
            
            let finish: ([String]) -> Void = { deleteFailures in
                clipboard.clearClipboard()
                self.loadDiskImage(from: targetDiskPath)
                if let sourceVM = sourceVM, sourceVM !== self, sourceVM.diskImagePath == sourceDiskPath {
                    sourceVM.loadDiskImage(from: sourceDiskPath)
                }
                self.reportFailures(isCut ? "Some Items Could Not Be Moved" : "Some Items Could Not Be Pasted",
                                    failures + deleteFailures)
            }
            
            if isCut {
                // Anything that failed to copy stays on the source disk
                self.deleteEntries(copied, from: sourceDiskPath, isDOS33: sourceIsDOS33, completion: finish)
            } else {
                finish([])
            }
        }
    }
}
