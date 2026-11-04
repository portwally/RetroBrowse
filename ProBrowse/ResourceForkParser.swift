//
//  ResourceForkParser.swift
//  ProBrowse
//
//  Lists the resources in an Apple IIgs resource fork (Apple IIgs Toolbox Reference,
//  volume 3, Resource Manager): the map at rFileToMap holds 20-byte reference records
//  giving each resource's type, ID, offset and size.
//

import Foundation

struct IIgsResource: Identifiable, Equatable {
    let type: UInt16
    let resourceID: UInt32
    let attributes: UInt16
    /// The resource's bytes
    let data: Data

    var id: String { String(format: "%04X-%08X", type, resourceID) }

    /// The Toolbox name of the type, e.g. "rIcon", or nil for an application's own type
    var typeName: String? { ResourceForkParser.typeNames[type] }
}

enum ResourceForkParser {

    /// The resources in a fork, in map order; nil if it has no valid resource map
    static func parse(_ fork: Data) -> [IIgsResource]? {
        let bytes = [UInt8](fork)
        func word(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func dword(_ at: Int) -> Int { word(at) | word(at + 2) << 16 }

        // Header: rFileVersion (0), rFileToMap, rFileMapSize
        guard bytes.count >= 12, dword(0) == 0 else { return nil }
        let mapOffset = dword(4), mapSize = dword(8)
        guard mapOffset >= 12, mapSize >= 0x20, mapOffset + mapSize <= bytes.count else { return nil }

        // Map: mapToIndex at +$0E, mapIndexUsed at +$18
        let indexOffset = mapOffset + word(mapOffset + 0x0E)
        let used = dword(mapOffset + 0x18)
        let mapEnd = mapOffset + mapSize
        guard indexOffset >= mapOffset + 0x20 else { return nil }

        // Records: resType, resID, resOffset, resAttr, resSize, resHandle; type 0 is unused
        var resources: [IIgsResource] = []
        var record = indexOffset
        while resources.count < used && record + 20 <= mapEnd {
            let type = UInt16(word(record))
            if type != 0 {
                let offset = dword(record + 6), size = dword(record + 0x0C)
                guard offset >= 0, size >= 0, offset + size <= bytes.count else { return nil }
                resources.append(IIgsResource(type: type, resourceID: UInt32(dword(record + 2)),
                                              attributes: UInt16(word(record + 0x0A)),
                                              data: Data(bytes[offset..<offset + size])))
            }
            record += 20
        }
        return resources
    }

    /// Resource types defined by Apple
    static let typeNames: [UInt16: String] = [
        0x8001: "rIcon", 0x8002: "rPicture", 0x8003: "rControlList", 0x8004: "rControlTemplate",
        0x8005: "rC1InputString", 0x8006: "rPString", 0x8007: "rStringList", 0x8008: "rMenuBar",
        0x8009: "rMenu", 0x800A: "rMenuItem", 0x800B: "rTextForLETextBox2", 0x800C: "rCtlDefProc",
        0x800D: "rCtlColorTbl", 0x800E: "rWindParam1", 0x800F: "rWindParam2", 0x8010: "rWindColor",
        0x8011: "rTextBlock", 0x8012: "rStyleBlock", 0x8013: "rToolStartup", 0x8014: "rResName",
        0x8015: "rAlertString", 0x8016: "rText", 0x8017: "rCodeResource", 0x8018: "rCDEVCode",
        0x8019: "rCDEVFlags", 0x801A: "rTwoRects", 0x801B: "rFileType", 0x801C: "rListRef",
        0x801D: "rCString", 0x801E: "rXCMD", 0x801F: "rXFCN", 0x8020: "rErrorString",
        0x8021: "rKTransTable", 0x8022: "rWString", 0x8023: "rC1OutputString", 0x8024: "rSoundSample",
        0x8025: "rTERuler", 0x8026: "rFSequence", 0x8027: "rCursor", 0x8028: "rItemStruct",
        0x8029: "rVersion", 0x802A: "rComment", 0x802B: "rBundle", 0x802C: "rFinderPath",
        0x802D: "rPaletteWindow", 0x802E: "rTaggedStrings", 0x802F: "rPatternList",
        0xC001: "rRectList", 0xC002: "rPrintRecord", 0xC003: "rFont",
    ]
}
