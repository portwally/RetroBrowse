//
//  main.swift
//  WriterTests
//
//  Round-trip tests for ProDOSWriter, DOS33Writer and DiskImageParser.
//  Run with Tests/run-tests.sh
//

import Foundation

// MARK: - Harness

var failureCount = 0
var checkCount = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checkCount += 1
    if !condition() {
        failureCount += 1
        FileHandle.standardError.write("FAIL (line \(line)): \(message)\n".data(using: .utf8)!)
    }
}

/// Runs a writer call and waits for its completion, which arrives on the main queue
func wait(_ body: (@escaping (Bool, String) -> Void) -> Void) -> (ok: Bool, message: String) {
    var result: (Bool, String)?
    body { result = ($0, $1) }
    while result == nil {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
    return result!
}

let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("probrowse-tests-\(ProcessInfo.processInfo.processIdentifier)")
try! FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDir) }

func bytes(_ count: Int, seed: UInt8) -> Data {
    return Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}

// MARK: - ProDOS helpers (independent of the code under test)

/// DOS 3.3 logical sectors holding the two halves of each block in a track
let blockSectors = [(0, 14), (13, 12), (11, 10), (9, 8), (7, 6), (5, 4), (3, 2), (1, 15)]

/// Re-orders a ProDOS-ordered 140K image into DOS order
func dosOrdered(_ po: Data) -> Data {
    var out = Data(count: po.count)
    for block in 0..<(po.count / 512) {
        let track = block / 8
        let (lower, upper) = blockSectors[block % 8]
        let source = block * 512
        out.replaceSubrange((track * 16 + lower) * 256..<(track * 16 + lower + 1) * 256, with: po[source..<(source + 256)])
        out.replaceSubrange((track * 16 + upper) * 256..<(track * 16 + upper + 1) * 256, with: po[(source + 256)..<(source + 512)])
    }
    return out
}

/// Free blocks according to the volume bitmap of a ProDOS-ordered image
func freeBlockCount(_ po: Data) -> Int {
    let total = Int(po[1024 + 0x29]) | (Int(po[1024 + 0x2A]) << 8)
    let bitmap = (Int(po[1024 + 0x27]) | (Int(po[1024 + 0x28]) << 8)) * 512
    return (0..<total).filter { po[bitmap + $0 / 8] & (0x80 >> UInt8($0 % 8)) != 0 }.count
}

func newProDOSImage(_ name: String, size: String) -> URL {
    let url = workDir.appendingPathComponent(name)
    let result = wait { ProDOSWriter.shared.createDiskImage(at: url, volumeName: "TEST", sizeString: size, completion: $0) }
    check(result.ok, "create \(name): \(result.message)")
    return url
}

func catalog(_ url: URL) -> DiskCatalog? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? DiskImageParser.parseProDOS(data: data, diskName: url.lastPathComponent)) ?? nil
}

func find(_ catalog: DiskCatalog?, _ path: String) -> DiskCatalogEntry? {
    return catalog?.allEntries.first { $0.parentPath + $0.name == path }
}

func add(_ url: URL, _ name: String, _ data: Data, parent: String = "/", type: UInt8 = 0x06) -> (ok: Bool, message: String) {
    return wait { ProDOSWriter.shared.addFile(diskImagePath: url, fileName: name, fileData: data, fileType: type, auxType: 0x2000, parentPath: parent, completion: $0) }
}

// MARK: - ProDOS: storage types

do {
    let url = newProDOSImage("sizes.po", size: "800KB")
    check(catalog(url)?.diskName == "TEST", "new image parses with its volume name")
    let free = freeBlockCount(try! Data(contentsOf: url))

    // (size, expected storage type): seedling, sapling boundaries, tree
    let cases: [(Int, UInt8)] = [(0, 1), (1, 1), (512, 1), (513, 2), (130_561, 2), (131_072, 2), (131_073, 3)]
    for (index, (size, storageType)) in cases.enumerated() {
        let name = "F\(index)"
        let data = bytes(size, seed: UInt8(index))
        let result = add(url, name, data)
        check(result.ok, "add \(size) bytes: \(result.message)")
        let entry = find(catalog(url), "/" + name)
        check(entry?.data == data, "\(size)-byte file reads back unchanged")
        check(entry?.storageType == storageType, "\(size)-byte file has storage type \(storageType), got \(String(describing: entry?.storageType))")
        check(entry?.headerPointer == 2, "\(size)-byte file's header pointer is the volume directory")
        check(entry?.modificationDate != nil, "\(size)-byte file has a valid date")
    }
    for index in cases.indices {
        let result = wait { ProDOSWriter.shared.deleteFile(diskImagePath: url, fileName: "F\(index)", parentPath: "/", completion: $0) }
        check(result.ok, "delete F\(index): \(result.message)")
    }
    check(catalog(url)?.entries.isEmpty == true, "all files deleted")
    check(freeBlockCount(try! Data(contentsOf: url)) == free, "every block is free again after deleting")
}

// MARK: - ProDOS: 2IMG images

do {
    let url = newProDOSImage("new.2mg", size: "800KB")
    let image = try! Data(contentsOf: url)
    check(image.count == 64 + 1600 * 512, "a new .2mg is 64 bytes longer than its 800K volume")
    check(String(decoding: image[0..<4], as: UTF8.self) == "2IMG" && image[12] == 1 && image[20] == 0x40 && image[21] == 0x06 && image[24] == 64,
          "the 2IMG header gives ProDOS order, 1600 blocks and a data offset of 64")
    check(add(url, "INSIDE", bytes(3000, seed: 2)).ok, "add to a .2mg")
    check(find(catalog(url), "/INSIDE")?.data == bytes(3000, seed: 2), "file added to a .2mg reads back")
}

// MARK: - ProDOS: dates

do {
    let url = newProDOSImage("dates.po", size: "140KB")
    _ = add(url, "STAMP", bytes(10, seed: 1))
    let image = try! Data(contentsOf: url)
    // First file entry is the second entry of block 2
    let entry = 1024 + 4 + 39
    let date = Int(image[entry + 0x18]) | (Int(image[entry + 0x19]) << 8)
    let now = Calendar(identifier: .gregorian).dateComponents([.year, .month, .hour], from: Date())
    check(date >> 9 == now.year! % 100, "year is stored as two digits")
    check((date >> 5) & 0x0F == now.month!, "month is stored")
    check(Int(image[entry + 0x1B]) <= 23 && abs(Int(image[entry + 0x1B]) - now.hour!) <= 1 || now.hour == 0, "hour is in the high byte of the time word")
}

// MARK: - ProDOS: same name in different directories

do {
    let url = newProDOSImage("dirs.po", size: "140KB")
    let free = freeBlockCount(try! Data(contentsOf: url))
    let rootData = bytes(700, seed: 1), subData = bytes(900, seed: 2)

    check(wait { ProDOSWriter.shared.createDirectory(diskImagePath: url, directoryName: "GAMES", parentPath: "/", completion: $0) }.ok, "create /GAMES")
    check(!wait { ProDOSWriter.shared.createDirectory(diskImagePath: url, directoryName: "GAMES", parentPath: "/", completion: $0) }.ok, "a second /GAMES is refused")
    check(wait { ProDOSWriter.shared.createDirectory(diskImagePath: url, directoryName: "DEEP", parentPath: "/GAMES/", completion: $0) }.ok, "create /GAMES/DEEP")
    check(add(url, "README", rootData).ok, "add /README")
    check(add(url, "README", subData, parent: "/GAMES/").ok, "add /GAMES/README")
    check(add(url, "README", subData, parent: "/GAMES/DEEP/").ok, "add /GAMES/DEEP/README")

    var cat = catalog(url)
    check(find(cat, "/GAMES/README")?.name == "README", "same name in a subdirectory is not auto-renamed")
    check(find(cat, "/GAMES")?.children?.count == 2, "subdirectory lists its two entries and no phantom header entry")
    check(find(cat, "/GAMES/DEEP")?.headerPointer == find(cat, "/GAMES")?.keyPointer, "nested directory's header pointer is its parent's key block")

    // Operations on the subdirectory file must leave the root file alone
    check(wait { ProDOSWriter.shared.setFileType(diskImagePath: url, fileName: "README", parentPath: "/GAMES/", fileType: 0x04, auxType: 0x1234, completion: $0) }.ok, "set type of /GAMES/README")
    check(wait { ProDOSWriter.shared.renameFile(diskImagePath: url, oldName: "README", newName: "NOTES", parentPath: "/GAMES/", completion: $0) }.ok, "rename /GAMES/README")
    cat = catalog(url)
    check(find(cat, "/README")?.fileType == 0x06 && find(cat, "/README")?.data == rootData, "/README is untouched by set-type and rename in /GAMES")
    check(find(cat, "/GAMES/NOTES")?.fileType == 0x04 && find(cat, "/GAMES/NOTES")?.auxType == 0x1234, "/GAMES/NOTES has the new type")
    check(find(cat, "/GAMES/NOTES")?.data == subData, "/GAMES/NOTES kept its data")

    check(wait { ProDOSWriter.shared.deleteFile(diskImagePath: url, fileName: "NOTES", parentPath: "/GAMES/", completion: $0) }.ok, "delete /GAMES/NOTES")
    cat = catalog(url)
    check(find(cat, "/README")?.data == rootData, "/README survives deleting a file in /GAMES")
    check(find(cat, "/GAMES/NOTES") == nil, "/GAMES/NOTES is gone")

    // Renaming a directory keeps its contents reachable and updates its header
    check(wait { ProDOSWriter.shared.renameFile(diskImagePath: url, oldName: "GAMES", newName: "ARCADE", parentPath: "/", completion: $0) }.ok, "rename /GAMES")
    check(add(url, "NEW", bytes(5, seed: 9), parent: "/ARCADE/").ok, "add into the renamed directory")
    cat = catalog(url)
    check(find(cat, "/ARCADE/DEEP/README")?.data == subData, "nested file reachable after directory rename")

    // File counts live in the header of each directory's key block
    let image = try! Data(contentsOf: url)
    let arcadeKey = find(cat, "/ARCADE")!.keyPointer!
    check(Int(image[1024 + 0x25]) == 2, "volume directory counts 2 entries, got \(image[1024 + 0x25])")
    check(Int(image[arcadeKey * 512 + 0x25]) == 2, "/ARCADE counts 2 entries, got \(image[arcadeKey * 512 + 0x25])")
    check(String(decoding: image[(arcadeKey * 512 + 5)..<(arcadeKey * 512 + 11)], as: UTF8.self) == "ARCADE", "directory header carries the new name")

    // Deleting a directory removes everything inside it
    check(wait { ProDOSWriter.shared.deleteFile(diskImagePath: url, fileName: "ARCADE", parentPath: "/", completion: $0) }.ok, "delete /ARCADE")
    check(wait { ProDOSWriter.shared.deleteFile(diskImagePath: url, fileName: "README", parentPath: "/", completion: $0) }.ok, "delete /README")
    check(freeBlockCount(try! Data(contentsOf: url)) == free, "deleting a directory frees its contents")
}

// MARK: - ProDOS: subdirectories grow

do {
    let url = newProDOSImage("grow.po", size: "140KB")
    let free = freeBlockCount(try! Data(contentsOf: url))
    _ = wait { ProDOSWriter.shared.createDirectory(diskImagePath: url, directoryName: "BIG", parentPath: "/", completion: $0) }

    // One block holds 12 entries beside the header; 30 files need three blocks
    for index in 0..<30 {
        check(add(url, "FILE\(index)", bytes(100 + index, seed: UInt8(index)), parent: "/BIG/").ok, "add file \(index) to /BIG")
    }
    _ = wait { ProDOSWriter.shared.createDirectory(diskImagePath: url, directoryName: "INNER", parentPath: "/BIG/", completion: $0) }

    let cat = catalog(url)
    check(find(cat, "/BIG")?.children?.count == 31, "all 31 entries are listed, got \(String(describing: find(cat, "/BIG")?.children?.count))")
    check((0..<30).allSatisfy { find(cat, "/BIG/FILE\($0)")?.data == bytes(100 + $0, seed: UInt8($0)) }, "every file in the grown directory reads back")
    check(find(cat, "/BIG")?.blocks == 3, "the parent entry counts three directory blocks, got \(String(describing: find(cat, "/BIG")?.blocks))")

    let image = try! Data(contentsOf: url)
    let key = find(cat, "/BIG")!.keyPointer!
    check(Int(image[key * 512 + 0x25]) == 31, "the directory header counts 31 entries")

    check(wait { ProDOSWriter.shared.deleteFile(diskImagePath: url, fileName: "BIG", parentPath: "/", completion: $0) }.ok, "delete the grown directory")
    check(freeBlockCount(try! Data(contentsOf: url)) == free, "deleting it frees every directory block")

    // The volume directory does not grow: 51 entries fit in its four blocks
    for index in 0..<51 {
        _ = add(url, "R\(index)", bytes(1, seed: 0))
    }
    check(!add(url, "ONEMORE", bytes(1, seed: 0)).ok, "the 52nd file in the volume directory is refused")
    check(catalog(url)?.entries.count == 51, "the volume directory holds 51 entries")
}

// MARK: - ProDOS: DOS-ordered images

do {
    let po = newProDOSImage("order.po", size: "140KB")
    // Enough files that entries straddle sector boundaries and the first data block (7) is in use
    var expected: [String: Data] = [:]
    for index in 0..<10 {
        let data = bytes(300 + index * 211, seed: UInt8(index))
        expected["FILE\(index)"] = data
        check(add(po, "FILE\(index)", data).ok, "add FILE\(index) to .po")
    }

    let dsk = workDir.appendingPathComponent("order.dsk")
    try! dosOrdered(try! Data(contentsOf: po)).write(to: dsk)

    var cat = catalog(dsk)
    check(cat?.diskFormat == "ProDOS (DSK)", "DOS-ordered image is detected")
    for (name, data) in expected {
        check(find(cat, "/" + name)?.data == data, "\(name) reads back from the DOS-ordered image")
    }

    // The same operations on both images must leave them holding the same volume
    for image in [po, dsk] {
        check(add(image, "EXTRA", bytes(5000, seed: 77)).ok, "add to \(image.lastPathComponent)")
        // Entry 7 of the block starts at byte 238 and crosses the 256-byte sector boundary
        check(wait { ProDOSWriter.shared.setFileType(diskImagePath: image, fileName: "FILE5", parentPath: "/", fileType: 0xB3, auxType: 0xBEEF, completion: $0) }.ok, "set type in \(image.lastPathComponent)")
        check(wait { ProDOSWriter.shared.deleteFile(diskImagePath: image, fileName: "FILE0", parentPath: "/", completion: $0) }.ok, "delete from \(image.lastPathComponent)")
    }
    cat = catalog(dsk)
    check(find(cat, "/FILE5")?.auxType == 0xBEEF && find(cat, "/FILE5")?.fileType == 0xB3, "aux type of the straddling entry is written correctly")
    check(find(cat, "/EXTRA")?.data == bytes(5000, seed: 77), "file added to the DOS-ordered image reads back")
    check(dosOrdered(try! Data(contentsOf: po)) == (try! Data(contentsOf: dsk)), "DOS-ordered image matches the ProDOS-ordered one after identical edits")

    // A ProDOS-ordered image that merely has a .dsk extension
    let mislabelled = workDir.appendingPathComponent("po-order.dsk")
    try! FileManager.default.copyItem(at: po, to: mislabelled)
    check(add(mislabelled, "LATE", bytes(1500, seed: 5)).ok, "add to a ProDOS-ordered .dsk")
    check(find(catalog(mislabelled), "/LATE")?.data == bytes(1500, seed: 5), "file added to a ProDOS-ordered .dsk reads back")
    check(find(catalog(mislabelled), "/FILE3")?.data == expected["FILE3"], "existing files in a ProDOS-ordered .dsk are intact")
}

// MARK: - ProDOS: refuses other images

do {
    let url = workDir.appendingPathComponent("notprodos.po")
    let junk = bytes(143_360, seed: 3)
    try! junk.write(to: url)
    check(!add(url, "X", bytes(10, seed: 1)).ok, "adding to a non-ProDOS image is refused")
    check(!wait { ProDOSWriter.shared.createDirectory(diskImagePath: url, directoryName: "D", parentPath: "/", completion: $0) }.ok, "creating a directory on a non-ProDOS image is refused")
    check((try! Data(contentsOf: url)) == junk, "a non-ProDOS image is left untouched")
}

// MARK: - ProDOS: damaged images do not hang or crash

do {
    let url = newProDOSImage("loop.po", size: "140KB")
    _ = wait { ProDOSWriter.shared.createDirectory(diskImagePath: url, directoryName: "LOOP", parentPath: "/", completion: $0) }
    var image = try! Data(contentsOf: url)
    let key = find(catalog(url), "/LOOP")!.keyPointer!
    // A subdirectory entry inside /LOOP that points back at the volume directory
    let entry = key * 512 + 4 + 39
    image[entry] = 0xD4
    image.replaceSubrange((entry + 1)..<(entry + 5), with: Array("BACK".utf8))
    image[entry + 0x11] = 2
    // ...and a volume directory whose chain loops back on itself
    image[5 * 512 + 2] = 2
    try! image.write(to: url)

    check(catalog(url) != nil, "a volume with directory loops still parses")
    check(!add(url, "MISSING", bytes(10, seed: 1), parent: "/NOPE/").ok, "adding to a missing directory fails cleanly")
    check(wait { ProDOSWriter.shared.deleteFile(diskImagePath: url, fileName: "LOOP", parentPath: "/", completion: $0) }.ok, "deleting a directory that points back at the root finishes")
    check(DiskImageParser.isValidProDOSVolumeHeader((try! Data(contentsOf: url)).subdata(in: 1024..<1536)), "the volume directory survives that delete")

    var header = Data(count: 64)
    header.replaceSubrange(0..<4, with: Array("2IMG".utf8))
    header[8] = 0xFF; header[9] = 0xFF
    check(((try? DiskImageParser.parseProDOS(data: header, diskName: "bad.2mg")) ?? nil) == nil, "a 2MG header pointing past the end of the file is rejected")
}

// MARK: - DOS 3.3

/// A blank DOS 3.3 data disk: VTOC, an empty 15-sector catalog, tracks 0-2 and 17 in use
func blankDOS33() -> Data {
    var disk = Data(count: 143_360)
    let vtoc = 17 * 16 * 256
    disk[vtoc + 1] = 17; disk[vtoc + 2] = 15; disk[vtoc + 3] = 3; disk[vtoc + 6] = 254
    disk[vtoc + 0x27] = 122; disk[vtoc + 0x30] = 18; disk[vtoc + 0x31] = 1
    disk[vtoc + 0x34] = 35; disk[vtoc + 0x35] = 16; disk[vtoc + 0x37] = 1
    for track in 0..<35 where track > 2 && track != 17 {
        disk[vtoc + 0x38 + track * 4] = 0xFF
        disk[vtoc + 0x38 + track * 4 + 1] = 0xFF
    }
    for sector in 2...15 {
        let offset = (17 * 16 + sector) * 256
        disk[offset + 1] = 17
        disk[offset + 2] = UInt8(sector - 1)
    }
    return disk
}

/// Whether the VTOC marks a sector free: byte 0 of a track's entry holds sectors F-8, byte 1 holds 7-0
func isFree(_ disk: Data, track: Int, sector: Int) -> Bool {
    let entry = 17 * 16 * 256 + 0x38 + track * 4
    let word = (Int(disk[entry]) << 8) | Int(disk[entry + 1])
    return word & (1 << sector) != 0
}

/// Every sector used by the files in the catalog: T/S list sectors and data sectors
func sectorsInUse(_ disk: Data) -> Set<Int> {
    var used = Set<Int>()
    var (track, sector) = (17, 15)
    while track != 0 {
        let catalog = (track * 16 + sector) * 256
        for index in 0..<7 {
            let entry = catalog + 0x0B + index * 0x23
            var (listTrack, listSector) = (Int(disk[entry]), Int(disk[entry + 1]))
            if listTrack == 0 || listTrack == 0xFF { continue }
            while listTrack != 0 {
                used.insert(listTrack * 16 + listSector)
                let list = (listTrack * 16 + listSector) * 256
                for pair in 0..<122 where disk[list + 0x0C + pair * 2] != 0 {
                    used.insert(Int(disk[list + 0x0C + pair * 2]) * 16 + Int(disk[list + 0x0D + pair * 2]))
                }
                (listTrack, listSector) = (Int(disk[list + 1]), Int(disk[list + 2]))
            }
        }
        (track, sector) = (Int(disk[catalog + 1]), Int(disk[catalog + 2]))
    }
    return used
}

do {
    let url = workDir.appendingPathComponent("dos33.dsk")
    var blank = blankDOS33()
    // Make track 3 partly used, as on a real disk: sectors 0-11 in use, 12-15 free
    let track3 = 17 * 16 * 256 + 0x38 + 3 * 4
    blank[track3] = 0xF0; blank[track3 + 1] = 0x00
    try! blank.write(to: url)

    // Large enough to need four T/S list sectors
    let big = bytes(95_000, seed: 4), small = bytes(700, seed: 6)
    check(!wait { DOS33Writer.shared.addFile(diskImagePath: url, fileName: "TOO BIG", fileData: big, fileType: 0x06, completion: $0) }.ok, "a binary over 64 KB is refused on DOS 3.3")
    check(wait { DOS33Writer.shared.addFile(diskImagePath: url, fileName: "BIG FILE", fileData: big, fileType: 0x04, completion: $0) }.ok, "add a 95 KB text file to DOS 3.3")
    check(wait { DOS33Writer.shared.addFile(diskImagePath: url, fileName: "SMALL", fileData: small, fileType: 0x06, auxType: 0x2000, completion: $0) }.ok, "add a small binary to DOS 3.3")

    let disk = try! Data(contentsOf: url)
    let used = sectorsInUse(disk)
    check(used.count == (95_000 + 255) / 256 + 4 + 3 + 1, "expected sector count in use, got \(used.count)")
    check(used.allSatisfy { !isFree(disk, track: $0 / 16, sector: $0 % 16) }, "every sector a file uses is marked used in the VTOC")
    check(used.allSatisfy { $0 / 16 != 3 || $0 % 16 >= 12 }, "sectors already in use on track 3 are not handed out again")
    check(used.allSatisfy { $0 / 16 != 0 && $0 / 16 != 17 }, "tracks 0 and 17 are never allocated")
    let freeNow = (0..<35 * 16).filter { isFree(disk, track: $0 / 16, sector: $0 % 16) }.count
    let freeBefore = (0..<35 * 16).filter { isFree(blank, track: $0 / 16, sector: $0 % 16) }.count
    check(freeBefore - freeNow == used.count, "the VTOC marks exactly the sectors in use")

    let cat = (try? DiskImageParser.parseDOS33(data: disk, diskName: "dos33.dsk")) ?? nil
    check(cat?.entries.first { $0.name == "BIG FILE" }?.data == big, "the large file reads back, with its full name")
    let smallEntry = cat?.entries.first { $0.name == "SMALL" }
    check(smallEntry?.data == small, "the binary reads back without its DOS header or sector padding")
    check(smallEntry?.fileType == 0x06 && smallEntry?.auxType == 0x2000, "the binary carries a ProDOS type and its load address")
    let firstEntry = (17 * 16 + 15) * 256 + 0x0B
    let catalogSectors = Int(disk[firstEntry + 0x21]) | (Int(disk[firstEntry + 0x22]) << 8)
    check(catalogSectors == 372 + 4, "the catalog sector count includes T/S list sectors, got \(catalogSectors)")

    // Names are compared in full, so a duplicate is renamed and a clash is refused
    check(wait { DOS33Writer.shared.addFile(diskImagePath: url, fileName: "SMALL", fileData: small, fileType: 0x06, completion: $0) }.ok, "add a second SMALL")
    check(!wait { DOS33Writer.shared.renameFile(diskImagePath: url, oldName: "SMALL.1", newName: "BIG FILE", completion: $0) }.ok, "renaming onto an existing name is refused")
    check(wait { DOS33Writer.shared.renameFile(diskImagePath: url, oldName: "SMALL.1", newName: "OTHER NAME", completion: $0) }.ok, "rename on DOS 3.3")
    let names = ((try? DiskImageParser.parseDOS33(data: try! Data(contentsOf: url), diskName: "dos33.dsk")) ?? nil)?.entries.map { $0.name }.sorted()
    check(names == ["BIG FILE", "OTHER NAME", "SMALL"], "catalog lists the three names, got \(String(describing: names))")
    check(wait { DOS33Writer.shared.deleteFile(diskImagePath: url, fileName: "OTHER NAME", completion: $0) }.ok, "delete the renamed file")

    check(wait { DOS33Writer.shared.deleteFile(diskImagePath: url, fileName: "BIG FILE", completion: $0) }.ok, "delete the large file")
    check(wait { DOS33Writer.shared.deleteFile(diskImagePath: url, fileName: "SMALL", completion: $0) }.ok, "delete the small file")
    let after = try! Data(contentsOf: url)
    let vtoc = 17 * 16 * 256
    check(after[(vtoc + 0x38)..<(vtoc + 0x38 + 35 * 4)] == blank[(vtoc + 0x38)..<(vtoc + 0x38 + 35 * 4)], "the VTOC bitmap is back to its original state after deleting")
}

// MARK: - Archives: truncated input

do {
    // A local file header whose extra field runs past the end of the file
    var zip = Data([0x50, 0x4B, 0x03, 0x04]) + Data(count: 27)
    zip[28] = 0xFF
    let entries = ZipArchive.parseEntries(from: zip)
    check(entries.allSatisfy { ZipArchive.extractEntry($0, from: zip) == nil || true }, "a truncated zip does not crash")
}

// MARK: - View model helpers

/// Runs the main run loop until a condition holds (writer completions arrive there)
func pump(until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(10)
    while !condition() && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
    check(condition(), "timed out waiting for the view model")
}

func makePane(_ url: URL, errors: @escaping (String) -> Void) -> DiskPaneViewModel {
    let pane = DiskPaneViewModel()
    pane.presentError = { title, message in errors(title + ": " + message) }
    pane.confirmAction = { _, _, _ in true }
    pane.loadDiskImage(from: url)
    return pane
}

func select(_ pane: DiskPaneViewModel, _ paths: [String]) {
    pane.selectedEntries = Set(paths.compactMap { find(pane.catalog, $0)?.id })
    check(pane.selectedEntries.count == paths.count, "selected \(paths)")
}

// MARK: - Archives: zip, Binary II and ShrinkIt

func run(_ tool: String, _ arguments: [String], in directory: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try! process.run()
    process.waitUntilExit()
}

func le16(_ value: Int) -> [UInt8] { return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
func le32(_ value: Int) -> [UInt8] { return le16(value & 0xFFFF) + le16((value >> 16) & 0xFFFF) }

do {
    // ditto writes sizes after the data (as Finder does); zip writes them in the local header
    let image = newProDOSImage("zipped.po", size: "140KB")
    _ = add(image, "INSIDE", bytes(4000, seed: 3))
    let original = try! Data(contentsOf: image)
    let dittoZip = workDir.appendingPathComponent("ditto.zip"), infoZip = workDir.appendingPathComponent("info.zip")
    run("/usr/bin/ditto", ["-c", "-k", image.path, dittoZip.path], in: workDir)
    run("/usr/bin/zip", ["-q", infoZip.path, image.lastPathComponent], in: workDir)
    for url in [dittoZip, infoZip] {
        let zip = (try? Data(contentsOf: url)) ?? Data()
        let entry = ZipArchive.parseEntries(from: zip).first { $0.filename.hasSuffix("zipped.po") }
        check(entry != nil && ZipArchive.extractEntry(entry!, from: zip) == original, "\(url.lastPathComponent) extracts the image")
    }
    var errors: [String] = []
    let pane = makePane(dittoZip) { errors.append($0) }
    check(find(pane.catalog, "/INSIDE") != nil && pane.isArchiveBacked && errors.isEmpty, "a Finder-style zip opens in a pane, read-only")
}

do {
    // Binary II: 128-byte header per file, 3-byte length at +20, name length at +23
    func header(_ name: String, type: UInt8, length: Int, filesToFollow: UInt8) -> Data {
        var h = Data(count: 128)
        h.replaceSubrange(0..<3, with: [0x0A, 0x47, 0x4C])
        h[3] = 0xE3; h[4] = type; h[5] = 0x00; h[6] = 0x20; h[7] = 1
        h[18] = 0x02
        h.replaceSubrange(20..<23, with: le32(length).prefix(3))
        h[23] = UInt8(name.utf8.count)
        h.replaceSubrange(24..<(24 + name.utf8.count), with: Array(name.utf8))
        h[127] = filesToFollow
        return h
    }
    let first = bytes(512, seed: 1), second = bytes(300, seed: 2)
    var archive = header("HELLO", type: 0x06, length: first.count, filesToFollow: 1) + first
    archive += header("DOCS/READ.ME", type: 0x04, length: second.count, filesToFollow: 0) + second + Data(count: 384 - 300)
    let parsed = BinaryIIArchive(data: archive)
    try! parsed.parse()
    check(parsed.entries.map { $0.filename } == ["HELLO", "DOCS/READ.ME"], "Binary II names, got \(parsed.entries.map { $0.filename })")
    check(parsed.entries.count == 2 && parsed.extractData(for: parsed.entries[1]) == second, "Binary II second file extracts")

    let url = workDir.appendingPathComponent("files.bny")
    try! archive.write(to: url)
    var errors: [String] = []
    let pane = makePane(url) { errors.append($0) }
    check(find(pane.catalog, "/HELLO")?.data == first && find(pane.catalog, "/DOCS/READ.ME")?.fileType == 0x04, "a Binary II file archive opens as a catalog with directories")
    check(pane.isArchiveBacked && errors.isEmpty, "the archive catalog is read-only")
}

do {
    // A minimal ShrinkIt archive: one version 3 record with a filename thread and a stored data thread
    let content = bytes(1000, seed: 7)
    let name = Array("DIR:FILE".utf8)
    var record = Data([0x4E, 0xF5, 0x46, 0xD8]) + Data(le16(0)) + Data(le16(60)) + Data(le16(3)) + Data(le32(2))
    record += Data(le16(1)) + Data([UInt8(ascii: ":"), 0]) + Data(le32(0xE3)) + Data(le32(0x04)) + Data(le32(0x1234)) + Data(le16(1))
    record += Data(count: 24) + Data(le16(0)) + Data(le16(0))  // dates, option size, filename length
    check(record.count == 60, "record header is 60 bytes, got \(record.count)")
    record += Data(le16(3)) + Data(le16(0)) + Data(le16(0)) + Data(le16(0)) + Data(le32(name.count)) + Data(le32(32))
    record += Data(le16(2)) + Data(le16(0)) + Data(le16(0)) + Data(le16(Int(NuFXCRC.crc16(content, initialValue: 0xFFFF)))) + Data(le32(content.count)) + Data(le32(content.count))
    record += Data(name) + Data(count: 32 - name.count) + content
    var archive = Data([0x4E, 0xF5, 0x46, 0xE9, 0x6C, 0xE5]) + Data(le16(0)) + Data(le32(1)) + Data(count: 36)
    check(archive.count == 48, "master header is 48 bytes")
    archive += record

    let parsed = NuFXArchive(data: archive)
    try! parsed.parse()
    check(parsed.records.first?.filename == "DIR:FILE", "ShrinkIt record name, got \(String(describing: parsed.records.first?.filename))")
    check((try? parsed.extractData(for: parsed.records[0])) == content, "ShrinkIt stored thread extracts")

    var damaged = archive
    damaged[damaged.count - 1] ^= 0xFF
    let bad = NuFXArchive(data: damaged)
    try! bad.parse()
    check((try? bad.extractData(for: bad.records[0])) == nil, "a thread that fails its CRC is rejected")
    check((try? NuFXArchive(data: archive.prefix(200)).parse()) != nil, "a truncated archive does not crash")

    let url = workDir.appendingPathComponent("files.shk")
    try! archive.write(to: url)
    var errors: [String] = []
    let pane = makePane(url) { errors.append($0) }
    check(find(pane.catalog, "/DIR/FILE")?.data == content && find(pane.catalog, "/DIR/FILE")?.auxType == 0x1234, "a ShrinkIt file archive opens as a catalog")
    check(pane.isArchiveBacked && errors.isEmpty, "the ShrinkIt catalog is read-only, errors \(errors)")

    // Files can be copied out of an archive onto a disk image
    let diskURL = newProDOSImage("from-archive.po", size: "140KB")
    let disk = makePane(diskURL) { errors.append($0) }
    select(pane, ["/DIR"])
    pane.copySelected()
    disk.pasteClipboard()
    pump { !FocusManager.shared.hasClipboard() }
    check(find(catalog(diskURL), "/DIR/FILE")?.data == content, "a directory copied from an archive lands on the disk")
}

// MARK: - View model: copy, cut, paste and delete between panes

do {
    var errors: [String] = []
    let sourceURL = newProDOSImage("vm-source.po", size: "140KB")
    let targetURL = newProDOSImage("vm-target.po", size: "140KB")
    let small = bytes(500, seed: 1), large = bytes(20_000, seed: 2), other = bytes(900, seed: 3)

    _ = wait { ProDOSWriter.shared.createDirectory(diskImagePath: sourceURL, directoryName: "GAMES", parentPath: "/", completion: $0) }
    _ = add(sourceURL, "SMALL", small)
    _ = add(sourceURL, "LARGE", large)
    _ = add(sourceURL, "README", other)
    _ = add(sourceURL, "README", small, parent: "/GAMES/")
    _ = add(sourceURL, "EXTRA", other, parent: "/GAMES/")
    // Leave room on the target for SMALL but not for LARGE
    let targetFree = freeBlockCount(try! Data(contentsOf: targetURL))
    _ = add(targetURL, "FILLER", bytes((targetFree - 12) * 512, seed: 9))

    let source = makePane(sourceURL) { errors.append($0) }
    let target = makePane(targetURL) { errors.append($0) }
    check(source.catalog != nil && target.catalog != nil, "both panes load")

    // Cut two files and paste into the other pane: only the one that fits may leave the source
    select(source, ["/SMALL", "/LARGE"])
    source.cutSelected()
    target.pasteClipboard()
    pump { !FocusManager.shared.hasClipboard() }
    check(find(catalog(targetURL), "/SMALL")?.data == small, "the file that fits arrives on the target")
    check(find(catalog(targetURL), "/LARGE") == nil, "the file that does not fit is not on the target")
    check(find(catalog(sourceURL), "/LARGE")?.data == large, "the file that could not be copied stays on the source")
    check(find(catalog(sourceURL), "/SMALL") == nil, "the file that was copied is removed from the source")
    check(errors.count == 1 && errors[0].contains("LARGE"), "the failure is reported once, got \(errors)")
    check(find(source.catalog, "/SMALL") == nil && find(target.catalog, "/SMALL") != nil, "both panes show the result")
    errors = []

    // Deleting a file inside a directory leaves the same-named file in the root alone
    select(source, ["/GAMES/README"])
    source.deleteSelected()
    pump { find(source.catalog, "/GAMES/README") == nil }
    check(find(catalog(sourceURL), "/README")?.data == other, "/README survives deleting /GAMES/README")
    check(find(catalog(sourceURL), "/GAMES/EXTRA") != nil, "the rest of /GAMES is intact")

    // A directory selected together with its contents is deleted once, without errors
    select(source, ["/GAMES", "/GAMES/EXTRA", "/LARGE"])
    source.deleteSelected()
    pump { find(source.catalog, "/GAMES") == nil && find(source.catalog, "/LARGE") == nil }
    check(catalog(sourceURL)?.allEntries.map { $0.name } == ["README"], "only /README is left")
    check(errors.isEmpty, "no errors from deleting a directory with its contents, got \(errors)")

    // Copy into the directory the target pane is showing
    _ = wait { ProDOSWriter.shared.deleteFile(diskImagePath: targetURL, fileName: "FILLER", parentPath: "/", completion: $0) }
    _ = wait { ProDOSWriter.shared.createDirectory(diskImagePath: targetURL, directoryName: "INBOX", parentPath: "/", completion: $0) }
    target.loadDiskImage(from: targetURL)
    target.navigateInto(find(target.catalog, "/INBOX")!)
    select(source, ["/README"])
    source.copySelected()
    target.pasteClipboard()
    pump { !FocusManager.shared.hasClipboard() }
    check(find(catalog(targetURL), "/INBOX/README")?.data == other, "paste lands in the directory being viewed")
    check(find(catalog(sourceURL), "/README") != nil, "copy leaves the source file in place")
    check(target.currentDirectoryPath == "/INBOX/", "the pane stays in its directory after the reload")

    // A file that cannot be parsed must not replace the loaded disk
    let junkURL = workDir.appendingPathComponent("junk.po")
    try! bytes(4096, seed: 8).write(to: junkURL)
    errors = []
    target.loadDiskImage(from: junkURL)
    check(target.diskImagePath == targetURL && target.catalog?.diskName == "TEST", "a failed load keeps the previous disk and path")
    check(errors.count == 1, "a failed load is reported")

    // An image inside an archive is read-only
    let gzURL = workDir.appendingPathComponent("packed.po.gz")
    let gzip = Process()
    gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    gzip.arguments = ["-c", sourceURL.path]
    let pipe = Pipe()
    gzip.standardOutput = pipe
    try! gzip.run()
    let packed = pipe.fileHandleForReading.readDataToEndOfFile()
    gzip.waitUntilExit()
    try! packed.write(to: gzURL)
    errors = []
    let archivePane = makePane(gzURL) { errors.append($0) }
    check(archivePane.catalog != nil && archivePane.isArchiveBacked, "a gzipped image opens as archive-backed")
    archivePane.importRawData(small, filename: "NEW", fileType: 0x06, auxType: 0)
    select(archivePane, ["/README"])
    archivePane.deleteSelected()
    check(errors.count == 2, "writes to an archive-backed image are refused, got \(errors)")
    check((try! Data(contentsOf: gzURL)) == packed, "the archive file is untouched")
}

// MARK: - View model: importing from the Mac, selection ranges, delete confirmation

do {
    var errors: [String] = []
    let url = newProDOSImage("vm-import.po", size: "140KB")
    _ = wait { ProDOSWriter.shared.createDirectory(diskImagePath: url, directoryName: "SRC", parentPath: "/", completion: $0) }
    _ = add(url, "INNER", bytes(10, seed: 1), parent: "/SRC/")
    let pane = makePane(url) { errors.append($0) }

    // Several files dropped at once are all imported, typed by extension
    var macFiles: [URL] = []
    for (name, size) in [("notes.txt", 300), ("game.bin", 2000), ("main.s", 500)] {
        let file = workDir.appendingPathComponent(name)
        try! bytes(size, seed: 4).write(to: file)
        macFiles.append(file)
    }
    pane.importFiles(from: macFiles + [workDir.appendingPathComponent("missing.dat")])
    pump { find(pane.catalog, "/MAIN.S") != nil }
    check(find(pane.catalog, "/NOTES.TXT")?.fileType == 0x04 && find(pane.catalog, "/GAME.BIN")?.fileType == 0x06 && find(pane.catalog, "/MAIN.S")?.fileType == 0x04,
          "three dropped files are imported with types from their extensions")
    check(find(pane.catalog, "/GAME.BIN")?.data == bytes(2000, seed: 4), "an imported file keeps its contents")
    check(errors.count == 1 && errors[0].contains("missing.dat"), "the unreadable file is reported, got \(errors)")

    // Shift-click selects within one directory and never reaches into a folder
    pane.selectedEntries = []
    pane.toggleSelection(find(pane.catalog, "/SRC")!)
    pane.toggleSelection(find(pane.catalog, "/MAIN.S")!, shiftPressed: true)
    let selectedPaths = Set(pane.getSelectedEntries().map { $0.parentPath + $0.name })
    check(selectedPaths.contains("/GAME.BIN") && !selectedPaths.contains("/SRC/INNER"), "a shift-click range stays in its directory, got \(selectedPaths.sorted())")

    // Declining the confirmation deletes nothing
    pane.confirmAction = { _, _, _ in false }
    pane.deleteSelected()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    check(catalog(url)?.allEntries.count == 5, "declining the confirmation deletes nothing")
}

// MARK: - View model: moving files from DOS 3.3 to ProDOS

do {
    var errors: [String] = []
    let dosURL = workDir.appendingPathComponent("vm-dos33.dsk")
    try! blankDOS33().write(to: dosURL)
    let proURL = newProDOSImage("vm-prodos.po", size: "140KB")
    for name in ["ONE", "TWO", "THREE"] {
        _ = wait { DOS33Writer.shared.addFile(diskImagePath: dosURL, fileName: name, fileData: bytes(600, seed: 3), fileType: 0x06, completion: $0) }
    }
    let dos = makePane(dosURL) { errors.append($0) }
    let pro = makePane(proURL) { errors.append($0) }
    check(dos.isDOS33 && !pro.isDOS33, "formats detected")

    select(dos, ["/ONE", "/TWO", "/THREE"])
    dos.cutSelected()
    pro.pasteClipboard()
    pump { !FocusManager.shared.hasClipboard() }
    check(catalog(proURL)?.entries.map { $0.name }.sorted() == ["ONE", "THREE", "TWO"], "all three files arrive on the ProDOS disk")
    let left = ((try? DiskImageParser.parseDOS33(data: try! Data(contentsOf: dosURL), diskName: "d")) ?? nil)?.entries.count ?? 0
    check(left == 0, "all three files are removed from the DOS 3.3 disk, \(left) left")
    check(errors.isEmpty, "no errors moving from DOS 3.3 to ProDOS, got \(errors)")

    // Directories cannot be created on DOS 3.3
    dos.loadDiskImage(from: dosURL)
    pro.loadDiskImage(from: proURL)
    let before = try! Data(contentsOf: dosURL)
    dos.showCreateDirectoryDialog()
    check(errors.count == 1 && (try! Data(contentsOf: dosURL)) == before, "New Folder is refused on a DOS 3.3 disk")
}

print("\(checkCount - failureCount) of \(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
