//
//  DiskImageParser.swift
//  ProBrowse
//
//  Parser for ProDOS and DOS 3.3 disk images
//  Updated to handle .dsk (DOS Ordered) ProDOS images correctly.
//

import Foundation
import Combine

class DiskImageParser {
    
    // MARK: - DOS to ProDOS Mapping Constants
    
    // DOS 3.3 logical sectors holding each ProDOS block. The same map applies to every track.
    // Based on DOS 3.3 Physical-to-Logical mapping from Apple II documentation:
    // Physical: 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15
    // DOS Log:  0, 7,14, 6,13, 5,12, 4,11, 3,10, 2, 9, 1, 8,15
    //
    // Combined with ProDOS Block-to-Physical mapping:
    // Block 0: Phys 0+2  -> DOS Log 0+14
    // Block 1: Phys 4+6  -> DOS Log 13+12
    // Block 2: Phys 8+10 -> DOS Log 11+10
    // Block 3: Phys 12+14 -> DOS Log 9+8
    // Block 4: Phys 1+3  -> DOS Log 7+6
    // Block 5: Phys 5+7  -> DOS Log 5+4
    // Block 6: Phys 9+11 -> DOS Log 3+2
    // Block 7: Phys 13+15 -> DOS Log 1+15
    private static let dosToProDOSMapData: [Int] = [0, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 15]

    /// Rearranges a 5.25" image stored in ProDOS block order into DOS sector order.
    /// Returns nil unless the image is a whole number of 16-sector tracks.
    static func dosOrdered(fromProDOSOrder data: Data) -> Data? {
        let sectorSize = 256
        let trackSize = 16 * sectorSize
        guard data.count == 35 * trackSize else { return nil }
        
        var result = Data(count: data.count)
        for half in 0..<(data.count / sectorSize) {
            // Each half block of the source goes to the DOS sector the map names
            let track = half / 16
            let target = track * trackSize + dosToProDOSMapData[half % 16] * sectorSize
            result.replaceSubrange(target..<(target + sectorSize), with: data.subdata(in: (half * sectorSize)..<((half + 1) * sectorSize)))
        }
        return result
    }
    
    // MARK: - Date/Time Parsing
    
    private static func decodeProDOSDateTime(_ dateBytes: [UInt8], _ timeBytes: [UInt8]) -> String? {
        guard dateBytes.count >= 2 else { return nil }
        
        let dateWord = UInt16(dateBytes[0]) | (UInt16(dateBytes[1]) << 8)
        
        // Check if date is zero (unset)
        guard dateWord != 0 else { return nil }
        
        // Two-digit year: 0-39 is 2000-2039, 40-99 is 1940-1999.
        // Values of 100 and up come from tools that stored (year - 1900).
        let rawYear = Int((dateWord >> 9) & 0x7F)
        let year = rawYear < 40 ? 2000 + rawYear : 1900 + rawYear
        let month = Int((dateWord >> 5) & 0x0F)
        let day = Int(dateWord & 0x1F)
        
        // Validate date
        guard month >= 1, month <= 12, day >= 1, day <= 31 else {
            return nil
        }
        
        // Parse time (optional)
        var hour = 0
        var minute = 0
        if timeBytes.count >= 2 {
            let timeWord = UInt16(timeBytes[0]) | (UInt16(timeBytes[1]) << 8)
            minute = Int(timeWord & 0xFF)
            hour = Int((timeWord >> 8) & 0xFF)
            
            // Validate time (some disks have invalid time data)
            if hour >= 24 || minute >= 60 {
                hour = 0
                minute = 0
            }
        }
        
        // Create Date object
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        
        guard let date = Calendar(identifier: .gregorian).date(from: components) else {
            return nil
        }
        
        // Format using system locale
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        
        return formatter.string(from: date)
    }
    
    // MARK: - DOS 3.3 Date/Time Parsing (not supported by DOS 3.3)
    
    /// Map DOS 3.3 file type to human-readable string
    private static func getDOS33FileTypeString(_ fileType: UInt8) -> String {
        switch fileType {
        case 0x00: return "T"    // Text
        case 0x01: return "INT"  // Integer BASIC
        case 0x02: return "BAS"  // Applesoft BASIC
        case 0x04: return "BIN"  // Binary
        case 0x08: return "S"    // Source (Assembly)
        case 0x10: return "REL"  // Relocatable
        case 0x20: return "A"    // Type A (newer, rare)
        case 0x40: return "B"    // Type B (newer, rare)
        default:   return String(format: "$%02X", fileType)
        }
    }
    
    /// Convert DOS 3.3 file type to ProDOS file type
    /// Known DOS 3.3 types are converted to their ProDOS equivalents.
    /// Unknown types (which may already be ProDOS types stored on a DOS 3.3 disk) are passed through unchanged.
    static func convertDOS33ToProDOSFileType(_ dos33Type: UInt8) -> (fileType: UInt8, auxType: UInt16) {
        switch dos33Type {
        case 0x00: return (0x04, 0x0000)  // Text → TXT
        case 0x01: return (0xFA, 0x0000)  // Integer BASIC → INT
        case 0x02: return (0xFC, 0x0000)  // Applesoft BASIC → BAS
        case 0x04: return (0x06, 0x0000)  // Binary → BIN
        case 0x08: return (0xB0, 0x0000)  // Source → SRC (Apple IIgs source)
        case 0x10: return (0xFE, 0x0000)  // Relocatable → REL
        case 0x20: return (0x00, 0x0000)  // Type A → NON (typeless)
        case 0x40: return (0x00, 0x0000)  // Type B → NON (typeless)
        default:
            // Unknown type - pass through unchanged
            // This handles cases where ProDOS types are stored on DOS 3.3 disks
            // (e.g., $06 BIN, $FC BAS already in ProDOS format)
            return (dos33Type, 0x0000)
        }
    }
    
    /// Removes the header DOS 3.3 stores in front of a file's contents and trims the
    /// sector padding behind them. Returns the contents and the load address, if the type has one.
    static func stripDOS33Header(_ raw: Data, dos33Type: UInt8) -> (contents: Data, loadAddress: UInt16?) {
        func word(_ offset: Int) -> Int {
            return Int(raw[offset]) | (Int(raw[offset + 1]) << 8)
        }
        
        switch dos33Type {
        case 0x04 where raw.count >= 4:
            // Binary: load address, length, data
            let length = word(2)
            let end = (length > 0 && 4 + length <= raw.count) ? 4 + length : raw.count
            return (raw.subdata(in: 4..<end), UInt16(word(0)))
            
        case 0x01 where raw.count >= 2, 0x02 where raw.count >= 2:
            // Integer BASIC and Applesoft: length, program
            let length = word(0)
            let end = (length > 0 && 2 + length <= raw.count) ? 2 + length : raw.count
            return (raw.subdata(in: 2..<end), dos33Type == 0x02 ? 0x0801 : nil)
            
        case 0x00:
            // Text has no header; the last sector is padded with zeros
            var end = raw.count
            while end > 0 && raw[end - 1] == 0 { end -= 1 }
            return (raw.prefix(end), nil)
            
        default:
            return (raw, nil)
        }
    }
    
    /// Puts the DOS 3.3 header in front of a file's contents, the reverse of `stripDOS33Header`
    static func addDOS33Header(_ contents: Data, dos33Type: UInt8, loadAddress: UInt16) -> Data {
        let length = UInt16(truncatingIfNeeded: contents.count)
        let lengthBytes = [UInt8(length & 0xFF), UInt8(length >> 8)]
        
        switch dos33Type {
        case 0x04:
            return Data([UInt8(loadAddress & 0xFF), UInt8(loadAddress >> 8)] + lengthBytes) + contents
        case 0x01, 0x02:
            return Data(lengthBytes) + contents
        default:
            return contents
        }
    }
    
    /// Convert ProDOS file type to DOS 3.3 file type
    static func convertProDOSToDOS33FileType(_ proDOSType: UInt8, auxType: UInt16) -> UInt8 {
        switch proDOSType {
        case 0x04: return 0x00  // TXT → Text
        case 0xFA: return 0x01  // INT → Integer BASIC
        case 0xFC: return 0x02  // BAS → Applesoft BASIC
        case 0x06: return 0x04  // BIN → Binary
        case 0xB0: return 0x08  // SRC → Source
        case 0xFE: return 0x10  // REL → Relocatable
        case 0x08:              // FOT (Graphics) → Binary with special handling
            // Check auxType for HGR/DHGR
            if auxType == 0x4000 || auxType == 0x4001 || auxType == 0x8001 || auxType == 0x8002 {
                return 0x04  // Binary
            }
            return 0x04
        case 0xC0, 0xC1:        // PNT, PIC (Super Hi-Res) → Binary
            return 0x04
        default:   return 0x04  // Default to Binary for unknown types
        }
    }
    
    // MARK: - Block Reader Helper
    
    /// Validates if a block is a valid ProDOS Volume Directory Header
    static func isValidProDOSVolumeHeader(_ block: Data) -> Bool {
        guard block.count >= 512 else { return false }
        
        // Check 1: Storage Type must be 0xF (Volume Directory Header)
        let storageType = (block[4] & 0xF0) >> 4
        guard storageType == 0x0F else { return false }
        
        // Check 2: Name Length must be 1-15
        let nameLength = Int(block[4] & 0x0F)
        guard nameLength >= 1 && nameLength <= 15 else { return false }
        
        // Check 3: Prev Block Pointer must be 0 (root has no previous)
        let prevBlock = UInt16(block[0]) | (UInt16(block[1]) << 8)
        guard prevBlock == 0 else { return false }
        
        // Check 4: Entry Length should be reasonable (typically 39, but allow 32-64)
        let entryLength = block[0x23]
        guard entryLength >= 32 && entryLength <= 64 else { return false }
        
        // Check 5: Entries Per Block should be reasonable (typically 13, but allow 8-16)
        let entriesPerBlock = block[0x24]
        guard entriesPerBlock >= 8 && entriesPerBlock <= 16 else { return false }
        
        // Check 6: Volume Name must contain mostly printable ASCII
        // Allow uppercase, lowercase, digits, period, space
        var validCharCount = 0
        for i in 0..<nameLength {
            let char = block[5 + i] & 0x7F
            // More permissive: allow A-Z, a-z, 0-9, period, space
            let isValid = (char >= 0x41 && char <= 0x5A) ||  // A-Z
                         (char >= 0x61 && char <= 0x7A) ||  // a-z
                         (char >= 0x30 && char <= 0x39) ||  // 0-9
                         (char == 0x2E) ||                   // .
                         (char == 0x20)                      // space
            if isValid {
                validCharCount += 1
            }
        }
        
        // At least 80% of characters should be valid (stricter to avoid false positives)
        guard validCharCount >= (nameLength * 4) / 5 else { return false }
        
        // Check 7: First character of volume name should be a letter (ProDOS requirement)
        let firstChar = block[5] & 0x7F
        guard (firstChar >= 0x41 && firstChar <= 0x5A) || (firstChar >= 0x61 && firstChar <= 0x7A) else { return false }
        
        return true
    }
    
    /// Reads a 512-byte block handling both Linear (.po) and Interleaved (.dsk) formats
    private static func getBlockData(from data: Data, blockIndex: Int, isDOSOrder: Bool) -> Data? {
        let blockSize = 512
        
        if !isDOSOrder {
            // Standard ProDOS Order (.po): Linear
            let offset = blockIndex * blockSize
            guard offset + blockSize <= data.count else { return nil }
            return data.subdata(in: offset..<(offset + blockSize))
        } else {
            // DOS Order (.dsk): Interleaved sectors
            // Calculate Track and "Block within Track"
            // 8 Blocks per track (because 1 Block = 2 Sectors, and there are 16 Sectors)
            let blocksPerTrack = 8
            let track = blockIndex / blocksPerTrack
            let blockInTrack = blockIndex % blocksPerTrack
            
            let sectorSize = 256
            let trackOffset = track * 16 * sectorSize
            
            guard trackOffset < data.count else { return nil }
            
            let mapping = dosToProDOSMapData
            
            // Find the two DOS sectors (Lower/Upper)
            let lowerSectorIdx = mapping[blockInTrack * 2]
            let upperSectorIdx = mapping[blockInTrack * 2 + 1]
            
            let lowerOffset = trackOffset + (lowerSectorIdx * sectorSize)
            let upperOffset = trackOffset + (upperSectorIdx * sectorSize)
            
            guard lowerOffset + sectorSize <= data.count,
                  upperOffset + sectorSize <= data.count else { return nil }
            
            var blockData = Data()
            blockData.append(data.subdata(in: lowerOffset..<(lowerOffset + sectorSize)))
            blockData.append(data.subdata(in: upperOffset..<(upperOffset + sectorSize)))
            
            return blockData
        }
    }
    
    // MARK: - Main Entry Point
    
    static func parseProDOS(data: Data, diskName: String) throws -> DiskCatalog? {
        let blockSize = 512
        
        // Check for 2MG/2IMG header and skip it
        var dataOffset = 0
        var actualData = data
        
        if data.count >= 64 {
            // Check for 2IMG magic header
            let magic = data.subdata(in: 0..<4)
            if magic == Data([0x32, 0x49, 0x4D, 0x47]) { // "2IMG"
                // Read header size (bytes 8-9, little-endian)
                let headerSize = Int(data[8]) | (Int(data[9]) << 8)
                
                // Read data offset (bytes 24-27, little-endian)
                let dataOffsetInHeader = Int(data[24]) | (Int(data[25]) << 8) |
                                        (Int(data[26]) << 16) | (Int(data[27]) << 24)
                
                if dataOffsetInHeader > 0 && dataOffsetInHeader < data.count {
                    dataOffset = dataOffsetInHeader
                } else {
                    // Fallback to header size
                    dataOffset = headerSize
                }
                
                print("🔍 Detected 2MG/2IMG container (header size: \(headerSize), data offset: \(dataOffset))")
                
                // Skip the header
                guard dataOffset <= data.count else { return nil }
                actualData = data.subdata(in: dataOffset..<data.count)
            }
        }
        
        guard actualData.count >= blockSize * 3 else { return nil }
        
        // --- Step 1: Detect Format Order ---
        var isDOSOrder = false
        var detected = false
        var rootBlockData: Data? = nil
        
        // Check standard ProDOS Order (Block 2 at linear offset 1024)
        if let block2PO = getBlockData(from: actualData, blockIndex: 2, isDOSOrder: false) {
            if isValidProDOSVolumeHeader(block2PO) {
                isDOSOrder = false
                detected = true
                rootBlockData = block2PO
                print("🔍 Detected Format: ProDOS Order (.po)")
            }
        }
        
        // Check DOS Order (Block 2 read through the sector interleave)
        if !detected, let block2DSK = getBlockData(from: actualData, blockIndex: 2, isDOSOrder: true) {
            if isValidProDOSVolumeHeader(block2DSK) {
                isDOSOrder = true
                detected = true
                rootBlockData = block2DSK
                print("🔍 Detected Format: DOS Order (.dsk)")
            }
        }
        
        // Fallback based on extension if detection failed (Optional)
        if !detected {
            // ProDOS detection failed - return nil so DOS 3.3 parser can try
            print("⚠️ ProDOS detection failed - not a valid ProDOS volume")
            return nil
        }
        
        guard let rootBlock = rootBlockData else {
            print("❌ Could not find Root Directory Block")
            return nil
        }
        
        // --- Step 2: Parse Volume Header ---
        let nameLength = Int(rootBlock[4] & 0x0F)
        var volumeName = ""
        
        if nameLength > 0 && nameLength <= 15 {
            for i in 0..<nameLength {
                var char = rootBlock[5 + i] & 0x7F
                if char < 0x20 { char = char + 0x40 }
                volumeName.append(Character(UnicodeScalar(char)))
            }
        }
        
        // --- Step 3: Read Directory Tree ---
        var visitedBlocks = Set<Int>()
        let entries = readProDOSDirectory(data: actualData, startBlock: 2, isDOSOrder: isDOSOrder, path: "/", visitedBlocks: &visitedBlocks)
        
        return DiskCatalog(
            diskName: volumeName.isEmpty ? diskName : volumeName,
            diskFormat: isDOSOrder ? "ProDOS (DSK)" : "ProDOS (PO)",
            diskSize: actualData.count,
            entries: entries
        )
    }
    
    static func parseDOS33(data: Data, diskName: String) throws -> DiskCatalog? {
        let sectorsPerTrack = 16
        let sectorSize = 256
        
        guard data.count >= 35 * sectorsPerTrack * sectorSize else { return nil }
        
        // VTOC is at Track 17, Sector 0
        let vtocOffset = (17 * sectorsPerTrack + 0) * sectorSize
        guard vtocOffset + sectorSize <= data.count else { return nil }
        
        // Catalog starts at Track 17, Sector 15 (usually)
        let catalogTrack = Int(data[vtocOffset + 1])
        let catalogSector = Int(data[vtocOffset + 2])
        
        guard catalogTrack == 17 else { return nil }
        
        let entries = readDOS33Catalog(data: data, catalogTrack: catalogTrack, catalogSector: catalogSector, sectorsPerTrack: sectorsPerTrack, sectorSize: sectorSize)
        
        // An empty catalog is only accepted when the VTOC describes a standard
        // 35-track, 16-sector disk; otherwise this is probably not DOS 3.3 at all
        if entries.isEmpty {
            let isStandardVTOC = data[vtocOffset + 0x34] == 35 && data[vtocOffset + 0x35] == 16 &&
                                 data[vtocOffset + 0x36] == 0 && data[vtocOffset + 0x37] == 1
            guard isStandardVTOC else { return nil }
        }
        
        return DiskCatalog(
            diskName: diskName,
            diskFormat: "DOS 3.3",
            diskSize: data.count,
            entries: entries
        )
    }
    
    // MARK: - ProDOS Directory Reading
    
    /// - Parameters:
    ///   - path: Path of this directory, e.g. "/" or "/SYSTEM/"
    ///   - visitedBlocks: Directory blocks seen so far on the whole volume, so a damaged
    ///     subdirectory pointer cannot loop back into a directory already read
    private static func readProDOSDirectory(data: Data, startBlock: Int, isDOSOrder: Bool, path: String, visitedBlocks: inout Set<Int>) -> [DiskCatalogEntry] {
        var entries: [DiskCatalogEntry] = []
        var currentBlock = startBlock
        
        while currentBlock != 0 {
            if visitedBlocks.contains(currentBlock) { break }
            visitedBlocks.insert(currentBlock)
            
            
            // USE helper to get data (de-interleaving if necessary)
            guard let blockData = getBlockData(from: data, blockIndex: currentBlock, isDOSOrder: isDOSOrder) else {
                break
            }
            
            // Standard Block 2 (Root) has header at +4 bytes. Subsequent blocks in chain don't have the 39 byte header skip logic usually,
            // BUT in ProDOS directory files, *every* block in the directory file contains entries.
            // Block structure:
            // Bytes 00-01: Pointer to previous block
            // Bytes 02-03: Pointer to next block
            // Entries start at byte 04.
            
            // However, the Volume Directory Header (only in the first block of root) occupies the first entry slot.
            // We usually skip it or parse it as volume info.
            
            // Is this the very first block of the directory?
            let entriesPerBlock = 13 // Standard is 13 entries per block (512 - 4) / 39 = 13.02
            
            var entriesInThisBlock = 0
            for entryIdx in 0..<entriesPerBlock {
                let entryOffset = 4 + (entryIdx * 39)
                
                // Safety check
                if entryOffset + 39 > blockData.count { continue }
                
                // Skip Volume Header Entry in the first block of the ROOT directory (Block 2)
                // The Volume Header is distinguishable by having a high nibble of 0xF in storage type (byte 0)
                // But wait, the loop reads offsets relative to blockData.
                // The Storage Type/Name Length byte is at offset 0 of the entry.
                
                let storageTypeByte = blockData[entryOffset]
                let storageType = (storageTypeByte & 0xF0) >> 4
                let nameLength = Int(storageTypeByte & 0x0F)
                
                // 0x00 = Deleted entry, 0xE = Subdirectory Header, 0xF = Volume Header
                if storageType == 0x00 { continue }
                if storageType >= 0x0E { continue } // Skip the directory's own header entry
                
                // Parse Name
                var fileName = ""
                if nameLength > 0 {
                    for i in 0..<nameLength {
                        var char = blockData[entryOffset + 1 + i] & 0x7F
                        if char < 0x20 { char += 0x40 }
                        fileName.append(Character(UnicodeScalar(char)))
                    }
                }
                
                let fileType = blockData[entryOffset + 16]
                let keyPointer = Int(blockData[entryOffset + 17]) | (Int(blockData[entryOffset + 18]) << 8)
                let blocksUsed = Int(blockData[entryOffset + 19]) | (Int(blockData[entryOffset + 20]) << 8)
                let eof = Int(blockData[entryOffset + 21]) | (Int(blockData[entryOffset + 22]) << 8) | (Int(blockData[entryOffset + 23]) << 16)
                let auxType = Int(blockData[entryOffset + 31]) | (Int(blockData[entryOffset + 32]) << 8)

                // Extended metadata
                let version = blockData[entryOffset + 28]
                let minVersion = blockData[entryOffset + 29]
                let accessFlags = blockData[entryOffset + 30]
                let headerPointer = Int(blockData[entryOffset + 37]) | (Int(blockData[entryOffset + 38]) << 8)

                let creationDate = decodeProDOSDateTime([blockData[entryOffset + 24], blockData[entryOffset + 25]], [blockData[entryOffset + 26], blockData[entryOffset + 27]])
                let modificationDate = decodeProDOSDateTime([blockData[entryOffset + 33], blockData[entryOffset + 34]], [blockData[entryOffset + 35], blockData[entryOffset + 36]])
                
                if storageType == 0x0D {
                    // Subdirectory
                    let children = readProDOSDirectory(data: data, startBlock: keyPointer, isDOSOrder: isDOSOrder, path: path + fileName + "/", visitedBlocks: &visitedBlocks)

                    entries.append(DiskCatalogEntry(
                        name: fileName,
                        fileType: 0x0F,
                        fileTypeString: "DIR",
                        auxType: 0,
                        size: blocksUsed * 512,
                        blocks: blocksUsed,
                        loadAddress: nil,
                        length: nil,
                        data: Data(),
                        isImage: false,
                        isDirectory: true,
                        children: children,
                        modificationDate: modificationDate,
                        creationDate: creationDate,
                        storageType: storageType,
                        keyPointer: keyPointer,
                        accessFlags: accessFlags,
                        version: version,
                        minVersion: minVersion,
                        headerPointer: headerPointer,
                        parentPath: path
                    ))
                } else {
                    // File
                    var fileData: Data
                    var resourceForkData: Data? = nil

                    if storageType == 0x05 {
                        // Extended file - extract both data and resource forks
                        if let forks = extractExtendedFile(data: data, keyBlock: keyPointer, isDOSOrder: isDOSOrder) {
                            fileData = forks.dataFork
                            resourceForkData = forks.resourceFork.isEmpty ? nil : forks.resourceFork
                        } else {
                            fileData = Data()
                        }
                    } else {
                        // Regular file - data fork only
                        fileData = extractProDOSFile(data: data, keyBlock: keyPointer, blocksUsed: blocksUsed, eof: eof, storageType: Int(storageType), isDOSOrder: isDOSOrder) ?? Data()
                    }

                    let isGraphicsFile = [0x08, 0xC0, 0xC1].contains(fileType)

                    // Get proper file type info from ProDOSFileTypes
                    let fileTypeInfo = ProDOSFileTypeInfo.getFileTypeInfo(fileType: fileType, auxType: UInt16(auxType))

                    entries.append(DiskCatalogEntry(
                        name: fileName,
                        fileType: fileType,
                        fileTypeString: fileTypeInfo.shortName,
                        auxType: UInt16(auxType),
                        size: eof,
                        blocks: blocksUsed,
                        loadAddress: auxType,
                        length: eof,
                        data: fileData,
                        isImage: isGraphicsFile,
                        isDirectory: false,
                        children: nil,
                        modificationDate: modificationDate,
                        creationDate: creationDate,
                        storageType: storageType,
                        keyPointer: keyPointer,
                        accessFlags: accessFlags,
                        version: version,
                        minVersion: minVersion,
                        headerPointer: headerPointer,
                        resourceForkData: resourceForkData,
                        parentPath: path
                    ))
                    entriesInThisBlock += 1
                }
            }
            
            
            // Get pointer to next block in directory chain
            let nextBlock = Int(blockData[2]) | (Int(blockData[3]) << 8)
            currentBlock = nextBlock
        }
        
        return entries
    }
    
    /// Extract extended file (storage type 5) with both data and resource forks
    private static func extractExtendedFile(data: Data, keyBlock: Int, isDOSOrder: Bool) -> (dataFork: Data, resourceFork: Data)? {
        guard let extendedKeyBlock = getBlockData(from: data, blockIndex: keyBlock, isDOSOrder: isDOSOrder) else {
            return nil
        }

        // Data fork info (bytes 0-8)
        let dataStorageType = Int(extendedKeyBlock[0])
        let dataKeyBlock = Int(extendedKeyBlock[1]) | (Int(extendedKeyBlock[2]) << 8)
        let dataBlocksUsed = Int(extendedKeyBlock[3]) | (Int(extendedKeyBlock[4]) << 8)
        let dataEof = Int(extendedKeyBlock[5]) | (Int(extendedKeyBlock[6]) << 8) | (Int(extendedKeyBlock[7]) << 16)

        // Resource fork info (bytes 256-264)
        let rsrcStorageType = Int(extendedKeyBlock[256])
        let rsrcKeyBlock = Int(extendedKeyBlock[257]) | (Int(extendedKeyBlock[258]) << 8)
        let rsrcBlocksUsed = Int(extendedKeyBlock[259]) | (Int(extendedKeyBlock[260]) << 8)
        let rsrcEof = Int(extendedKeyBlock[261]) | (Int(extendedKeyBlock[262]) << 8) | (Int(extendedKeyBlock[263]) << 16)

        // Extract data fork
        var dataFork = Data()
        if dataStorageType > 0 && dataKeyBlock > 0 {
            dataFork = extractProDOSFile(data: data, keyBlock: dataKeyBlock, blocksUsed: dataBlocksUsed, eof: dataEof, storageType: dataStorageType, isDOSOrder: isDOSOrder) ?? Data()
        }

        // Extract resource fork
        var resourceFork = Data()
        if rsrcStorageType > 0 && rsrcKeyBlock > 0 {
            resourceFork = extractProDOSFile(data: data, keyBlock: rsrcKeyBlock, blocksUsed: rsrcBlocksUsed, eof: rsrcEof, storageType: rsrcStorageType, isDOSOrder: isDOSOrder) ?? Data()
        }

        return (dataFork, resourceFork)
    }

    private static func extractProDOSFile(data: Data, keyBlock: Int, blocksUsed: Int, eof: Int, storageType: Int, isDOSOrder: Bool) -> Data? {
        var fileData = Data()

        if storageType == 1 {
            // Seedling file (single block)
            if let blockData = getBlockData(from: data, blockIndex: keyBlock, isDOSOrder: isDOSOrder) {
                fileData = blockData
            }
        }
        else if storageType == 2 {
            // Sapling file (index block with data blocks)
            if let indexBlock = getBlockData(from: data, blockIndex: keyBlock, isDOSOrder: isDOSOrder) {
                for i in 0..<256 {
                    let blockNumLo = Int(indexBlock[i])
                    let blockNumHi = Int(indexBlock[256 + i])
                    let blockNum = blockNumLo | (blockNumHi << 8)
                    
                    if blockNum == 0 {
                        // Sparse block (hole)
                        fileData.append(Data(repeating: 0, count: 512))
                    } else {
                        if let dataBlock = getBlockData(from: data, blockIndex: blockNum, isDOSOrder: isDOSOrder) {
                            fileData.append(dataBlock)
                        } else {
                            // Read error or out of bounds, fill with zeros to maintain offset
                            fileData.append(Data(repeating: 0, count: 512))
                        }
                    }
                }
            }
        }
        else if storageType == 3 {
            // Tree file (master index -> index blocks -> data blocks)
            if let masterIndex = getBlockData(from: data, blockIndex: keyBlock, isDOSOrder: isDOSOrder) {
                for i in 0..<256 {
                    let indexBlockNum = Int(masterIndex[i]) | (Int(masterIndex[256 + i]) << 8)
                    
                    // Note: ProDOS Tech Ref says Tree files are generally full up to EOF, but can be sparse.
                    // If Master Index entry is 0, it represents 256 * 512 bytes of zeros.
                    
                    if indexBlockNum == 0 {
                         // Sparse hole: only append zeros up to EOF to avoid excessive allocation
                         let remaining = eof - fileData.count
                         if remaining <= 0 { break }
                         let chunkSize = min(512 * 256, remaining)
                         let sparseChunk = Data(repeating: 0, count: chunkSize)
                         fileData.append(sparseChunk)
                         continue
                    }
                    
                    if let indexBlock = getBlockData(from: data, blockIndex: indexBlockNum, isDOSOrder: isDOSOrder) {
                        for j in 0..<256 {
                            if fileData.count >= eof { break }
                            let dataBlockNum = Int(indexBlock[j]) | (Int(indexBlock[256 + j]) << 8)

                            if dataBlockNum == 0 {
                                fileData.append(Data(repeating: 0, count: min(512, eof - fileData.count)))
                            } else {
                                if let dataBlock = getBlockData(from: data, blockIndex: dataBlockNum, isDOSOrder: isDOSOrder) {
                                    fileData.append(dataBlock)
                                } else {
                                    fileData.append(Data(repeating: 0, count: min(512, eof - fileData.count)))
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // Trim to exact file size
        if fileData.count > eof {
            fileData = fileData.subdata(in: 0..<eof)
        }
        
        return fileData.isEmpty && eof > 0 ? nil : fileData
    }
    
    // MARK: - DOS 3.3 Catalog Reading (Standard)
    
    private static func readDOS33Catalog(data: Data, catalogTrack: Int, catalogSector: Int, sectorsPerTrack: Int, sectorSize: Int) -> [DiskCatalogEntry] {
        var entries: [DiskCatalogEntry] = []
        var currentTrack = catalogTrack
        var currentSector = catalogSector
        
        // DOS 3.3 stores sectors logically in .dsk usually, so simple offset calc works
        // unless it's a .nib file (which we aren't handling here).
        // Standard .dsk = DOS Order.
        
        for _ in 0..<100 {
            let catalogOffset = (currentTrack * sectorsPerTrack + currentSector) * sectorSize
            guard catalogOffset + sectorSize <= data.count else { break }
            
            for entryIdx in 0..<7 {
                let entryOffset = catalogOffset + 11 + (entryIdx * 35)
                guard entryOffset + 35 <= data.count else { continue }
                
                let trackList = Int(data[entryOffset])
                let sectorList = Int(data[entryOffset + 1])
                
                // Skip deleted/invalid entries
                if trackList == 0 || trackList == 0xFF { continue }
                
                // Validate track/sector are in range
                if trackList >= 35 || sectorList >= 16 { continue }
                
                var fileName = ""
                for i in 0..<30 {
                    var char = data[entryOffset + 3 + i] & 0x7F
                    // Names are space-padded to 30 characters and may contain spaces
                    if char == 0 { break }
                    if char < 0x20 { char += 0x40 }
                    if char > 0 { fileName.append(Character(UnicodeScalar(char))) }
                }
                fileName = fileName.trimmingCharacters(in: .whitespaces)
                if fileName.isEmpty { continue }
                
                // Additional validation: Check if filename contains mostly printable chars
                let printableCount = fileName.filter { char in
                    let scalar = char.unicodeScalars.first!
                    return scalar.value >= 32 && scalar.value < 127
                }.count
                
                // If less than 80% printable, probably garbage
                if printableCount < (fileName.count * 4) / 5 { continue }
                
                let fileType = data[entryOffset + 2] & 0x7F
                let locked = (data[entryOffset + 2] & 0x80) != 0
                
                // Read sector count from catalog (bytes 0x21-0x22, little-endian)
                let sectorCount = Int(data[entryOffset + 0x21]) | (Int(data[entryOffset + 0x22]) << 8)
                
                // Validate sector count is reasonable (0 means deleted, >560 is suspicious for 140KB disk)
                if sectorCount == 0 || sectorCount > 560 { continue }
                
                if let rawData = extractDOS33File(data: data, trackList: trackList, sectorList: sectorList, sectorsPerTrack: sectorsPerTrack, sectorSize: sectorSize) {

                    // Entries carry ProDOS file types and bare contents, like entries from any other
                    // disk, so the viewers and the writers treat them the same way
                    let (fileData, loadAddress) = stripDOS33Header(rawData, dos33Type: fileType)
                    let proDOSType = convertDOS33ToProDOSFileType(fileType)

                    let isGraphicsFile = (fileType == 0x04 || fileType == 0x42) && fileData.count > 8000

                    // Use sector count from catalog to determine displayed size
                    // This matches what DOS 3.3 CATALOG command shows
                    let displaySize = sectorCount * sectorSize

                    // Get DOS 3.3 specific file type string
                    let fileTypeString = getDOS33FileTypeString(fileType)

                    // DOS 3.3 access flags: locked = no write/delete
                    let dos33AccessFlags: UInt8 = locked ? 0x01 : 0xE3  // read-only vs full access

                    entries.append(DiskCatalogEntry(
                        name: fileName,
                        fileType: proDOSType.fileType,
                        fileTypeString: fileTypeString,
                        auxType: loadAddress ?? proDOSType.auxType,
                        size: displaySize,  // Use catalog sector count
                        blocks: sectorCount,
                        loadAddress: loadAddress.map { Int($0) },
                        length: fileData.count,  // Keep actual data length
                        data: fileData,
                        isImage: isGraphicsFile,
                        isDirectory: false,
                        children: nil,
                        storageType: nil,  // DOS 3.3 doesn't have storage types
                        keyPointer: trackList * 16 + sectorList,  // T/S list pointer as pseudo-key
                        accessFlags: dos33AccessFlags,
                        version: nil,
                        minVersion: nil,
                        headerPointer: nil,
                        isLocked: locked
                    ))
                }
            }
            
            let nextTrack = Int(data[catalogOffset + 1])
            let nextSector = Int(data[catalogOffset + 2])
            
            if nextTrack == 0 { break }
            currentTrack = nextTrack
            currentSector = nextSector
        }
        
        return entries
    }
    
    private static func extractDOS33File(data: Data, trackList: Int, sectorList: Int, sectorsPerTrack: Int, sectorSize: Int) -> Data? {
        var fileData = Data()
        var currentTrack = trackList
        var currentSector = sectorList
        
        for _ in 0..<1000 { // Limit T/S list traversal
            let tsListOffset = (currentTrack * sectorsPerTrack + currentSector) * sectorSize
            guard tsListOffset + sectorSize <= data.count else { break }
            
            for pairIdx in 0..<122 {
                let track = Int(data[tsListOffset + 12 + (pairIdx * 2)])
                let sector = Int(data[tsListOffset + 12 + (pairIdx * 2) + 1])
                
                if track == 0 { break } // End of sector list
                
                let dataOffset = (track * sectorsPerTrack + sector) * sectorSize
                guard dataOffset + sectorSize <= data.count else { continue }
                
                fileData.append(data.subdata(in: dataOffset..<(dataOffset + sectorSize)))
            }
            
            let nextTrack = Int(data[tsListOffset + 1])
            let nextSector = Int(data[tsListOffset + 2])
            
            if nextTrack == 0 { break }
            currentTrack = nextTrack
            currentSector = nextSector
        }
        
        return fileData.isEmpty ? nil : fileData
    }
}
