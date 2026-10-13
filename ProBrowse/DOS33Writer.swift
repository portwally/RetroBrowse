//
//  DOS33Writer.swift
//  ProBrowse
//
//  Direct DOS 3.3 disk image manipulation for writing and deleting files
//

import Foundation

class DOS33Writer {
    static let shared = DOS33Writer()
    
    private let SECTOR_SIZE = 256
    private let SECTORS_PER_TRACK = 16
    private let TRACKS = 35
    
    // VTOC (Volume Table of Contents) location
    private let VTOC_TRACK = 17
    private let VTOC_SECTOR = 0
    
    // Default catalog location
    private let CATALOG_TRACK = 17
    private let CATALOG_SECTOR = 15  // Usually starts at T17, S15 (0x0F)
    
    private init() {}
    
    // MARK: - Helper Functions
    
    /// Calculate offset for a given track/sector
    private func offset(track: Int, sector: Int) -> Int {
        return (track * SECTORS_PER_TRACK + sector) * SECTOR_SIZE
    }
    
    /// Sanitize filename for DOS 3.3: max 30 chars, printable ASCII, uppercase
    private func sanitizeDOS33Filename(_ filename: String) -> String {
        var name = filename.uppercased()
        
        // DOS 3.3 allows most printable ASCII, but we'll be conservative
        // Allow: A-Z, 0-9, space, period
        let validChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ."))
        name = name.filter { char in
            guard let scalar = char.unicodeScalars.first else { return false }
            return validChars.contains(scalar) && scalar.value >= 32 && scalar.value < 127
        }
        
        // Max 30 characters
        if name.count > 30 {
            name = String(name.prefix(30))
        }
        
        // Ensure not empty
        if name.isEmpty {
            name = "UNNAMED"
        }
        
        // Pad with spaces to 30 characters
        while name.count < 30 {
            name += " "
        }
        
        return name
    }
    
    /// Read VTOC to get catalog location and disk info
    private func readVTOC(_ diskData: Data) -> (catalogTrack: Int, catalogSector: Int, direction: Int)? {
        let vtocOffset = offset(track: VTOC_TRACK, sector: VTOC_SECTOR)
        
        guard vtocOffset + SECTOR_SIZE <= diskData.count else {
            print("❌ Disk too small to contain VTOC")
            return nil
        }
        
        // VTOC Structure:
        // +0x00: Not used
        // +0x01: First catalog track
        // +0x02: First catalog sector
        // +0x03: DOS release number
        // +0x27: Direction of allocation (0x01 = forward, 0xFF = backward)
        
        let catalogTrack = Int(diskData[vtocOffset + 0x01])
        let catalogSector = Int(diskData[vtocOffset + 0x02])
        let direction = Int(diskData[vtocOffset + 0x27])
        
        guard catalogTrack < TRACKS && catalogSector < SECTORS_PER_TRACK else {
            print("❌ Invalid catalog location in VTOC: T\(catalogTrack) S\(catalogSector)")
            return nil
        }
        
        return (catalogTrack, catalogSector, direction)
    }
    
    /// Find a free catalog entry
    private func findFreeCatalogEntry(_ diskData: Data, catalogTrack: Int, catalogSector: Int) -> (track: Int, sector: Int, entryIndex: Int)? {
        var currentTrack = catalogTrack
        var currentSector = catalogSector
        var visitedSectors = Set<String>()
        
        // Maximum 100 catalog sectors to prevent infinite loops
        for _ in 0..<100 {
            let key = "\(currentTrack)-\(currentSector)"
            if visitedSectors.contains(key) {
                print("⚠️ Catalog loop detected")
                break
            }
            visitedSectors.insert(key)
            
            let sectorOffset = offset(track: currentTrack, sector: currentSector)
            guard sectorOffset + SECTOR_SIZE <= diskData.count else { break }
            
            // Check all 7 file entries in this catalog sector
            // Catalog sector structure:
            // +0x00: Not used
            // +0x01: Track of next catalog sector (0 if last)
            // +0x02: Sector of next catalog sector
            // +0x0B: Start of first file entry (11 bytes in)
            // Each file entry is 35 bytes (0x23)
            
            for entryIdx in 0..<7 {
                let entryOffset = sectorOffset + 0x0B + (entryIdx * 0x23)
                
                // Check track of first T/S list sector
                // If 0x00 or 0xFF, entry is deleted/free
                let trackByte = diskData[entryOffset]
                
                if trackByte == 0x00 || trackByte == 0xFF {
                    // Found a free entry!
                    return (currentTrack, currentSector, entryIdx)
                }
            }
            
            // Move to next catalog sector
            let nextTrack = Int(diskData[sectorOffset + 0x01])
            let nextSector = Int(diskData[sectorOffset + 0x02])
            
            if nextTrack == 0 {
                // Last catalog sector - no free entries found
                break
            }
            
            currentTrack = nextTrack
            currentSector = nextSector
        }
        
        print("❌ No free catalog entries found (max 105 files)")
        return nil
    }
    
    /// Find a file entry in the catalog by name
    private func findFileEntry(_ diskData: Data, fileName: String, catalogTrack: Int, catalogSector: Int) -> (track: Int, sector: Int, entryIndex: Int, tsTrack: Int, tsSector: Int)? {
        // Clean the search name - remove lock icon if present, trim, uppercase
        var searchName = fileName
        searchName = searchName.trimmingCharacters(in: .whitespaces).uppercased()
        
        var currentTrack = catalogTrack
        var currentSector = catalogSector
        var visitedSectors = Set<String>()
        
        print("🔍 Searching DOS 3.3 catalog for: '\(searchName)'")
        
        for _ in 0..<100 {
            let key = "\(currentTrack)-\(currentSector)"
            if visitedSectors.contains(key) {
                print("⚠️ Catalog loop detected")
                break
            }
            visitedSectors.insert(key)
            
            let sectorOffset = offset(track: currentTrack, sector: currentSector)
            guard sectorOffset + SECTOR_SIZE <= diskData.count else { break }
            
            for entryIdx in 0..<7 {
                let entryOffset = sectorOffset + 0x0B + (entryIdx * 0x23)
                let trackByte = diskData[entryOffset]
                
                // Skip deleted entries
                if trackByte == 0x00 || trackByte == 0xFF { continue }
                
                // Read filename (strip high bit)
                var entryName = ""
                for i in 0..<30 {
                    let char = diskData[entryOffset + 0x03 + i] & 0x7F
                    if char == 0x00 { break }
                    if char >= 0x20 {
                        entryName.append(Character(UnicodeScalar(char)))
                    }
                }
                entryName = entryName.trimmingCharacters(in: .whitespaces)
                
                print("   Found: '\(entryName)'")
                
                if entryName.uppercased() == searchName {
                    let tsTrack = Int(diskData[entryOffset])
                    let tsSector = Int(diskData[entryOffset + 1])
                    print("   ✅ Match found at T\(currentTrack) S\(currentSector) Entry#\(entryIdx)")
                    return (currentTrack, currentSector, entryIdx, tsTrack, tsSector)
                }
            }
            
            let nextTrack = Int(diskData[sectorOffset + 0x01])
            let nextSector = Int(diskData[sectorOffset + 0x02])
            
            if nextTrack == 0 { break }
            
            currentTrack = nextTrack
            currentSector = nextSector
        }
        
        print("   ❌ File not found")
        return nil
    }
    
    /// Every sector the catalog and its files occupy, as track * 16 + sector.
    /// Many disks have a VTOC bitmap that marks some of these free, so the
    /// allocator checks this set as well and never hands such a sector out.
    private func sectorsInUse(_ diskData: Data, catalogTrack: Int, catalogSector: Int) -> Set<Int> {
        var inUse = Set<Int>()
        var currentTrack = catalogTrack
        var currentSector = catalogSector
        
        while currentTrack != 0, currentTrack < TRACKS, currentSector < SECTORS_PER_TRACK,
              inUse.insert(currentTrack * SECTORS_PER_TRACK + currentSector).inserted {
            let sectorOffset = offset(track: currentTrack, sector: currentSector)
            guard sectorOffset + SECTOR_SIZE <= diskData.count else { break }
            
            for entryIdx in 0..<7 {
                let entryOffset = sectorOffset + 0x0B + (entryIdx * 0x23)
                let tsTrack = Int(diskData[entryOffset])
                let tsSector = Int(diskData[entryOffset + 1])
                
                // Skip deleted and unused entries
                if tsTrack == 0x00 || tsTrack == 0xFF || tsTrack >= TRACKS || tsSector >= SECTORS_PER_TRACK { continue }
                
                for sector in getFileSectors(diskData, tsTrack: tsTrack, tsSector: tsSector) {
                    inUse.insert(sector.track * SECTORS_PER_TRACK + sector.sector)
                }
            }
            
            currentTrack = Int(diskData[sectorOffset + 0x01])
            currentSector = Int(diskData[sectorOffset + 0x02])
        }
        
        return inUse
    }
    
    /// Allocate sectors for a file using VTOC bitmap
    private func allocateSectors(_ diskData: NSMutableData, sectorCount: Int, direction: Int) -> [(track: Int, sector: Int)]? {
        let vtocOffset = offset(track: VTOC_TRACK, sector: VTOC_SECTOR)
        var allocatedSectors: [(track: Int, sector: Int)] = []
        
        let catalogTrack = Int(diskData[vtocOffset + 0x01])
        let catalogSector = Int(diskData[vtocOffset + 0x02])
        let inUse = sectorsInUse(diskData as Data, catalogTrack: catalogTrack, catalogSector: catalogSector)
        
        // VTOC bitmap: starts at offset 0x38 (56 bytes)
        // 4 bytes per track (32 bits for 16 sectors, but only 16 used)
        // Bit = 1 means sector is FREE, 0 means USED
        
        let bitmapOffset = vtocOffset + 0x38
        
        // Determine search direction
        let trackRange: [Int]
        if direction == 0x01 {
            trackRange = Array(0..<TRACKS)
        } else {
            trackRange = Array(stride(from: TRACKS-1, through: 0, by: -1))
        }
        
        for track in trackRange {
            // Skip track 17 (VTOC and catalog) and track 0: a track number of 0
            // in a catalog entry or T/S pair means "unused"
            if track == VTOC_TRACK || track == 0 { continue }
            
            let trackBitmapOffset = bitmapOffset + (track * 4)

            // Bounds check: ensure 4 bitmap bytes are within disk data
            guard trackBitmapOffset + 3 < diskData.count else { continue }

            // Byte 0 holds sectors F-8 and byte 1 holds sectors 7-0, so as a
            // big-endian word bit N is sector N. Bytes 2-3 are unused.
            var bitmap = UInt32(diskData[trackBitmapOffset]) << 8
            bitmap |= UInt32(diskData[trackBitmapOffset + 1])
            
            // Check each sector in this track
            for sector in 0..<SECTORS_PER_TRACK {
                let mask: UInt32 = 1 << sector
                
                if (bitmap & mask) != 0 && !inUse.contains(track * SECTORS_PER_TRACK + sector) {
                    // Sector is free!
                    allocatedSectors.append((track, sector))
                    
                    // Mark as used in bitmap
                    bitmap &= ~mask
                    
                    // Write updated bitmap back to NSMutableData
                    let bytes = diskData.mutableBytes.assumingMemoryBound(to: UInt8.self)
                    bytes[trackBitmapOffset] = UInt8((bitmap >> 8) & 0xFF)
                    bytes[trackBitmapOffset + 1] = UInt8(bitmap & 0xFF)
                    
                    if allocatedSectors.count >= sectorCount {
                        return allocatedSectors
                    }
                }
            }
        }
        
        print("❌ Not enough free sectors (needed \(sectorCount), found \(allocatedSectors.count))")
        return nil
    }
    
    /// Free sectors in the VTOC bitmap
    private func freeSectors(_ diskData: NSMutableData, sectors: [(track: Int, sector: Int)]) {
        let vtocOffset = offset(track: VTOC_TRACK, sector: VTOC_SECTOR)
        let bitmapOffset = vtocOffset + 0x38
        let bytes = diskData.mutableBytes.assumingMemoryBound(to: UInt8.self)
        
        for sector in sectors {
            // Skip invalid sectors
            guard sector.track < TRACKS && sector.sector < SECTORS_PER_TRACK else { continue }
            
            let trackBitmapOffset = bitmapOffset + (sector.track * 4)
            
            guard trackBitmapOffset + 1 < diskData.length else { continue }
            
            // Read current bitmap for this track (big-endian word, bit N = sector N)
            var bitmap = UInt32(bytes[trackBitmapOffset]) << 8
            bitmap |= UInt32(bytes[trackBitmapOffset + 1])
            
            // Set bit to mark sector as free
            let mask: UInt32 = 1 << sector.sector
            bitmap |= mask
            
            // Write updated bitmap back
            bytes[trackBitmapOffset] = UInt8((bitmap >> 8) & 0xFF)
            bytes[trackBitmapOffset + 1] = UInt8(bitmap & 0xFF)
        }
        
        print("   🔓 Freed \(sectors.count) sectors in VTOC bitmap")
    }
    
    /// Get all sectors used by a file (T/S list sectors + data sectors)
    private func getFileSectors(_ diskData: Data, tsTrack: Int, tsSector: Int) -> [(track: Int, sector: Int)] {
        var allSectors: [(track: Int, sector: Int)] = []
        var currentTrack = tsTrack
        var currentSector = tsSector
        var visitedTSLists = Set<String>()
        
        // Follow the T/S list chain
        while currentTrack != 0 {
            let key = "\(currentTrack)-\(currentSector)"
            if visitedTSLists.contains(key) {
                print("⚠️ T/S list loop detected")
                break
            }
            visitedTSLists.insert(key)
            
            // Add the T/S list sector itself
            allSectors.append((currentTrack, currentSector))
            
            let tsListOffset = offset(track: currentTrack, sector: currentSector)
            guard tsListOffset + SECTOR_SIZE <= diskData.count else { break }
            
            // Read data sector pointers from this T/S list
            // T/S pairs start at offset 0x0C (12 bytes in)
            for pairIdx in 0..<122 {
                let pairOffset = tsListOffset + 0x0C + (pairIdx * 2)
                let dataTrack = Int(diskData[pairOffset])
                let dataSector = Int(diskData[pairOffset + 1])
                
                // Track 0 marks an unused pair; a random-access file can have holes
                if dataTrack == 0 { continue }
                
                // Validate sector
                if dataTrack < TRACKS && dataSector < SECTORS_PER_TRACK {
                    allSectors.append((dataTrack, dataSector))
                }
            }
            
            // Get next T/S list sector
            currentTrack = Int(diskData[tsListOffset + 0x01])
            currentSector = Int(diskData[tsListOffset + 0x02])
        }
        
        return allSectors
    }
    
    /// Create T/S List sector(s) for a file
    private func createTSList(_ diskData: NSMutableData, dataSectors: [(track: Int, sector: Int)], tsListSectors: [(track: Int, sector: Int)]) -> Bool {
        
        // Each T/S list sector can hold 122 T/S pairs (244 bytes / 2 bytes per pair)
        // T/S List structure:
        // +0x00: Not used
        // +0x01: Track of next T/S list sector (0 if last)
        // +0x02: Sector of next T/S list sector
        // +0x05: Sector offset in file (usually 0x00)
        // +0x0C: Start of T/S pairs (12 bytes in)
        // Each pair: 1 byte track, 1 byte sector
        
        let maxPairsPerSector = 122
        var dataIndex = 0
        
        for (tsListIdx, tsListSector) in tsListSectors.enumerated() {
            let tsListOffset = offset(track: tsListSector.track, sector: tsListSector.sector)
            
            // Clear the T/S list sector
            let bytes = diskData.mutableBytes.assumingMemoryBound(to: UInt8.self)
            for i in 0..<SECTOR_SIZE {
                bytes[tsListOffset + i] = 0x00
            }
            
            // Write next T/S list pointer (if there is one)
            if tsListIdx < tsListSectors.count - 1 {
                let nextTSList = tsListSectors[tsListIdx + 1]
                bytes[tsListOffset + 0x01] = UInt8(nextTSList.track)
                bytes[tsListOffset + 0x02] = UInt8(nextTSList.sector)
            } else {
                // Last T/S list
                bytes[tsListOffset + 0x01] = 0x00
                bytes[tsListOffset + 0x02] = 0x00
            }
            
            // Write sector offset (for large files with multiple T/S lists)
            let sectorBase = tsListIdx * maxPairsPerSector
            bytes[tsListOffset + 0x05] = UInt8(sectorBase & 0xFF)
            bytes[tsListOffset + 0x06] = UInt8((sectorBase >> 8) & 0xFF)
            
            // Write T/S pairs
            var pairIndex = 0
            while pairIndex < maxPairsPerSector && dataIndex < dataSectors.count {
                let dataSector = dataSectors[dataIndex]
                let pairOffset = tsListOffset + 0x0C + (pairIndex * 2)
                
                bytes[pairOffset] = UInt8(dataSector.track)
                bytes[pairOffset + 1] = UInt8(dataSector.sector)
                
                pairIndex += 1
                dataIndex += 1
            }
        }
        
        return true
    }
    
    // MARK: - Public API
    
    /// Add a file to a DOS 3.3 disk image
    /// - Parameter fileType: ProDOS file type (will be converted to DOS 3.3 automatically)
    /// - Parameter auxType: ProDOS aux type (used for conversion)
    func addFile(diskImagePath: URL, fileName: String, fileData contents: Data, fileType: UInt8, auxType: UInt16 = 0, locked: Bool = false, completion: @escaping (Bool, String) -> Void) {
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Convert ProDOS file type to DOS 3.3 file type
                let dos33FileType = DiskImageParser.convertProDOSToDOS33FileType(fileType, auxType: auxType)
                
                // Binary and BASIC files are stored with an address/length header,
                // and that length is a 16-bit field
                if [0x01, 0x02, 0x04].contains(dos33FileType) && contents.count > 0xFFFF {
                    DispatchQueue.main.async {
                        completion(false, "File is too large for a DOS 3.3 binary or BASIC file (64 KB maximum)")
                    }
                    return
                }
                let fileData = DiskImageParser.addDOS33Header(contents, dos33Type: dos33FileType, loadAddress: auxType)
                
                print("📝 DOS 3.3 Write: Adding file '\(fileName)'")
                print("   FileType conversion: ProDOS $\(String(format: "%02X", fileType)) → DOS 3.3 $\(String(format: "%02X", dos33FileType))")
                
                // Load disk image
                guard let diskData = NSMutableData(contentsOf: diskImagePath) else {
                    DispatchQueue.main.async {
                        completion(false, "Could not read disk image")
                    }
                    return
                }
                
                // Read VTOC to get catalog location
                guard let vtocInfo = self.readVTOC(diskData as Data) else {
                    DispatchQueue.main.async {
                        completion(false, "Invalid VTOC")
                    }
                    return
                }
                
                // Check if file already exists - generate unique name if needed
                var finalName = fileName
                var counter = 1
                while self.fileExists(diskData as Data, fileName: finalName) {
                    // Truncate base name to make room for number suffix
                    let baseName = String(fileName.prefix(27))  // Leave room for ".XX"
                    finalName = "\(baseName).\(counter)"
                    counter += 1
                    if counter > 99 {
                        DispatchQueue.main.async {
                            completion(false, "Too many files with similar names")
                        }
                        return
                    }
                }
                
                if finalName != fileName {
                    print("   ⚠️ File exists, renamed to: \(finalName)")
                }
                
                // Find free catalog entry
                guard let catalogEntry = self.findFreeCatalogEntry(diskData as Data, catalogTrack: vtocInfo.catalogTrack, catalogSector: vtocInfo.catalogSector) else {
                    DispatchQueue.main.async {
                        completion(false, "No free catalog entries (disk full - max 105 files)")
                    }
                    return
                }
                
                print("📝 Found free catalog entry: T\(catalogEntry.track) S\(catalogEntry.sector) Entry #\(catalogEntry.entryIndex)")
                
                // Calculate how many sectors we need
                let sectorsNeeded = max(1, (fileData.count + self.SECTOR_SIZE - 1) / self.SECTOR_SIZE)
                
                // Calculate T/S list sectors needed (122 pairs per T/S list sector)
                let tsListSectorsNeeded = (sectorsNeeded + 121) / 122
                
                let totalSectorsNeeded = sectorsNeeded + tsListSectorsNeeded
                
                print("📊 File size: \(fileData.count) bytes")
                print("   Data sectors needed: \(sectorsNeeded)")
                print("   T/S list sectors needed: \(tsListSectorsNeeded)")
                print("   Total sectors: \(totalSectorsNeeded)")
                
                // Allocate sectors
                guard let allocatedSectors = self.allocateSectors(diskData, sectorCount: totalSectorsNeeded, direction: vtocInfo.direction) else {
                    DispatchQueue.main.async {
                        completion(false, "Not enough free space")
                    }
                    return
                }
                
                // Split into T/S list sectors and data sectors
                let tsListSectors = Array(allocatedSectors.prefix(tsListSectorsNeeded))
                let dataSectors = Array(allocatedSectors.dropFirst(tsListSectorsNeeded))
                
                print("✅ Allocated \(allocatedSectors.count) sectors")
                print("   T/S List: \(tsListSectors.map { "T\($0.track)S\($0.sector)" }.joined(separator: ", "))")
                
                // Write file data to sectors
                var dataOffset = 0
                for sector in dataSectors {
                    let sectorOffset = self.offset(track: sector.track, sector: sector.sector)
                    let remainingData = fileData.count - dataOffset
                    let bytesToWrite = min(self.SECTOR_SIZE, remainingData)
                    
                    let bytes = diskData.mutableBytes.assumingMemoryBound(to: UInt8.self)
                    
                    // Clear the sector first
                    memset(bytes + sectorOffset, 0, self.SECTOR_SIZE)
                    
                    if bytesToWrite > 0 {
                        fileData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                            _ = memcpy(bytes + sectorOffset, ptr.baseAddress! + dataOffset, bytesToWrite)
                        }
                        dataOffset += bytesToWrite
                    }
                }
                
                print("✅ Wrote \(dataOffset) bytes to \(dataSectors.count) sectors")
                
                // Create T/S List
                if !self.createTSList(diskData, dataSectors: dataSectors, tsListSectors: tsListSectors) {
                    DispatchQueue.main.async {
                        completion(false, "Failed to create T/S list")
                    }
                    return
                }
                
                print("✅ Created T/S list")
                
                // Write catalog entry
                let catalogSectorOffset = self.offset(track: catalogEntry.track, sector: catalogEntry.sector)
                let entryOffset = catalogSectorOffset + 0x0B + (catalogEntry.entryIndex * 0x23)
                
                // Catalog entry structure (35 bytes):
                // +0x00: Track of first T/S list sector
                // +0x01: Sector of first T/S list sector
                // +0x02: File type (bit 7 = locked)
                // +0x03-0x20: Filename (30 bytes, space-padded, high ASCII)
                // +0x21-0x22: File size in sectors (little-endian)
                
                let sanitizedName = self.sanitizeDOS33Filename(finalName)
                let firstTSList = tsListSectors[0]
                
                let bytes = diskData.mutableBytes.assumingMemoryBound(to: UInt8.self)
                
                // Write T/S list pointer
                bytes[entryOffset + 0x00] = UInt8(firstTSList.track)
                bytes[entryOffset + 0x01] = UInt8(firstTSList.sector)
                
                // Write file type (with lock bit if needed) - use converted DOS 3.3 type
                var fileTypeByte = dos33FileType & 0x7F
                if locked {
                    fileTypeByte |= 0x80
                }
                bytes[entryOffset + 0x02] = fileTypeByte
                
                // Write filename (high ASCII - set bit 7)
                for i in 0..<30 {
                    let char = i < sanitizedName.count ? sanitizedName[sanitizedName.index(sanitizedName.startIndex, offsetBy: i)] : " "
                    let asciiValue = char.asciiValue ?? 0x20
                    bytes[entryOffset + 0x03 + i] = asciiValue | 0x80  // Set high bit
                }
                
                // Write file size in sectors, T/S list sectors included (little-endian)
                bytes[entryOffset + 0x21] = UInt8(totalSectorsNeeded & 0xFF)
                bytes[entryOffset + 0x22] = UInt8((totalSectorsNeeded >> 8) & 0xFF)
                
                print("✅ Wrote catalog entry: \(sanitizedName.trimmingCharacters(in: .whitespaces))")
                
                // Write back to disk
                try diskData.write(to: diskImagePath, options: .atomic)
                
                print("✅ DOS 3.3 write complete!")
                
                DispatchQueue.main.async {
                    completion(true, "Successfully wrote \(finalName) to DOS 3.3 disk")
                }
                
            } catch {
                DispatchQueue.main.async {
                    completion(false, "Error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// Delete a file from a DOS 3.3 disk image
    func deleteFile(diskImagePath: URL, fileName: String, completion: @escaping (Bool, String) -> Void) {
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                print("🗑️ DOS 3.3 Delete: Removing file '\(fileName)'")
                
                // Load disk image
                guard let diskData = NSMutableData(contentsOf: diskImagePath) else {
                    DispatchQueue.main.async {
                        completion(false, "Could not read disk image")
                    }
                    return
                }
                
                // Read VTOC to get catalog location
                guard let vtocInfo = self.readVTOC(diskData as Data) else {
                    DispatchQueue.main.async {
                        completion(false, "Invalid VTOC")
                    }
                    return
                }
                
                // Find the file entry
                guard let fileEntry = self.findFileEntry(diskData as Data, fileName: fileName, catalogTrack: vtocInfo.catalogTrack, catalogSector: vtocInfo.catalogSector) else {
                    DispatchQueue.main.async {
                        completion(false, "File not found: \(fileName)")
                    }
                    return
                }
                
                print("   📍 Found file at T\(fileEntry.track) S\(fileEntry.sector) Entry#\(fileEntry.entryIndex)")
                print("   📍 T/S List starts at T\(fileEntry.tsTrack) S\(fileEntry.tsSector)")
                
                // Get all sectors used by this file
                let sectorsToFree = self.getFileSectors(diskData as Data, tsTrack: fileEntry.tsTrack, tsSector: fileEntry.tsSector)
                
                print("   📦 File uses \(sectorsToFree.count) sectors")
                
                // Free the sectors in the VTOC bitmap
                self.freeSectors(diskData, sectors: sectorsToFree)
                
                // Mark the catalog entry as deleted
                // DOS 3.3 deletion: Set first byte of entry (T/S list track) to 0xFF
                // and copy the original track number to byte 0x20 (last byte before sector count)
                let catalogSectorOffset = self.offset(track: fileEntry.track, sector: fileEntry.sector)
                let entryOffset = catalogSectorOffset + 0x0B + (fileEntry.entryIndex * 0x23)
                
                let bytes = diskData.mutableBytes.assumingMemoryBound(to: UInt8.self)
                
                // Save original T/S list track to byte 0x20 (for UNDELETE functionality)
                bytes[entryOffset + 0x20] = UInt8(fileEntry.tsTrack)
                
                // Mark entry as deleted by setting track to 0xFF
                bytes[entryOffset + 0x00] = 0xFF
                
                print("   ✅ Marked catalog entry as deleted")
                
                // Write back to disk
                try diskData.write(to: diskImagePath, options: .atomic)
                
                print("✅ DOS 3.3 delete complete!")
                
                DispatchQueue.main.async {
                    completion(true, "File deleted successfully")
                }
                
            } catch {
                DispatchQueue.main.async {
                    completion(false, "Error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// Check if a file exists in the catalog
    func fileExists(_ diskData: Data, fileName: String) -> Bool {
        guard let vtocInfo = readVTOC(diskData) else { return false }
        
        // Names are stored space-padded; compare without the padding
        let searchName = sanitizeDOS33Filename(fileName).trimmingCharacters(in: .whitespaces).uppercased()
        var currentTrack = vtocInfo.catalogTrack
        var currentSector = vtocInfo.catalogSector
        var visitedSectors = Set<String>()
        
        for _ in 0..<100 {
            let key = "\(currentTrack)-\(currentSector)"
            if visitedSectors.contains(key) { break }
            visitedSectors.insert(key)
            
            let sectorOffset = offset(track: currentTrack, sector: currentSector)
            guard sectorOffset + SECTOR_SIZE <= diskData.count else { break }
            
            for entryIdx in 0..<7 {
                let entryOffset = sectorOffset + 0x0B + (entryIdx * 0x23)
                let trackByte = diskData[entryOffset]
                
                // Skip deleted entries
                if trackByte == 0x00 || trackByte == 0xFF { continue }
                
                // Read filename (strip high bit)
                var entryName = ""
                for i in 0..<30 {
                    let char = diskData[entryOffset + 0x03 + i] & 0x7F
                    if char == 0x00 { break }
                    entryName.append(Character(UnicodeScalar(char)))
                }
                entryName = entryName.trimmingCharacters(in: .whitespaces)
                
                if entryName.uppercased() == searchName {
                    return true
                }
            }
            
            let nextTrack = Int(diskData[sectorOffset + 0x01])
            if nextTrack == 0 { break }
            
            currentSector = Int(diskData[sectorOffset + 0x02])
            currentTrack = nextTrack
        }
        
        return false
    }
    
    /// Rename a file in a DOS 3.3 disk image
    func renameFile(diskImagePath: URL, oldName: String, newName: String, completion: @escaping (Bool, String) -> Void) {
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                print("✏️ DOS 3.3 Rename: '\(oldName)' → '\(newName)'")
                
                // Load disk image
                guard let diskData = NSMutableData(contentsOf: diskImagePath) else {
                    DispatchQueue.main.async {
                        completion(false, "Could not read disk image")
                    }
                    return
                }
                
                // Read VTOC to get catalog location
                guard let vtocInfo = self.readVTOC(diskData as Data) else {
                    DispatchQueue.main.async {
                        completion(false, "Invalid VTOC")
                    }
                    return
                }
                
                // Find the file entry
                guard let fileEntry = self.findFileEntry(diskData as Data, fileName: oldName, catalogTrack: vtocInfo.catalogTrack, catalogSector: vtocInfo.catalogSector) else {
                    DispatchQueue.main.async {
                        completion(false, "File not found: \(oldName)")
                    }
                    return
                }
                
                // Sanitize new name
                let sanitizedName = self.sanitizeDOS33Filename(newName)
                
                // Check if new name already exists
                if self.fileExists(diskData as Data, fileName: newName) {
                    DispatchQueue.main.async {
                        completion(false, "A file named '\(newName)' already exists")
                    }
                    return
                }
                
                // Update the filename in the catalog entry
                let catalogSectorOffset = self.offset(track: fileEntry.track, sector: fileEntry.sector)
                let entryOffset = catalogSectorOffset + 0x0B + (fileEntry.entryIndex * 0x23)
                
                let bytes = diskData.mutableBytes.assumingMemoryBound(to: UInt8.self)
                
                // Write new filename (high ASCII - set bit 7)
                for i in 0..<30 {
                    let char = i < sanitizedName.count ? sanitizedName[sanitizedName.index(sanitizedName.startIndex, offsetBy: i)] : " "
                    let asciiValue = char.asciiValue ?? 0x20
                    bytes[entryOffset + 0x03 + i] = asciiValue | 0x80
                }
                
                print("   ✅ Updated filename in catalog")
                
                // Write back to disk
                try diskData.write(to: diskImagePath, options: .atomic)
                
                print("✅ DOS 3.3 rename complete!")
                
                DispatchQueue.main.async {
                    completion(true, "File renamed successfully")
                }
                
            } catch {
                DispatchQueue.main.async {
                    completion(false, "Error: \(error.localizedDescription)")
                }
            }
        }
    }
}
