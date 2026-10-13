//
//  ProDOSWriter.swift
//  ProBrowse
//
//  Direct ProDOS disk image manipulation without external tools
//  Updated with sector interleaving support for .dsk/.do floppy images
//

import Foundation

class ProDOSWriter {
    static let shared = ProDOSWriter()
    
    private let BLOCK_SIZE = 512
    private let VOLUME_DIR_BLOCK = 2
    private let ENTRIES_PER_BLOCK = 13  // 0x0D
    private let ENTRY_LENGTH = 39       // 0x27
    
    // MARK: - DOS to ProDOS Sector Interleaving Map
    
    // DOS 3.3 logical sectors holding the lower and upper half of each of the
    // 8 ProDOS blocks in a track. The same map applies to every track.
    private let dosToProDOSMapData: [Int] = [0, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 15]
    
    private init() {}
    
    // MARK: - Volume Location
    
    /// Where the ProDOS volume sits inside the image file
    private struct VolumeLayout {
        let dataOffset: Int
        let isDOSOrder: Bool
    }
    
    /// Finds the volume directory by content, the same way DiskImageParser does, so the
    /// writer and the parser always agree on sector order.
    /// Returns nil if the image does not hold a ProDOS volume.
    private func locateVolume(_ diskData: Data) -> VolumeLayout? {
        let dataOffset = get2MGDataOffset(diskData)
        for isDOSOrder in [false, true] {
            guard let header = readBlock(diskData, blockIndex: VOLUME_DIR_BLOCK, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else { continue }
            if DiskImageParser.isValidProDOSVolumeHeader(header),
               Int(header[0x23]) == ENTRY_LENGTH, Int(header[0x24]) == ENTRIES_PER_BLOCK {
                return VolumeLayout(dataOffset: dataOffset, isDOSOrder: isDOSOrder)
            }
        }
        return nil
    }
    
    // MARK: - Block Read/Write with Interleaving Support
    
    /// Reads a 512-byte block from disk data, handling sector interleaving for floppy images
    private func readBlock(_ diskData: Data, blockIndex: Int, dataOffset: Int, isDOSOrder: Bool) -> Data? {
        if !isDOSOrder {
            // Standard ProDOS Order (.po, .hdv, .2mg): Linear access
            let offset = dataOffset + (blockIndex * BLOCK_SIZE)
            guard offset + BLOCK_SIZE <= diskData.count else { return nil }
            return diskData.subdata(in: offset..<(offset + BLOCK_SIZE))
        } else {
            // DOS Order (.dsk, .do): Interleaved sectors
            let blocksPerTrack = 8
            let track = blockIndex / blocksPerTrack
            let blockInTrack = blockIndex % blocksPerTrack
            
            let sectorSize = 256
            let trackOffset = dataOffset + (track * 16 * sectorSize)
            
            guard trackOffset < diskData.count else { return nil }
            
            let mapping = dosToProDOSMapData
            
            // Get the two sector indices for this block
            let lowerSectorIdx = mapping[blockInTrack * 2]
            let upperSectorIdx = mapping[blockInTrack * 2 + 1]
            
            let lowerOffset = trackOffset + (lowerSectorIdx * sectorSize)
            let upperOffset = trackOffset + (upperSectorIdx * sectorSize)
            
            guard lowerOffset + sectorSize <= diskData.count,
                  upperOffset + sectorSize <= diskData.count else { return nil }
            
            var blockData = Data()
            blockData.append(diskData.subdata(in: lowerOffset..<(lowerOffset + sectorSize)))
            blockData.append(diskData.subdata(in: upperOffset..<(upperOffset + sectorSize)))
            
            return blockData
        }
    }
    
    /// Writes a 512-byte block to disk data, handling sector interleaving for floppy images
    @discardableResult
    private func writeBlock(_ diskData: NSMutableData, blockIndex: Int, blockData: Data, dataOffset: Int, isDOSOrder: Bool) -> Bool {
        guard blockData.count == BLOCK_SIZE else {
            print("   ❌ Block data size mismatch: \(blockData.count) != \(BLOCK_SIZE)")
            return false
        }
        // The whole track (DOS order) or block (ProDOS order) must lie inside the image
        let blockEnd = isDOSOrder
            ? dataOffset + ((blockIndex / 8) + 1) * 16 * 256
            : dataOffset + (blockIndex + 1) * BLOCK_SIZE
        guard blockIndex >= 0, blockEnd <= diskData.length else {
            print("   ❌ Block \(blockIndex) is outside the disk image")
            return false
        }
        
        let bytes = diskData.mutableBytes.assumingMemoryBound(to: UInt8.self)
        
        if !isDOSOrder {
            // Standard ProDOS Order (.po, .hdv, .2mg): Linear access
            let offset = dataOffset + (blockIndex * BLOCK_SIZE)
            blockData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                _ = memcpy(bytes + offset, ptr.baseAddress!, BLOCK_SIZE)
            }
        } else {
            // DOS Order (.dsk, .do): Interleaved sectors
            let blocksPerTrack = 8
            let track = blockIndex / blocksPerTrack
            let blockInTrack = blockIndex % blocksPerTrack
            
            let sectorSize = 256
            let trackOffset = dataOffset + (track * 16 * sectorSize)
            
            let mapping = dosToProDOSMapData
            
            // Get the two sector indices for this block
            let lowerSectorIdx = mapping[blockInTrack * 2]
            let upperSectorIdx = mapping[blockInTrack * 2 + 1]
            
            let lowerOffset = trackOffset + (lowerSectorIdx * sectorSize)
            let upperOffset = trackOffset + (upperSectorIdx * sectorSize)
            
            // Write lower 256 bytes to first sector
            blockData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                memcpy(bytes + lowerOffset, ptr.baseAddress!, sectorSize)
                memcpy(bytes + upperOffset, ptr.baseAddress! + sectorSize, sectorSize)
            }
        }
        return true
    }
    
    // MARK: - 2MG Header Detection
    
    /// Current date and time as ProDOS words.
    /// Date: YYYYYYYM MMMDDDDD with a two-digit year; time: hour in the high byte, minute in the low byte.
    private func proDOSDateTimeNow() -> (date: UInt16, time: UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute], from: Date())
        let year = (c.year ?? 2000) % 100
        let date = UInt16((year << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
        let time = UInt16(((c.hour ?? 0) << 8) | (c.minute ?? 0))
        return (date, time)
    }
    
    /// Detects if disk image has 2MG header and returns data offset
    private func get2MGDataOffset(_ diskData: Data) -> Int {
        // Check for 2IMG/2MG signature
        if diskData.count >= 64 {
            let signature = diskData[0..<4]
            // "2IMG" signature
            if signature == Data([0x32, 0x49, 0x4D, 0x47]) {
                // The header gives the data offset at $18; it is 64 in practice
                let offset = Int(diskData[0x18]) | (Int(diskData[0x19]) << 8) |
                             (Int(diskData[0x1A]) << 16) | (Int(diskData[0x1B]) << 24)
                return (offset >= 64 && offset < diskData.count) ? offset : 64
            }
        }
        return 0  // No header, data starts at offset 0
    }
    
    // MARK: - Sanitize Filename
    
    /// Sanitizes a filename for ProDOS: removes invalid chars, max 15 chars, uppercase
    private func sanitizeProDOSFilename(_ filename: String) -> String {
        var name = filename.uppercased()
        
        // ProDOS allows: A-Z, 0-9, and period (.) - ASCII only
        name = name.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }
        
        // Max 15 characters
        if name.count > 15 {
            name = String(name.prefix(15))
        }
        
        // ProDOS requirement: First character must be a letter
        if let firstChar = name.first, !firstChar.isLetter {
            name = "A" + name  // Prepend 'A' if starts with number or period
            if name.count > 15 {
                name = String(name.prefix(15))
            }
        }
        
        // Ensure not empty
        if name.isEmpty {
            name = "UNNAMED"
        }
        
        return name
    }
    
    // MARK: - Add File to Disk Image
    
    /// Adds a file to a ProDOS disk image
    /// - Parameters:
    ///   - parentPath: Path to parent directory (e.g., "/" for root, "/SYSTEM" for subdirectory)
    func addFile(diskImagePath: URL, fileName: String, fileData: Data, fileType: UInt8, auxType: UInt16, parentPath: String = "/", completion: @escaping (Bool, String) -> Void) {
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Sanitize filename for ProDOS (remove invalid chars, max 15 chars)
                let sanitizedName = self.sanitizeProDOSFilename(fileName)
                
                // Load entire disk image into NSMutableData for safe byte manipulation
                guard let diskData = NSMutableData(contentsOf: diskImagePath) else {
                    DispatchQueue.main.async {
                        completion(false, "Could not read disk image")
                    }
                    return
                }
                
guard let volume = self.locateVolume(Data(referencing: diskData)) else {
                    DispatchQueue.main.async {
                        completion(false, "Not a ProDOS volume")
                    }
                    return
                }
                let dataOffset = volume.dataOffset
                let isDOSOrder = volume.isDOSOrder
                
                // EOF is a 3-byte field
                guard fileData.count <= 0xFFFFFF else {
                    DispatchQueue.main.async {
                        completion(false, "File is too large for ProDOS (16 MB maximum)")
                    }
                    return
                }
                
                // Find target directory block
                guard let targetDirBlock = self.findDirectoryBlock(diskData, path: parentPath, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else {
                    DispatchQueue.main.async {
                        completion(false, "Parent directory not found: \(parentPath)")
                    }
                    return
                }
                
                // Check if filename already exists in that directory and rename if needed
                var finalName = sanitizedName
                var counter = 1
                while self.findEntry(Data(referencing: diskData), directoryBlock: targetDirBlock, fileName: finalName, dataOffset: dataOffset, isDOSOrder: isDOSOrder) != nil {
                    // Auto-rename: FILENAME -> FILENAME.1, FILENAME.2, etc
                    let baseName = String(sanitizedName.prefix(13)) // Leave room for ".XX"
                    finalName = "\(baseName).\(counter)"
                    counter += 1
                    
                    if counter > 99 {
                        DispatchQueue.main.async {
                            completion(false, "Too many files with same name")
                        }
                        return
                    }
                }
                
                if finalName != sanitizedName {
                    print("   ⚠️ File exists - renamed to: \(finalName)")
                }
                
                print("📝 Adding file to ProDOS image:")
                print("   Original: \(fileName)")
                print("   Sanitized: \(sanitizedName)")
                print("   Final name: \(finalName)")
                print("   Parent path: \(parentPath)")
                print("   Size: \(fileData.count) bytes")
                print("   Type: $\(String(format: "%02X", fileType))")
                print("   Image: \(diskImagePath.lastPathComponent)")
                print("   DOS Order: \(isDOSOrder)")
                
                print("   📂 Target directory block: \(targetDirBlock)")
                
                // 1. Find free directory entry in target directory
                guard let (dirBlock, entryOffsetInBlock) = self.findFreeDirectoryEntry(diskData, dirBlock: targetDirBlock, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else {
                    DispatchQueue.main.async {
                        completion(false, "No free directory entries in \(parentPath)")
                    }
                    return
                }
                
                print("   📂 Free entry at block \(dirBlock), entry offset \(entryOffsetInBlock)")
                
                // 2. Allocate blocks for file data
                let blocksNeeded = max(1, (fileData.count + self.BLOCK_SIZE - 1) / self.BLOCK_SIZE)
                guard let dataBlocks = self.allocateBlocks(diskData, count: blocksNeeded, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else {
                    DispatchQueue.main.async {
                        completion(false, "Not enough free blocks (need \(blocksNeeded))")
                    }
                    return
                }
                
                print("   💾 Allocated \(blocksNeeded) blocks: \(dataBlocks)")
                
                // 3. Write file data to allocated blocks
                self.writeFileData(diskData, fileData: fileData, blocks: dataBlocks, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
                
                // 4. For sapling/tree files, create index block(s)
                var keyBlock = 0  // Will be set based on file type
                var totalBlocks = dataBlocks.count
                var storageType: UInt8 = 1  // Seedling
                
                if dataBlocks.isEmpty {
                    // Zero-length file - no blocks needed
                    keyBlock = 0
                    totalBlocks = 0
                    print("   📄 Zero-length file (no blocks)")
                    
                } else if dataBlocks.count > 256 {
                    // Tree file - need master index + multiple index blocks
                    let numIndexBlocks = (dataBlocks.count + 255) / 256  // Round up
                    
                    guard let indexBlocks = self.allocateBlocks(diskData, count: numIndexBlocks, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else {
                        DispatchQueue.main.async {
                            completion(false, "Could not allocate index blocks")
                        }
                        return
                    }
                    
                    guard let masterIndexBlocks = self.allocateBlocks(diskData, count: 1, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else {
                        DispatchQueue.main.async {
                            completion(false, "Could not allocate master index block")
                        }
                        return
                    }
                    
                    keyBlock = masterIndexBlocks[0]
                    storageType = 3
                    totalBlocks += numIndexBlocks + 1  // Include all index blocks + master
                    
                    // Create index blocks
                    for i in 0..<numIndexBlocks {
                        let startIdx = i * 256
                        let endIdx = min(startIdx + 256, dataBlocks.count)
                        let blocksForThisIndex = Array(dataBlocks[startIdx..<endIdx])
                        self.createIndexBlock(diskData, indexBlock: indexBlocks[i], dataBlocks: blocksForThisIndex, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
                    }
                    
                    // Create master index block pointing to index blocks
                    self.createMasterIndexBlock(diskData, masterIndexBlock: keyBlock, indexBlocks: indexBlocks, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
                    print("   🌳 Created tree file: master index at \(keyBlock), \(numIndexBlocks) index blocks")
                    
                } else if dataBlocks.count > 1 {
                    // Sapling file - need one index block
                    guard let indexBlocks = self.allocateBlocks(diskData, count: 1, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else {
                        DispatchQueue.main.async {
                            completion(false, "Could not allocate index block")
                        }
                        return
                    }
                    keyBlock = indexBlocks[0]
                    storageType = 2
                    totalBlocks += 1  // Include index block in count
                    self.createIndexBlock(diskData, indexBlock: keyBlock, dataBlocks: dataBlocks, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
                    print("   📇 Created index block at \(keyBlock)")
                    
                } else {
                    // Seedling file (1 block only)
                    keyBlock = dataBlocks[0]
                }
                
                // 5. Create directory entry
                self.createDirectoryEntry(diskData, dirBlock: dirBlock, entryOffsetInBlock: entryOffsetInBlock,
                                        fileName: finalName, fileType: fileType, auxType: auxType,
                                        storageType: storageType, headerPointer: targetDirBlock,
                                        keyBlock: keyBlock, blockCount: totalBlocks, fileSize: fileData.count,
                                        dataOffset: dataOffset, isDOSOrder: isDOSOrder)
                
                // 6. Update file count in target directory
                self.adjustFileCount(diskData, dirBlock: targetDirBlock, by: 1, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
                
                // 7. Write modified disk image back to file
                try diskData.write(to: diskImagePath, options: .atomic)
                
                print("   ✅ File added successfully!")
                
                DispatchQueue.main.async {
                    completion(true, "File added successfully")
                }
                
            } catch {
                print("   ❌ Error: \(error)")
                DispatchQueue.main.async {
                    completion(false, "Error writing disk: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Create Index Block
    
    /// Creates a master index block for tree files (storage type 3)
    private func createMasterIndexBlock(_ diskData: NSMutableData, masterIndexBlock: Int, indexBlocks: [Int], dataOffset: Int, isDOSOrder: Bool) {
        var blockData = Data(repeating: 0, count: BLOCK_SIZE)
        
        // Write index block pointers
        // Format: first 256 bytes are low bytes, second 256 bytes are high bytes
        for i in 0..<min(indexBlocks.count, 256) {
            let block = indexBlocks[i]
            blockData[i] = UInt8(block & 0xFF)
            blockData[256 + i] = UInt8((block >> 8) & 0xFF)
        }
        
        writeBlock(diskData, blockIndex: masterIndexBlock, blockData: blockData, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
    }
    
    /// Creates an index block for sapling files (storage type 2)
    private func createIndexBlock(_ diskData: NSMutableData, indexBlock: Int, dataBlocks: [Int], dataOffset: Int, isDOSOrder: Bool) {
        var blockData = Data(repeating: 0, count: BLOCK_SIZE)
        
        // Write data block pointers
        // Format: first 256 bytes are low bytes, second 256 bytes are high bytes
        for i in 0..<min(dataBlocks.count, 256) {
            let block = dataBlocks[i]
            blockData[i] = UInt8(block & 0xFF)
            blockData[256 + i] = UInt8((block >> 8) & 0xFF)
        }
        
        writeBlock(diskData, blockIndex: indexBlock, blockData: blockData, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
    }
    
    // MARK: - Directory Lookup
    
    /// Block numbers of a directory, following its chain from the key block.
    /// Stops at an unreadable block or a loop.
    private func directoryChain(_ diskData: Data, keyBlock: Int, dataOffset: Int, isDOSOrder: Bool) -> [Int] {
        var chain: [Int] = []
        var visited = Set<Int>()
        var currentBlock = keyBlock
        
        while currentBlock != 0, visited.insert(currentBlock).inserted,
              let blockData = readBlock(diskData, blockIndex: currentBlock, dataOffset: dataOffset, isDOSOrder: isDOSOrder) {
            chain.append(currentBlock)
            currentBlock = Int(blockData[2]) | (Int(blockData[3]) << 8)
        }
        
        return chain
    }
    
    /// Finds the key block of the directory at a path such as "/" or "/SYSTEM/FSTS/"
    private func findDirectoryBlock(_ diskData: NSMutableData, path: String, dataOffset: Int, isDOSOrder: Bool) -> Int? {
        let data = Data(referencing: diskData)
        var currentDirBlock = VOLUME_DIR_BLOCK
        
        for dirName in path.split(separator: "/").map(String.init) {
            guard let (block, entryOffset) = findEntry(data, directoryBlock: currentDirBlock, fileName: dirName, dataOffset: dataOffset, isDOSOrder: isDOSOrder),
                  let blockData = readBlock(data, blockIndex: block, dataOffset: dataOffset, isDOSOrder: isDOSOrder),
                  blockData[entryOffset] >> 4 == 0xD else {
                print("   ❌ Directory '\(dirName)' not found in path")
                return nil
            }
            currentDirBlock = Int(blockData[entryOffset + 0x11]) | (Int(blockData[entryOffset + 0x12]) << 8)
        }
        
        return currentDirBlock
    }
    
    /// Finds a named entry in one directory. Subdirectories are not searched.
    private func findEntry(_ diskData: Data, directoryBlock: Int, fileName: String, dataOffset: Int, isDOSOrder: Bool) -> (block: Int, entryOffsetInBlock: Int)? {
        let searchName = fileName.uppercased()
        let chain = directoryChain(diskData, keyBlock: directoryBlock, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
        
        for (chainIndex, block) in chain.enumerated() {
            guard let blockData = readBlock(diskData, blockIndex: block, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else { continue }
            
            // The first entry of the key block is the directory header
            for entryIndex in (chainIndex == 0 ? 1 : 0)..<ENTRIES_PER_BLOCK {
                let entryOffset = 4 + (entryIndex * ENTRY_LENGTH)
                guard blockData[entryOffset] >> 4 != 0 else { continue }
                
                let nameLength = Int(blockData[entryOffset] & 0x0F)
                let nameBytes = blockData[(entryOffset + 1)..<(entryOffset + 1 + nameLength)].map { $0 & 0x7F }
                if String(decoding: nameBytes, as: UTF8.self).uppercased() == searchName {
                    return (block, entryOffset)
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Find Free Directory Entry
    
    private func findFreeDirectoryEntry(_ diskData: NSMutableData, dirBlock: Int, dataOffset: Int, isDOSOrder: Bool) -> (block: Int, entryOffsetInBlock: Int)? {
        let data = Data(referencing: diskData)
        let chain = directoryChain(data, keyBlock: dirBlock, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
        
        for (chainIndex, block) in chain.enumerated() {
            guard let blockData = readBlock(data, blockIndex: block, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else { continue }
            
            for entryIndex in (chainIndex == 0 ? 1 : 0)..<ENTRIES_PER_BLOCK {
                let entryOffset = 4 + (entryIndex * ENTRY_LENGTH)
                if blockData[entryOffset] >> 4 == 0 {
                    return (block, entryOffset)
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Volume Bitmap
    
    /// Location of the volume bitmap and the number of blocks it covers
    private func bitmapLayout(_ diskData: Data, dataOffset: Int, isDOSOrder: Bool) -> (bitmapBlocks: Range<Int>, totalBlocks: Int)? {
        guard let volBlock = readBlock(diskData, blockIndex: VOLUME_DIR_BLOCK, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else {
            return nil
        }
        
        let bitmapStartBlock = Int(volBlock[0x27]) | (Int(volBlock[0x28]) << 8)
        // Never trust the header beyond the end of the image file
        let blocksInImage = (diskData.count - dataOffset) / BLOCK_SIZE
        let totalBlocks = min(Int(volBlock[0x29]) | (Int(volBlock[0x2A]) << 8), blocksInImage)
        let bitsPerBlock = BLOCK_SIZE * 8
        let bitmapBlockCount = (totalBlocks + bitsPerBlock - 1) / bitsPerBlock
        
        guard bitmapStartBlock > VOLUME_DIR_BLOCK, bitmapStartBlock + bitmapBlockCount <= totalBlocks else {
            print("   ❌ Invalid volume bitmap (start \(bitmapStartBlock), total blocks \(totalBlocks))")
            return nil
        }
        
        return (bitmapStartBlock..<(bitmapStartBlock + bitmapBlockCount), totalBlocks)
    }
    
    /// Whether a block number may be handed out or freed: inside the volume and
    /// not a boot, volume directory key or bitmap block
    private func isDataBlock(_ block: Int, layout: (bitmapBlocks: Range<Int>, totalBlocks: Int)) -> Bool {
        return block > VOLUME_DIR_BLOCK && block < layout.totalBlocks && !layout.bitmapBlocks.contains(block)
    }
    
    // MARK: - Allocate Blocks
    
    private func allocateBlocks(_ diskData: NSMutableData, count: Int, dataOffset: Int, isDOSOrder: Bool) -> [Int]? {
        guard count > 0 else { return [] }
        
        guard let layout = bitmapLayout(Data(referencing: diskData), dataOffset: dataOffset, isDOSOrder: isDOSOrder) else {
            return nil
        }
        
        print("   🔍 Searching for \(count) free blocks (total: \(layout.totalBlocks))")
        
        let inUse = blocksInUse(Data(referencing: diskData), dataOffset: dataOffset, isDOSOrder: isDOSOrder)
        
        var allocatedBlocks: [Int] = []
        var loadedBitmapBlock = -1
        var bitmapData = Data()
        var isDirty = false
        
        func flush() {
            if isDirty {
                writeBlock(diskData, blockIndex: loadedBitmapBlock, blockData: bitmapData, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
                isDirty = false
            }
        }
        
        for block in 0..<layout.totalBlocks {
            if allocatedBlocks.count >= count { break }
            guard isDataBlock(block, layout: layout), !inUse.contains(block) else { continue }
            
            let bitmapBlock = layout.bitmapBlocks.lowerBound + (block / (BLOCK_SIZE * 8))
            if bitmapBlock != loadedBitmapBlock {
                flush()
                guard let data = readBlock(Data(referencing: diskData), blockIndex: bitmapBlock, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else {
                    return nil
                }
                bitmapData = data
                loadedBitmapBlock = bitmapBlock
            }
            
            // Bit = 1 means the block is free
            let byteIndex = (block / 8) % BLOCK_SIZE
            let mask: UInt8 = 0x80 >> UInt8(block % 8)
            if bitmapData[byteIndex] & mask != 0 {
                bitmapData[byteIndex] &= ~mask
                isDirty = true
                allocatedBlocks.append(block)
            }
        }
        flush()
        
        return allocatedBlocks.count == count ? allocatedBlocks : nil
    }
    
    // MARK: - Write File Data
    
    private func writeFileData(_ diskData: NSMutableData, fileData: Data, blocks: [Int], dataOffset: Int, isDOSOrder: Bool) {
        print("   📝 Writing \(fileData.count) bytes to \(blocks.count) blocks")
        
        var dataPosition = 0
        
        for (index, block) in blocks.enumerated() {
            let bytesToWrite = min(BLOCK_SIZE, fileData.count - dataPosition)
            
            var blockData = Data(repeating: 0, count: BLOCK_SIZE)
            if bytesToWrite > 0 {
                blockData.replaceSubrange(0..<bytesToWrite, with: fileData.subdata(in: dataPosition..<(dataPosition + bytesToWrite)))
            }
            
            print("   📦 Block \(index): block#\(block), writing \(bytesToWrite) bytes")
            
            writeBlock(diskData, blockIndex: block, blockData: blockData, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
            
            dataPosition += bytesToWrite
        }
        
        print("   ✅ Wrote \(dataPosition) bytes total")
    }
    
    // MARK: - Create Directory Entry
    
    private func createDirectoryEntry(_ diskData: NSMutableData, dirBlock: Int, entryOffsetInBlock: Int,
                                     fileName: String, fileType: UInt8, auxType: UInt16,
                                     storageType: UInt8, headerPointer: Int,
                                     keyBlock: Int, blockCount: Int, fileSize: Int,
                                     dataOffset: Int, isDOSOrder: Bool) {
        
        // Read current directory block
        guard var blockData = readBlock(Data(referencing: diskData), blockIndex: dirBlock, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else {
            return
        }
        
        var nameBytes = [UInt8](repeating: 0x00, count: 15)
        let nameData = fileName.uppercased().data(using: .ascii) ?? Data()
        let nameLen = min(nameData.count, 15)
        for i in 0..<nameLen {
            nameBytes[i] = nameData[i]
        }
        
        print("   📝 Filename bytes: \(nameBytes.prefix(nameLen).map { String(format: "%02X", $0) }.joined(separator: " "))")
        
        var entry = [UInt8](repeating: 0, count: ENTRY_LENGTH)
        
        entry[0] = (storageType << 4) | UInt8(nameLen)
        
        for i in 0..<15 {
            entry[1 + i] = nameBytes[i]
        }
        
        entry[0x10] = fileType
        
        entry[0x11] = UInt8(keyBlock & 0xFF)
        entry[0x12] = UInt8((keyBlock >> 8) & 0xFF)
        
        entry[0x13] = UInt8(blockCount & 0xFF)
        entry[0x14] = UInt8((blockCount >> 8) & 0xFF)
        
        entry[0x15] = UInt8(fileSize & 0xFF)
        entry[0x16] = UInt8((fileSize >> 8) & 0xFF)
        entry[0x17] = UInt8((fileSize >> 16) & 0xFF)
        
        let stamp = proDOSDateTimeNow()
        entry[0x18] = UInt8(stamp.date & 0xFF)
        entry[0x19] = UInt8(stamp.date >> 8)
        entry[0x1A] = UInt8(stamp.time & 0xFF)
        entry[0x1B] = UInt8(stamp.time >> 8)
        
        entry[0x1C] = 0x00
        entry[0x1D] = 0x00
        entry[0x1E] = 0xE3
        
        entry[0x1F] = UInt8(auxType & 0xFF)
        entry[0x20] = UInt8((auxType >> 8) & 0xFF)
        
        entry[0x21] = entry[0x18]
        entry[0x22] = entry[0x19]
        entry[0x23] = entry[0x1A]
        entry[0x24] = entry[0x1B]
        
        // Key block of the directory that holds this entry
        entry[0x25] = UInt8(headerPointer & 0xFF)
        entry[0x26] = UInt8((headerPointer >> 8) & 0xFF)
        
        // Write entry into block data
        for i in 0..<ENTRY_LENGTH {
            blockData[entryOffsetInBlock + i] = entry[i]
        }
        
        // Write block back to disk
        writeBlock(diskData, blockIndex: dirBlock, blockData: blockData, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
    }
    
    // MARK: - File Count
    
    /// Adds `delta` to the file count in a directory's header (the first entry of its key block)
    private func adjustFileCount(_ diskData: NSMutableData, dirBlock: Int, by delta: Int, dataOffset: Int, isDOSOrder: Bool) {
        guard var blockData = readBlock(Data(referencing: diskData), blockIndex: dirBlock, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else {
            return
        }
        
        // File count at +$25-$26 (same for volume dir and subdirs)
        let fileCountOffset = 0x25
        let currentCount = Int(blockData[fileCountOffset]) | (Int(blockData[fileCountOffset + 1]) << 8)
        let fileCount = min(max(0, currentCount + delta), 0xFFFF)
        
        blockData[fileCountOffset] = UInt8(fileCount & 0xFF)
        blockData[fileCountOffset + 1] = UInt8((fileCount >> 8) & 0xFF)
        
        writeBlock(diskData, blockIndex: dirBlock, blockData: blockData, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
        
        print("   📊 Updated file count in block \(dirBlock): \(fileCount)")
    }
    
    // MARK: - Delete File
    
    /// Deletes a file or directory. A directory is deleted together with everything inside it.
    /// - Parameters:
    ///   - parentPath: Path of the directory that holds the entry (e.g., "/" or "/SYSTEM/")
    func deleteFile(diskImagePath: URL, fileName: String, parentPath: String, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let diskData = NSMutableData(contentsOf: diskImagePath) else {
                    DispatchQueue.main.async {
                        completion(false, "Could not read disk image")
                    }
                    return
                }
                
                guard let volume = self.locateVolume(Data(referencing: diskData)) else {
                    DispatchQueue.main.async {
                        completion(false, "Not a ProDOS volume")
                    }
                    return
                }
                let dataOffset = volume.dataOffset
                let isDOSOrder = volume.isDOSOrder
                
                print("🗑️ Deleting from ProDOS image: \(parentPath)\(fileName)")
                
                // Find the entry in its own directory
                guard let parentDirBlock = self.findDirectoryBlock(diskData, path: parentPath, dataOffset: dataOffset, isDOSOrder: isDOSOrder),
                      let (blockNum, entryOffsetInBlock) = self.findEntry(Data(referencing: diskData), directoryBlock: parentDirBlock, fileName: fileName, dataOffset: dataOffset, isDOSOrder: isDOSOrder),
                      var blockData = self.readBlock(Data(referencing: diskData), blockIndex: blockNum, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else {
                    DispatchQueue.main.async {
                        completion(false, "File not found")
                    }
                    return
                }
                
                // Collect every block the entry owns. The volume directory is seeded as
                // visited so a damaged subdirectory pointer can never lead back into it.
                var visited = Set(self.directoryChain(Data(referencing: diskData), keyBlock: self.VOLUME_DIR_BLOCK, dataOffset: dataOffset, isDOSOrder: isDOSOrder))
                guard let blocksToFree = self.blocksOwned(byEntryAt: entryOffsetInBlock, in: blockData, diskData: Data(referencing: diskData), dataOffset: dataOffset, isDOSOrder: isDOSOrder, visited: &visited) else {
                    DispatchQueue.main.async {
                        completion(false, "'\(fileName)' has a storage type that cannot be deleted")
                    }
                    return
                }
                
                print("   🔓 Freeing \(blocksToFree.count) blocks")
                
                // Mark blocks as free in bitmap
                self.freeBlocks(diskData, blocks: blocksToFree, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
                
                // Clear directory entry (mark as deleted)
                for i in 0..<self.ENTRY_LENGTH {
                    blockData[entryOffsetInBlock + i] = 0
                }
                
                // Write directory block back
                self.writeBlock(diskData, blockIndex: blockNum, blockData: blockData, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
                
                // Decrement file count of the directory that held the entry
                self.adjustFileCount(diskData, dirBlock: parentDirBlock, by: -1, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
                
                // Write back to disk
                try diskData.write(to: diskImagePath, options: .atomic)
                
                DispatchQueue.main.async {
                    completion(true, "File deleted successfully")
                }
                
                print("   ✅ File deleted successfully")
            } catch {
                DispatchQueue.main.async {
                    completion(false, "Error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// Blocks of one fork: its data blocks plus any index blocks
    private func forkBlocks(_ diskData: Data, storageType: UInt8, keyBlock: Int, dataOffset: Int, isDOSOrder: Bool) -> [Int] {
        // Non-zero pointers of an index block (zero marks a sparse hole)
        func pointers(in indexBlock: Int) -> [Int] {
            guard let data = readBlock(diskData, blockIndex: indexBlock, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else { return [] }
            return (0..<256).map { Int(data[$0]) | (Int(data[256 + $0]) << 8) }.filter { $0 != 0 }
        }
        
        switch storageType {
        case 1:
            // Seedling - just the data block
            return [keyBlock]
        case 2:
            // Sapling - index block + data blocks
            return pointers(in: keyBlock) + [keyBlock]
        default:
            // Tree - master index + index blocks + data blocks
            return pointers(in: keyBlock).flatMap { pointers(in: $0) + [$0] } + [keyBlock]
        }
    }
    
    /// Every block owned by a directory entry: its data and index blocks, both forks of an
    /// extended file, and for a subdirectory the directory blocks and everything inside it.
    /// Returns nil if the entry, or anything inside it, has a storage type this writer does not
    /// handle; with `skipUnknown` such entries are left out instead.
    private func blocksOwned(byEntryAt entryOffset: Int, in blockData: Data, diskData: Data, dataOffset: Int, isDOSOrder: Bool, visited: inout Set<Int>, skipUnknown: Bool = false) -> [Int]? {
        let storageType = blockData[entryOffset] >> 4
        let keyBlock = Int(blockData[entryOffset + 0x11]) | (Int(blockData[entryOffset + 0x12]) << 8)
        
        switch storageType {
        case 1, 2, 3:
            return forkBlocks(diskData, storageType: storageType, keyBlock: keyBlock, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
            
        case 5:
            // Extended key block: a mini-entry for the data fork at +0 and the resource fork at +256
            var blocks = [keyBlock]
            guard let extended = readBlock(diskData, blockIndex: keyBlock, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else { return blocks }
            for forkOffset in [0, 256] {
                let forkType = extended[forkOffset] & 0x0F
                let forkKey = Int(extended[forkOffset + 1]) | (Int(extended[forkOffset + 2]) << 8)
                if (1...3).contains(forkType) {
                    blocks += forkBlocks(diskData, storageType: forkType, keyBlock: forkKey, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
                }
            }
            return blocks
            
        case 0xD:
            var blocks: [Int] = []
            let chain = directoryChain(diskData, keyBlock: keyBlock, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
            for (chainIndex, block) in chain.enumerated() {
                guard visited.insert(block).inserted,
                      let dirData = readBlock(diskData, blockIndex: block, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else { continue }
                blocks.append(block)
                
                for entryIndex in (chainIndex == 0 ? 1 : 0)..<ENTRIES_PER_BLOCK {
                    let childOffset = 4 + (entryIndex * ENTRY_LENGTH)
                    guard dirData[childOffset] >> 4 != 0 else { continue }
                    guard let childBlocks = blocksOwned(byEntryAt: childOffset, in: dirData, diskData: diskData, dataOffset: dataOffset, isDOSOrder: isDOSOrder, visited: &visited, skipUnknown: skipUnknown) else {
                        return nil
                    }
                    blocks += childBlocks
                }
            }
            return blocks
            
        default:
            return skipUnknown ? [] : nil
        }
    }
    
    /// Every block the directory tree refers to: all directory blocks and all file blocks.
    /// Many disks have a bitmap that marks some of these free, so the allocator
    /// checks this set as well and never hands such a block out.
    private func blocksInUse(_ diskData: Data, dataOffset: Int, isDOSOrder: Bool) -> Set<Int> {
        var visited = Set<Int>()
        var inUse = Set<Int>()
        let chain = directoryChain(diskData, keyBlock: VOLUME_DIR_BLOCK, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
        
        for (chainIndex, block) in chain.enumerated() {
            guard visited.insert(block).inserted,
                  let dirData = readBlock(diskData, blockIndex: block, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else { continue }
            inUse.insert(block)
            
            for entryIndex in (chainIndex == 0 ? 1 : 0)..<ENTRIES_PER_BLOCK {
                let entryOffset = 4 + (entryIndex * ENTRY_LENGTH)
                guard dirData[entryOffset] >> 4 != 0 else { continue }
                inUse.formUnion(blocksOwned(byEntryAt: entryOffset, in: dirData, diskData: diskData, dataOffset: dataOffset, isDOSOrder: isDOSOrder, visited: &visited, skipUnknown: true) ?? [])
            }
        }
        
        return inUse
    }
    
    // MARK: - Free Blocks
    
    private func freeBlocks(_ diskData: NSMutableData, blocks: [Int], dataOffset: Int, isDOSOrder: Bool) {
        guard let layout = bitmapLayout(Data(referencing: diskData), dataOffset: dataOffset, isDOSOrder: isDOSOrder) else {
            return
        }
        
        for block in blocks {
            // A damaged index block can point anywhere; only free real data blocks
            guard isDataBlock(block, layout: layout) else { continue }
            
            let byteIndex = block / 8
            let bitPosition = 7 - (block % 8)
            
            let bitmapBlock = layout.bitmapBlocks.lowerBound + (byteIndex / BLOCK_SIZE)
            let bitmapByteOffset = byteIndex % BLOCK_SIZE
            
            guard var bitmapBlockData = readBlock(Data(referencing: diskData), blockIndex: bitmapBlock, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else {
                continue
            }
            
            bitmapBlockData[bitmapByteOffset] |= (1 << bitPosition)  // Set bit to 1 = free
            
            writeBlock(diskData, blockIndex: bitmapBlock, blockData: bitmapBlockData, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
        }
    }
    
    // MARK: - Create Directory
    
    func createDirectory(diskImagePath: URL, directoryName: String, parentPath: String = "/", completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let sanitizedName = self.sanitizeProDOSFilename(directoryName)
            
            guard let diskData = NSMutableData(contentsOf: diskImagePath) else {
                DispatchQueue.main.async {
                    completion(false, "Could not read disk image")
                }
                return
            }
            
            guard let volume = self.locateVolume(Data(referencing: diskData)) else {
                DispatchQueue.main.async {
                    completion(false, "Not a ProDOS volume")
                }
                return
            }
            let dataOffset = volume.dataOffset
            let isDOSOrder = volume.isDOSOrder
            
            // Find parent directory block
            guard let parentDirBlock = self.findDirectoryBlock(diskData, path: parentPath, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else {
                DispatchQueue.main.async {
                    completion(false, "Parent directory not found: \(parentPath)")
                }
                return
            }
            
            print("   📂 Parent directory block: \(parentDirBlock) (path: \(parentPath))")
            
            guard self.findEntry(Data(referencing: diskData), directoryBlock: parentDirBlock, fileName: sanitizedName, dataOffset: dataOffset, isDOSOrder: isDOSOrder) == nil else {
                DispatchQueue.main.async {
                    completion(false, "'\(sanitizedName)' already exists in \(parentPath)")
                }
                return
            }
            
            // Find free directory entry in parent
            guard let (entryDirBlock, entryOffsetInBlock) = self.findFreeDirectoryEntry(diskData, dirBlock: parentDirBlock, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else {
                DispatchQueue.main.async {
                    completion(false, "No free directory entries in \(parentPath)")
                }
                return
            }
            
            // Allocate a block for the new subdirectory
            guard let blocks = self.allocateBlocks(diskData, count: 1, dataOffset: dataOffset, isDOSOrder: isDOSOrder),
                  let dirBlock = blocks.first else {
                DispatchQueue.main.async {
                    completion(false, "Could not allocate block for directory")
                }
                return
            }
            
            print("📁 Creating directory '\(sanitizedName)' at block \(dirBlock)")
            
            // Create subdirectory header block
            let parentEntryNumber = (entryOffsetInBlock - 4) / self.ENTRY_LENGTH + 1
            self.createSubdirectoryHeader(diskData, dirBlock: dirBlock, dirName: sanitizedName, parentBlock: entryDirBlock, parentEntryNumber: parentEntryNumber, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
            
            // Create directory entry in parent
            self.createDirectoryEntryForSubdir(diskData, dirBlock: entryDirBlock, entryOffsetInBlock: entryOffsetInBlock, dirName: sanitizedName, keyBlock: dirBlock, headerPointer: parentDirBlock, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
            
            // Increment file count in parent directory
            self.adjustFileCount(diskData, dirBlock: parentDirBlock, by: 1, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
            
            // Write back to disk
            guard diskData.write(to: diskImagePath, atomically: true) else {
                DispatchQueue.main.async {
                    completion(false, "Failed to write disk image")
                }
                return
            }
            
            print("✅ Directory '\(sanitizedName)' created successfully")
            
            DispatchQueue.main.async {
                completion(true, "Directory created")
            }
        }
    }
    
    // MARK: - Create Subdirectory Header
    
    /// - Parameters:
    ///   - parentBlock: Block of the parent directory that holds this directory's entry
    ///   - parentEntryNumber: 1-based position of that entry within the block
    private func createSubdirectoryHeader(_ diskData: NSMutableData, dirBlock: Int, dirName: String, parentBlock: Int, parentEntryNumber: Int, dataOffset: Int, isDOSOrder: Bool) {
        var blockData = Data(repeating: 0, count: BLOCK_SIZE)
        
        // +$00-01: Previous block (0x0000 for first block)
        blockData[0] = 0x00
        blockData[1] = 0x00
        
        // +$02-03: Next block (0x0000 - no next block initially)
        blockData[2] = 0x00
        blockData[3] = 0x00
        
        // +$04: Storage type (0xE = subdirectory header) + name length
        let nameLength = min(dirName.count, 15)
        blockData[4] = UInt8(0xE0 | nameLength)
        
        // +$05-$13: Directory name (15 bytes)
        for i in 0..<nameLength {
            let index = dirName.index(dirName.startIndex, offsetBy: i)
            blockData[5 + i] = UInt8(dirName[index].asciiValue ?? 0x20)
        }
        
        // +$14: Reserved, $75 in a subdirectory header
        blockData[0x14] = 0x75
        
        // +$1C-$1F: Creation date/time
        let stamp = proDOSDateTimeNow()
        blockData[0x1C] = UInt8(stamp.date & 0xFF)
        blockData[0x1D] = UInt8(stamp.date >> 8)
        blockData[0x1E] = UInt8(stamp.time & 0xFF)
        blockData[0x1F] = UInt8(stamp.time >> 8)
        
        // +$20: Version (0x00)
        blockData[0x20] = 0x00
        
        // +$21: Min version (0x00)
        blockData[0x21] = 0x00
        
        // +$22: Access (0xE3 = full access)
        blockData[0x22] = 0xE3
        
        // +$23: Entry length (0x27 = 39 bytes)
        blockData[0x23] = 0x27
        
        // +$24: Entries per block (0x0D = 13)
        blockData[0x24] = 0x0D
        
        // +$25-$26: File count (0x0000 initially - empty directory)
        blockData[0x25] = 0x00
        blockData[0x26] = 0x00
        
        // +$27-$28: Parent pointer (block of the parent directory that holds our entry)
        blockData[0x27] = UInt8(parentBlock & 0xFF)
        blockData[0x28] = UInt8((parentBlock >> 8) & 0xFF)
        
        // +$29: Parent entry number
        blockData[0x29] = UInt8(parentEntryNumber)
        
        // +$2A: Parent entry length (0x27)
        blockData[0x2A] = 0x27
        
        writeBlock(diskData, blockIndex: dirBlock, blockData: blockData, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
    }
    
    // MARK: - Create Directory Entry for Subdirectory
    
    private func createDirectoryEntryForSubdir(_ diskData: NSMutableData, dirBlock: Int, entryOffsetInBlock: Int, dirName: String, keyBlock: Int, headerPointer: Int, dataOffset: Int, isDOSOrder: Bool) {
        guard var blockData = readBlock(Data(referencing: diskData), blockIndex: dirBlock, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else {
            return
        }
        
        let nameLength = min(dirName.count, 15)
        
        // Storage type 0xD = subdirectory
        blockData[entryOffsetInBlock] = UInt8(0xD0 | nameLength)
        
        // Name
        for i in 0..<nameLength {
            let index = dirName.index(dirName.startIndex, offsetBy: i)
            blockData[entryOffsetInBlock + 1 + i] = UInt8(dirName[index].asciiValue ?? 0x20)
        }
        
        // File type = 0x0F (directory)
        blockData[entryOffsetInBlock + 0x10] = 0x0F
        
        // Key block
        blockData[entryOffsetInBlock + 0x11] = UInt8(keyBlock & 0xFF)
        blockData[entryOffsetInBlock + 0x12] = UInt8((keyBlock >> 8) & 0xFF)
        
        // Blocks used = 1
        blockData[entryOffsetInBlock + 0x13] = 0x01
        blockData[entryOffsetInBlock + 0x14] = 0x00
        
        // EOF = 512 (1 block)
        blockData[entryOffsetInBlock + 0x15] = 0x00
        blockData[entryOffsetInBlock + 0x16] = 0x02
        blockData[entryOffsetInBlock + 0x17] = 0x00
        
        // Creation date/time
        let stamp = proDOSDateTimeNow()
        blockData[entryOffsetInBlock + 0x18] = UInt8(stamp.date & 0xFF)
        blockData[entryOffsetInBlock + 0x19] = UInt8(stamp.date >> 8)
        blockData[entryOffsetInBlock + 0x1A] = UInt8(stamp.time & 0xFF)
        blockData[entryOffsetInBlock + 0x1B] = UInt8(stamp.time >> 8)
        
        // Version, min version
        blockData[entryOffsetInBlock + 0x1C] = 0x00
        blockData[entryOffsetInBlock + 0x1D] = 0x00
        
        // Access
        blockData[entryOffsetInBlock + 0x1E] = 0xE3
        
        // Aux type = 0x0000 for directories
        blockData[entryOffsetInBlock + 0x1F] = 0x00
        blockData[entryOffsetInBlock + 0x20] = 0x00
        
        // Last mod = creation
        blockData[entryOffsetInBlock + 0x21] = blockData[entryOffsetInBlock + 0x18]
        blockData[entryOffsetInBlock + 0x22] = blockData[entryOffsetInBlock + 0x19]
        blockData[entryOffsetInBlock + 0x23] = blockData[entryOffsetInBlock + 0x1A]
        blockData[entryOffsetInBlock + 0x24] = blockData[entryOffsetInBlock + 0x1B]
        
        // Header pointer: key block of the directory that holds this entry
        blockData[entryOffsetInBlock + 0x25] = UInt8(headerPointer & 0xFF)
        blockData[entryOffsetInBlock + 0x26] = UInt8((headerPointer >> 8) & 0xFF)
        
        writeBlock(diskData, blockIndex: dirBlock, blockData: blockData, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
    }
    
    // MARK: - Rename File
    
    /// Renames a file or directory
    /// - Parameters:
    ///   - parentPath: Path of the directory that holds the entry (e.g., "/" or "/SYSTEM/")
    func renameFile(diskImagePath: URL, oldName: String, newName: String, parentPath: String, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let diskData = NSMutableData(contentsOf: diskImagePath) else {
                    DispatchQueue.main.async {
                        completion(false, "Could not read disk image")
                    }
                    return
                }
                
                guard let volume = self.locateVolume(Data(referencing: diskData)) else {
                    DispatchQueue.main.async {
                        completion(false, "Not a ProDOS volume")
                    }
                    return
                }
                let dataOffset = volume.dataOffset
                let isDOSOrder = volume.isDOSOrder
                
                print("✏️ Renaming in ProDOS image: \(parentPath)\(oldName) → \(newName)")
                
                // Find the entry in its own directory
                guard let parentDirBlock = self.findDirectoryBlock(diskData, path: parentPath, dataOffset: dataOffset, isDOSOrder: isDOSOrder),
                      let (blockNum, entryOffsetInBlock) = self.findEntry(Data(referencing: diskData), directoryBlock: parentDirBlock, fileName: oldName, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else {
                    DispatchQueue.main.async {
                        completion(false, "File '\(oldName)' not found")
                    }
                    return
                }
                
                // Sanitize new name
                let sanitizedName = self.sanitizeProDOSFilename(newName)
                print("   Sanitized name: \(sanitizedName)")
                
                // Check if new name already exists in the same directory
                if let existing = self.findEntry(Data(referencing: diskData), directoryBlock: parentDirBlock, fileName: sanitizedName, dataOffset: dataOffset, isDOSOrder: isDOSOrder),
                   existing != (blockNum, entryOffsetInBlock) {
                    DispatchQueue.main.async {
                        completion(false, "A file named '\(sanitizedName)' already exists")
                    }
                    return
                }
                
                // Read directory block
                guard var blockData = self.readBlock(Data(referencing: diskData), blockIndex: blockNum, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else {
                    DispatchQueue.main.async {
                        completion(false, "Could not read directory block")
                    }
                    return
                }
                
                let storageType = blockData[entryOffsetInBlock] >> 4
                let nameBytes = Array(sanitizedName.utf8.prefix(15))
                
                /// Writes the storage type / name length byte and the 15-byte name field
                func writeName(_ block: inout Data, at offset: Int, storageType: UInt8) {
                    block[offset] = (storageType << 4) | UInt8(nameBytes.count)
                    for i in 0..<15 {
                        block[offset + 1 + i] = i < nameBytes.count ? nameBytes[i] : 0x00
                    }
                }
                
                writeName(&blockData, at: entryOffsetInBlock, storageType: storageType)
                self.writeBlock(diskData, blockIndex: blockNum, blockData: blockData, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
                
                // A directory also carries its name in the header of its key block
                if storageType == 0xD {
                    let keyBlock = Int(blockData[entryOffsetInBlock + 0x11]) | (Int(blockData[entryOffsetInBlock + 0x12]) << 8)
                    if var headerBlock = self.readBlock(Data(referencing: diskData), blockIndex: keyBlock, dataOffset: dataOffset, isDOSOrder: isDOSOrder),
                       headerBlock[4] >> 4 == 0xE {
                        writeName(&headerBlock, at: 4, storageType: 0xE)
                        self.writeBlock(diskData, blockIndex: keyBlock, blockData: headerBlock, dataOffset: dataOffset, isDOSOrder: isDOSOrder)
                    }
                }
                
                // Write to disk
                try diskData.write(to: diskImagePath, options: .atomic)
                
                DispatchQueue.main.async {
                    completion(true, "File renamed successfully")
                }
                
                print("   ✅ File renamed successfully!")
                
            } catch {
                DispatchQueue.main.async {
                    completion(false, "Error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Create Disk Image
    
    func createDiskImage(at path: URL, volumeName: String, sizeString: String, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let totalBlocks: Int
                if sizeString.uppercased().contains("MB") {
                    let mb = Int(sizeString.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 32
                    let calculatedBlocks = (mb * 1024 * 1024) / self.BLOCK_SIZE
                    totalBlocks = min(calculatedBlocks, 65535)
                } else if sizeString.uppercased().contains("KB") {
                    let kb = Int(sizeString.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 800
                    let calculatedBlocks = (kb * 1024) / self.BLOCK_SIZE
                    totalBlocks = min(calculatedBlocks, 65535)
                } else {
                    totalBlocks = 65535
                }
                
                print("📝 Creating ProDOS disk image:")
                print("   Path: \(path.path)")
                print("   Volume: \(volumeName)")
                print("   Blocks: \(totalBlocks)")
                
                let diskData = NSMutableData(length: totalBlocks * self.BLOCK_SIZE)!
                
                // Note: New disk images are created in ProDOS order (linear), not DOS order
                self.createBootBlocks(diskData)
                self.createVolumeDirectory(diskData, volumeName: volumeName, totalBlocks: totalBlocks)
                self.createBitmap(diskData, totalBlocks: totalBlocks)
                
                if path.pathExtension.lowercased() == "2mg" {
                    let image = self.twoIMGHeader(blockCount: totalBlocks) + (diskData as Data)
                    try image.write(to: path, options: .atomic)
                } else {
                    try diskData.write(to: path, options: .atomic)
                }
                
                print("   ✅ Disk image created successfully!")
                
                DispatchQueue.main.async {
                    completion(true, "Disk image created successfully")
                }
                
            } catch {
                print("   ❌ Error: \(error)")
                DispatchQueue.main.async {
                    completion(false, "Error creating disk: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// The 64-byte header of a 2IMG file holding a ProDOS-ordered image
    private func twoIMGHeader(blockCount: Int) -> Data {
        func le32(_ value: Int) -> [UInt8] {
            return (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) }
        }
        
        var header = Data()
        header.append(contentsOf: Array("2IMG".utf8))        // Magic
        header.append(contentsOf: Array("PRBR".utf8))        // Creator
        header.append(contentsOf: [64, 0])                   // Header size
        header.append(contentsOf: [1, 0])                    // Version
        header.append(contentsOf: le32(1))                   // Image format: ProDOS order
        header.append(contentsOf: le32(0))                   // Flags
        header.append(contentsOf: le32(blockCount))          // ProDOS blocks
        header.append(contentsOf: le32(64))                  // Offset to disk data
        header.append(contentsOf: le32(blockCount * BLOCK_SIZE))  // Length of disk data
        header.append(Data(count: 64 - header.count))        // No comment or creator data
        return header
    }
    
    // MARK: - Create Boot Blocks
    
    private func createBootBlocks(_ diskData: NSMutableData) {
        let bytes = diskData.mutableBytes.assumingMemoryBound(to: UInt8.self)
        
        // Standard ProDOS boot loader (first 512 bytes)
        let bootCode: [UInt8] = [
            0x01, 0x38, 0xB0, 0x03, 0x4C, 0x32, 0xA1, 0x86, 0x43, 0xC9, 0x03, 0x08, 0x8A, 0x29, 0x70, 0x4A,
            0x4A, 0x4A, 0x4A, 0x09, 0xC0, 0x85, 0x49, 0xA0, 0xFF, 0x84, 0x48, 0x28, 0xC8, 0xB1, 0x48, 0xD0,
            0x3A, 0xB0, 0x0E, 0xA9, 0x03, 0x8D, 0x00, 0x08, 0xE6, 0x3D, 0xA5, 0x49, 0x48, 0xA9, 0x5B, 0x48,
            0x60, 0x85, 0x40, 0x85, 0x48, 0xA0, 0x63, 0xB1, 0x48, 0x99, 0x94, 0x09, 0xC8, 0xC0, 0xEB, 0xD0,
            0xF6, 0xA2, 0x06, 0xBC, 0x1D, 0x09, 0xBD, 0x24, 0x09, 0x99, 0xF2, 0x09, 0xBD, 0x2B, 0x09, 0x9D,
            0x7F, 0x0A, 0xCA, 0x10, 0xEE, 0xA9, 0x09, 0x85, 0x49, 0xA9, 0x86, 0xA0, 0x00, 0xC9, 0xF9, 0xB0,
            0x2F, 0x85, 0x48, 0x84, 0x60, 0x84, 0x4A, 0x84, 0x4C, 0x84, 0x4E, 0x84, 0x47, 0xC8, 0x84, 0x42,
            0xC8, 0x84, 0x46, 0xA9, 0x0C, 0x85, 0x61, 0x85, 0x4B, 0x20, 0x12, 0x09, 0xB0, 0x68, 0xE6, 0x61
        ]
        
        for (i, byte) in bootCode.enumerated() {
            bytes[i] = byte
        }
    }
    
    // MARK: - Create Volume Directory
    
    private func createVolumeDirectory(_ diskData: NSMutableData, volumeName: String, totalBlocks: Int) {
        let bytes = diskData.mutableBytes.assumingMemoryBound(to: UInt8.self)
        let blockOffset = VOLUME_DIR_BLOCK * BLOCK_SIZE
        
        // Clear the block
        memset(bytes + blockOffset, 0, BLOCK_SIZE)
        
        // +$00-01: Previous block (0x0000)
        bytes[blockOffset + 0] = 0x00
        bytes[blockOffset + 1] = 0x00
        
        // +$02-03: Next block (block 3 for volume directory)
        bytes[blockOffset + 2] = 0x03
        bytes[blockOffset + 3] = 0x00
        
        // +$04: Storage type (0xF = volume header) + name length
        let nameLength = min(volumeName.count, 15)
        bytes[blockOffset + 4] = UInt8(0xF0 | nameLength)
        
        // +$05-$13: Volume name (15 bytes)
        for i in 0..<nameLength {
            let index = volumeName.index(volumeName.startIndex, offsetBy: i)
            bytes[blockOffset + 5 + i] = UInt8(volumeName[index].asciiValue ?? 0x20)
        }
        
        // Creation date/time
        let stamp = proDOSDateTimeNow()
        bytes[blockOffset + 0x1C] = UInt8(stamp.date & 0xFF)
        bytes[blockOffset + 0x1D] = UInt8(stamp.date >> 8)
        bytes[blockOffset + 0x1E] = UInt8(stamp.time & 0xFF)
        bytes[blockOffset + 0x1F] = UInt8(stamp.time >> 8)
        
        // +$20: Version (0x00)
        bytes[blockOffset + 0x20] = 0x00
        
        // +$21: Min version (0x00)
        bytes[blockOffset + 0x21] = 0x00
        
        // +$22: Access (0xC3)
        bytes[blockOffset + 0x22] = 0xC3
        
        // +$23: Entry length (0x27 = 39)
        bytes[blockOffset + 0x23] = 0x27
        
        // +$24: Entries per block (0x0D = 13)
        bytes[blockOffset + 0x24] = 0x0D
        
        // +$25-$26: File count (0x0000)
        bytes[blockOffset + 0x25] = 0x00
        bytes[blockOffset + 0x26] = 0x00
        
        // +$27-$28: Bitmap pointer (block 6)
        bytes[blockOffset + 0x27] = 0x06
        bytes[blockOffset + 0x28] = 0x00
        
        // +$29-$2A: Total blocks
        bytes[blockOffset + 0x29] = UInt8(totalBlocks & 0xFF)
        bytes[blockOffset + 0x2A] = UInt8((totalBlocks >> 8) & 0xFF)
        
        // Create additional directory blocks (3, 4, 5)
        for additionalBlock in 3...5 {
            let addBlockOffset = additionalBlock * BLOCK_SIZE
            memset(bytes + addBlockOffset, 0, BLOCK_SIZE)
            
            // Previous block
            bytes[addBlockOffset + 0] = UInt8((additionalBlock - 1) & 0xFF)
            bytes[addBlockOffset + 1] = 0x00
            
            // Next block (0 for last block)
            if additionalBlock < 5 {
                bytes[addBlockOffset + 2] = UInt8((additionalBlock + 1) & 0xFF)
                bytes[addBlockOffset + 3] = 0x00
            }
        }
    }
    
    // MARK: - Create Bitmap
    
    private func createBitmap(_ diskData: NSMutableData, totalBlocks: Int) {
        let bytes = diskData.mutableBytes.assumingMemoryBound(to: UInt8.self)
        let bitmapStartBlock = 6
        let bitmapBytes = (totalBlocks + 7) / 8
        let bitmapBlocks = (bitmapBytes + BLOCK_SIZE - 1) / BLOCK_SIZE
        
        print("   🗺️  Creating bitmap: \(bitmapBlocks) blocks")
        
        let bitmapOffset = bitmapStartBlock * BLOCK_SIZE
        memset(bytes + bitmapOffset, 0xFF, bitmapBytes)
        
        let systemBlocks = 6 + bitmapBlocks
        for block in 0..<systemBlocks {
            let byteIndex = block / 8
            let bitPosition = 7 - (block % 8)
            bytes[bitmapOffset + byteIndex] &= ~(1 << bitPosition)
        }
        
        print("   ✅ Marked blocks 0-\(systemBlocks - 1) as used")
    }

    // MARK: - Set File Type and Aux Type

    /// Changes the file type and aux type of an existing file on a ProDOS disk
    /// - Parameters:
    ///   - parentPath: Path of the directory that holds the file (e.g., "/" or "/SYSTEM/")
    func setFileType(diskImagePath: URL, fileName: String, parentPath: String, fileType: UInt8, auxType: UInt16, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let diskData = NSMutableData(contentsOf: diskImagePath) else {
                    DispatchQueue.main.async {
                        completion(false, "Could not read disk image")
                    }
                    return
                }

                guard let volume = self.locateVolume(Data(referencing: diskData)) else {
                    DispatchQueue.main.async {
                        completion(false, "Not a ProDOS volume")
                    }
                    return
                }
                let dataOffset = volume.dataOffset
                let isDOSOrder = volume.isDOSOrder

                // Find the file in its own directory
                guard let parentDirBlock = self.findDirectoryBlock(diskData, path: parentPath, dataOffset: dataOffset, isDOSOrder: isDOSOrder),
                      let (entryBlockIndex, entryOffset) = self.findEntry(Data(referencing: diskData), directoryBlock: parentDirBlock, fileName: fileName, dataOffset: dataOffset, isDOSOrder: isDOSOrder),
                      var blockData = self.readBlock(Data(referencing: diskData), blockIndex: entryBlockIndex, dataOffset: dataOffset, isDOSOrder: isDOSOrder) else {
                    DispatchQueue.main.async {
                        completion(false, "File '\(fileName)' not found")
                    }
                    return
                }

                // File type at +$10, aux type at +$1F-$20 (little-endian)
                blockData[entryOffset + 0x10] = fileType
                blockData[entryOffset + 0x1F] = UInt8(auxType & 0xFF)
                blockData[entryOffset + 0x20] = UInt8((auxType >> 8) & 0xFF)

                self.writeBlock(diskData, blockIndex: entryBlockIndex, blockData: blockData, dataOffset: dataOffset, isDOSOrder: isDOSOrder)

                try diskData.write(to: diskImagePath, options: .atomic)

                DispatchQueue.main.async {
                    completion(true, "File type changed successfully")
                }
            } catch {
                DispatchQueue.main.async {
                    completion(false, "Error: \(error.localizedDescription)")
                }
            }
        }
    }
}
