//
//  InspectorSupport.swift
//  ProBrowse
//
//  Which file types the inspector can show as more than a hex dump. Mirrors the choices in
//  FileContentView.detectContentType, AppleIIGraphicsDecoder.detectAndDecode and
//  AppleIIgsSoundDecoder; used by the File Types table in Help.
//

import Foundation

enum InspectorSupport {

    /// What the inspector shows for this type, or nil when only Hex and Info are available.
    /// `auxType` nil means the file type in general (any aux type).
    static func viewer(fileType: UInt8, auxType: UInt16?) -> String? {
        switch fileType {
        case 0x04: return "Text, or Merlin source"
        case 0xB0: return "Text"
        case 0xFC: return "Applesoft BASIC listing"
        case 0xFA: return "Integer BASIC listing"
        case 0x19, 0x1A, 0x1B: return "AppleWorks"
        case 0x50:
            switch auxType {
            case 0x8010: return "AppleWorks GS"
            case 0x5445: return "Teach document"
            default: return nil
            }
        case 0x06: return "6502 disassembly, or graphics by size"
        case 0xFF, 0xFE: return "6502 disassembly"
        case 0xB3: return "65816 disassembly, or Super Hi-Res"
        case 0xB5, 0xBC: return "65816 disassembly"
        case 0x0F: return "Folder"

        // Graphics
        case 0x08:
            switch auxType {
            case nil, 0x0000, 0x4000, 0x4001: return "Hi-Res / Double Hi-Res"
            default: return nil
            }
        case 0xC0:
            switch auxType {
            case nil, 0x0000, 0x0001, 0x0002, 0x0003: return "Packed Super Hi-Res"
            case 0x8005: return "DreamGrafix (packed)"
            default: return nil
            }
        case 0xC1:
            switch auxType {
            case nil, 0x0000: return "Super Hi-Res"
            case 0x0002: return "3200-colour Super Hi-Res"
            case 0x8003: return "DreamGrafix"
            default: return nil
            }
        case 0xC2: return "PaintWorks animation (first frame)"
        case 0x07: return "Hi-res screen font"
        case 0xC8: return "Apple IIgs font"
        case 0xCA: return "Finder icons"

        // Sound and music
        case 0xD7: return "Standard MIDI file"
        case 0xD8:
            switch auxType {
            case 0x0000, 0x0001: return "AIFF / AIFF-C"
            case 0x0002: return "ASIF instrument"
            case 0x0003: return "Sound resources (rSound)"
            case 0x8001: return "HyperStudio sound"
            default: return nil
            }
        case 0xD5:
            switch auxType {
            case 0x0007: return "SoundSmith song"
            case 0x0008: return "NinjaTracker Plus song"
            default: return nil
            }

        default: return nil
        }
    }
}
