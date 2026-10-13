//
//  Disassembler6502.swift
//  ProBrowse
//
//  6502 Disassembler for Apple II machine code
//  Based on MOS 6502 instruction set
//

import SwiftUI

// MARK: - 6502 Addressing Modes

enum AddressMode6502 {
    case implied        // No operand (e.g., NOP, RTS)
    case accumulator    // Operates on A register (e.g., ASL A)
    case immediate      // #$nn - 8-bit immediate value
    case zeroPage       // $nn - Zero page address
    case zeroPageX      // $nn,X - Zero page indexed by X
    case zeroPageY      // $nn,Y - Zero page indexed by Y
    case absolute       // $nnnn - 16-bit absolute address
    case absoluteX      // $nnnn,X - Absolute indexed by X
    case absoluteY      // $nnnn,Y - Absolute indexed by Y
    case indirect       // ($nnnn) - Indirect (JMP only)
    case indexedIndirect // ($nn,X) - Indexed indirect
    case indirectIndexed // ($nn),Y - Indirect indexed
    case relative       // Branch offset (signed 8-bit)
    case invalid        // Invalid/undocumented opcode
}

// MARK: - 6502 Opcode Definition

struct Opcode6502 {
    let mnemonic: String
    let mode: AddressMode6502
    let bytes: Int
    let cycles: Int

    init(_ mnemonic: String, _ mode: AddressMode6502, _ bytes: Int, _ cycles: Int) {
        self.mnemonic = mnemonic
        self.mode = mode
        self.bytes = bytes
        self.cycles = cycles
    }
}

// MARK: - Disassembled Instruction

struct DisassembledInstruction {
    let address: UInt16
    let bytes: [UInt8]
    let mnemonic: String
    let operand: String
    let comment: String?

    var bytesString: String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    var fullInstruction: String {
        if operand.isEmpty {
            return mnemonic
        }
        return "\(mnemonic) \(operand)"
    }
}

// MARK: - 6502 Disassembler

class Disassembler6502 {

    // Complete 6502 opcode table (256 entries)
    static let opcodes: [Opcode6502] = [
        // $00-$0F
        Opcode6502("BRK", .implied, 1, 7),
        Opcode6502("ORA", .indexedIndirect, 2, 6),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("ORA", .zeroPage, 2, 3),
        Opcode6502("ASL", .zeroPage, 2, 5),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("PHP", .implied, 1, 3),
        Opcode6502("ORA", .immediate, 2, 2),
        Opcode6502("ASL", .accumulator, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("ORA", .absolute, 3, 4),
        Opcode6502("ASL", .absolute, 3, 6),
        Opcode6502("???", .invalid, 1, 2),

        // $10-$1F
        Opcode6502("BPL", .relative, 2, 2),
        Opcode6502("ORA", .indirectIndexed, 2, 5),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("ORA", .zeroPageX, 2, 4),
        Opcode6502("ASL", .zeroPageX, 2, 6),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("CLC", .implied, 1, 2),
        Opcode6502("ORA", .absoluteY, 3, 4),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("ORA", .absoluteX, 3, 4),
        Opcode6502("ASL", .absoluteX, 3, 7),
        Opcode6502("???", .invalid, 1, 2),

        // $20-$2F
        Opcode6502("JSR", .absolute, 3, 6),
        Opcode6502("AND", .indexedIndirect, 2, 6),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("BIT", .zeroPage, 2, 3),
        Opcode6502("AND", .zeroPage, 2, 3),
        Opcode6502("ROL", .zeroPage, 2, 5),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("PLP", .implied, 1, 4),
        Opcode6502("AND", .immediate, 2, 2),
        Opcode6502("ROL", .accumulator, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("BIT", .absolute, 3, 4),
        Opcode6502("AND", .absolute, 3, 4),
        Opcode6502("ROL", .absolute, 3, 6),
        Opcode6502("???", .invalid, 1, 2),

        // $30-$3F
        Opcode6502("BMI", .relative, 2, 2),
        Opcode6502("AND", .indirectIndexed, 2, 5),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("AND", .zeroPageX, 2, 4),
        Opcode6502("ROL", .zeroPageX, 2, 6),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("SEC", .implied, 1, 2),
        Opcode6502("AND", .absoluteY, 3, 4),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("AND", .absoluteX, 3, 4),
        Opcode6502("ROL", .absoluteX, 3, 7),
        Opcode6502("???", .invalid, 1, 2),

        // $40-$4F
        Opcode6502("RTI", .implied, 1, 6),
        Opcode6502("EOR", .indexedIndirect, 2, 6),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("EOR", .zeroPage, 2, 3),
        Opcode6502("LSR", .zeroPage, 2, 5),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("PHA", .implied, 1, 3),
        Opcode6502("EOR", .immediate, 2, 2),
        Opcode6502("LSR", .accumulator, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("JMP", .absolute, 3, 3),
        Opcode6502("EOR", .absolute, 3, 4),
        Opcode6502("LSR", .absolute, 3, 6),
        Opcode6502("???", .invalid, 1, 2),

        // $50-$5F
        Opcode6502("BVC", .relative, 2, 2),
        Opcode6502("EOR", .indirectIndexed, 2, 5),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("EOR", .zeroPageX, 2, 4),
        Opcode6502("LSR", .zeroPageX, 2, 6),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("CLI", .implied, 1, 2),
        Opcode6502("EOR", .absoluteY, 3, 4),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("EOR", .absoluteX, 3, 4),
        Opcode6502("LSR", .absoluteX, 3, 7),
        Opcode6502("???", .invalid, 1, 2),

        // $60-$6F
        Opcode6502("RTS", .implied, 1, 6),
        Opcode6502("ADC", .indexedIndirect, 2, 6),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("ADC", .zeroPage, 2, 3),
        Opcode6502("ROR", .zeroPage, 2, 5),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("PLA", .implied, 1, 4),
        Opcode6502("ADC", .immediate, 2, 2),
        Opcode6502("ROR", .accumulator, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("JMP", .indirect, 3, 5),
        Opcode6502("ADC", .absolute, 3, 4),
        Opcode6502("ROR", .absolute, 3, 6),
        Opcode6502("???", .invalid, 1, 2),

        // $70-$7F
        Opcode6502("BVS", .relative, 2, 2),
        Opcode6502("ADC", .indirectIndexed, 2, 5),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("ADC", .zeroPageX, 2, 4),
        Opcode6502("ROR", .zeroPageX, 2, 6),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("SEI", .implied, 1, 2),
        Opcode6502("ADC", .absoluteY, 3, 4),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("ADC", .absoluteX, 3, 4),
        Opcode6502("ROR", .absoluteX, 3, 7),
        Opcode6502("???", .invalid, 1, 2),

        // $80-$8F
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("STA", .indexedIndirect, 2, 6),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("STY", .zeroPage, 2, 3),
        Opcode6502("STA", .zeroPage, 2, 3),
        Opcode6502("STX", .zeroPage, 2, 3),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("DEY", .implied, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("TXA", .implied, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("STY", .absolute, 3, 4),
        Opcode6502("STA", .absolute, 3, 4),
        Opcode6502("STX", .absolute, 3, 4),
        Opcode6502("???", .invalid, 1, 2),

        // $90-$9F
        Opcode6502("BCC", .relative, 2, 2),
        Opcode6502("STA", .indirectIndexed, 2, 6),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("STY", .zeroPageX, 2, 4),
        Opcode6502("STA", .zeroPageX, 2, 4),
        Opcode6502("STX", .zeroPageY, 2, 4),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("TYA", .implied, 1, 2),
        Opcode6502("STA", .absoluteY, 3, 5),
        Opcode6502("TXS", .implied, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("STA", .absoluteX, 3, 5),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),

        // $A0-$AF
        Opcode6502("LDY", .immediate, 2, 2),
        Opcode6502("LDA", .indexedIndirect, 2, 6),
        Opcode6502("LDX", .immediate, 2, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("LDY", .zeroPage, 2, 3),
        Opcode6502("LDA", .zeroPage, 2, 3),
        Opcode6502("LDX", .zeroPage, 2, 3),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("TAY", .implied, 1, 2),
        Opcode6502("LDA", .immediate, 2, 2),
        Opcode6502("TAX", .implied, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("LDY", .absolute, 3, 4),
        Opcode6502("LDA", .absolute, 3, 4),
        Opcode6502("LDX", .absolute, 3, 4),
        Opcode6502("???", .invalid, 1, 2),

        // $B0-$BF
        Opcode6502("BCS", .relative, 2, 2),
        Opcode6502("LDA", .indirectIndexed, 2, 5),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("LDY", .zeroPageX, 2, 4),
        Opcode6502("LDA", .zeroPageX, 2, 4),
        Opcode6502("LDX", .zeroPageY, 2, 4),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("CLV", .implied, 1, 2),
        Opcode6502("LDA", .absoluteY, 3, 4),
        Opcode6502("TSX", .implied, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("LDY", .absoluteX, 3, 4),
        Opcode6502("LDA", .absoluteX, 3, 4),
        Opcode6502("LDX", .absoluteY, 3, 4),
        Opcode6502("???", .invalid, 1, 2),

        // $C0-$CF
        Opcode6502("CPY", .immediate, 2, 2),
        Opcode6502("CMP", .indexedIndirect, 2, 6),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("CPY", .zeroPage, 2, 3),
        Opcode6502("CMP", .zeroPage, 2, 3),
        Opcode6502("DEC", .zeroPage, 2, 5),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("INY", .implied, 1, 2),
        Opcode6502("CMP", .immediate, 2, 2),
        Opcode6502("DEX", .implied, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("CPY", .absolute, 3, 4),
        Opcode6502("CMP", .absolute, 3, 4),
        Opcode6502("DEC", .absolute, 3, 6),
        Opcode6502("???", .invalid, 1, 2),

        // $D0-$DF
        Opcode6502("BNE", .relative, 2, 2),
        Opcode6502("CMP", .indirectIndexed, 2, 5),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("CMP", .zeroPageX, 2, 4),
        Opcode6502("DEC", .zeroPageX, 2, 6),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("CLD", .implied, 1, 2),
        Opcode6502("CMP", .absoluteY, 3, 4),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("CMP", .absoluteX, 3, 4),
        Opcode6502("DEC", .absoluteX, 3, 7),
        Opcode6502("???", .invalid, 1, 2),

        // $E0-$EF
        Opcode6502("CPX", .immediate, 2, 2),
        Opcode6502("SBC", .indexedIndirect, 2, 6),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("CPX", .zeroPage, 2, 3),
        Opcode6502("SBC", .zeroPage, 2, 3),
        Opcode6502("INC", .zeroPage, 2, 5),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("INX", .implied, 1, 2),
        Opcode6502("SBC", .immediate, 2, 2),
        Opcode6502("NOP", .implied, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("CPX", .absolute, 3, 4),
        Opcode6502("SBC", .absolute, 3, 4),
        Opcode6502("INC", .absolute, 3, 6),
        Opcode6502("???", .invalid, 1, 2),

        // $F0-$FF
        Opcode6502("BEQ", .relative, 2, 2),
        Opcode6502("SBC", .indirectIndexed, 2, 5),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("SBC", .zeroPageX, 2, 4),
        Opcode6502("INC", .zeroPageX, 2, 6),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("SED", .implied, 1, 2),
        Opcode6502("SBC", .absoluteY, 3, 4),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("???", .invalid, 1, 2),
        Opcode6502("SBC", .absoluteX, 3, 4),
        Opcode6502("INC", .absoluteX, 3, 7),
        Opcode6502("???", .invalid, 1, 2),
    ]

    // Common Apple II addresses for comments
    static let knownAddresses: [UInt16: String] = [
        // Zero Page
        0x0020: "WNDLFT",
        0x0021: "WNDWDTH",
        0x0022: "WNDTOP",
        0x0023: "WNDBTM",
        0x0024: "CH",
        0x0025: "CV",
        0x0026: "GBASL",
        0x0027: "GBASH",
        0x0028: "BASL",
        0x0029: "BASH",
        0x002B: "BOOTSLOT",
        0x0030: "COLOR",
        0x0033: "PROMPT",
        0x0036: "CSWL",
        0x0037: "CSWH",
        0x0038: "KSWL",
        0x0039: "KSWH",

        // I/O Soft Switches
        0xC000: "KBD",
        0xC010: "KBDSTRB",
        0xC020: "TAPEOUT",
        0xC030: "SPKR",
        0xC050: "TXTCLR",
        0xC051: "TXTSET",
        0xC052: "MIXCLR",
        0xC053: "MIXSET",
        0xC054: "LOWSCR",
        0xC055: "HISCR",
        0xC056: "LORES",
        0xC057: "HIRES",

        // Monitor ROM
        0xF800: "PLOT",
        0xF819: "HLINE",
        0xF828: "VLINE",
        0xF832: "CLRSCR",
        0xF836: "CLRTOP",
        0xF847: "GBASCALC",
        0xF864: "SETCOL",
        0xF871: "SCRN",
        0xF940: "PRNTYX",
        0xF941: "PRNTAX",
        0xF948: "PRBLNK",
        0xFAD7: "REGDSP",
        0xFB1E: "PREAD",
        0xFB2F: "INIT",
        0xFB39: "SETTXT",
        0xFB40: "SETGR",
        0xFB4B: "SETWND",
        0xFBC1: "BASCALC",
        0xFBDD: "BELL1",
        0xFC10: "BS",
        0xFC1A: "UP",
        0xFC22: "VTAB",
        0xFC42: "CLREOP",
        0xFC58: "HOME",
        0xFC62: "CR",
        0xFC66: "LF",
        0xFC70: "SCROLL",
        0xFC9C: "CLREOL",
        0xFCA8: "WAIT",
        0xFD0C: "RDKEY",
        0xFD1B: "KEYIN",
        0xFD35: "RDCHAR",
        0xFD67: "GETLNZ",
        0xFD6A: "GETLN",
        0xFD6F: "GETLN1",
        0xFD8B: "CROUT1",
        0xFD8E: "CROUT",
        0xFDDA: "PRBYTE",
        0xFDE3: "PRHEX",
        0xFDED: "COUT",
        0xFDF0: "COUT1",
        0xFE2C: "MOVE",
        0xFE80: "SETINV",
        0xFE84: "SETNORM",
        0xFE89: "SETKBD",
        0xFE93: "SETVID",
        0xFECD: "WRITE",
        0xFEFD: "READ",
        0xFF2D: "PRERR",
        0xFF3A: "BELL",
        0xFF3F: "IOREST",
        0xFF4A: "IOSAVE",
        0xFF65: "MON",
        0xFF69: "MONZ",

        // ProDOS MLI
        0xBF00: "MLI",
    ]

    /// Disassemble binary data starting at a given address
    /// - Parameters:
    ///   - data: Binary data to disassemble
    ///   - startAddress: Starting address for the code
    ///   - maxInstructions: Maximum number of instructions to disassemble
    /// - Returns: Array of disassembled instructions
    static func disassemble(data: Data, startAddress: UInt16, maxInstructions: Int = 1000) -> [DisassembledInstruction] {
        var instructions: [DisassembledInstruction] = []
        var offset = 0
        var address = startAddress

        while offset < data.count && instructions.count < maxInstructions {
            let opcodeByte = data[offset]
            let opcode = opcodes[Int(opcodeByte)]

            // Collect bytes for this instruction
            var bytes: [UInt8] = [opcodeByte]
            let bytesNeeded = min(opcode.bytes, data.count - offset)

            for i in 1..<bytesNeeded {
                bytes.append(data[offset + i])
            }

            // Format operand based on addressing mode
            let operand = formatOperand(mode: opcode.mode, bytes: bytes, address: address)

            // Get comment if this address is known
            let comment = getComment(mode: opcode.mode, bytes: bytes, address: address)

            let instruction = DisassembledInstruction(
                address: address,
                bytes: bytes,
                mnemonic: opcode.mnemonic,
                operand: operand,
                comment: comment
            )
            instructions.append(instruction)

            // Move to next instruction
            offset += opcode.bytes
            address = address &+ UInt16(opcode.bytes)
        }

        return instructions
    }

    /// Format the operand based on addressing mode
    private static func formatOperand(mode: AddressMode6502, bytes: [UInt8], address: UInt16) -> String {
        switch mode {
        case .implied:
            return ""
        case .accumulator:
            return "A"
        case .immediate:
            guard bytes.count >= 2 else { return "#$??" }
            return String(format: "#$%02X", bytes[1])
        case .zeroPage:
            guard bytes.count >= 2 else { return "$??" }
            return String(format: "$%02X", bytes[1])
        case .zeroPageX:
            guard bytes.count >= 2 else { return "$??,X" }
            return String(format: "$%02X,X", bytes[1])
        case .zeroPageY:
            guard bytes.count >= 2 else { return "$??,Y" }
            return String(format: "$%02X,Y", bytes[1])
        case .absolute:
            guard bytes.count >= 3 else { return "$????" }
            let addr = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            return String(format: "$%04X", addr)
        case .absoluteX:
            guard bytes.count >= 3 else { return "$????,X" }
            let addr = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            return String(format: "$%04X,X", addr)
        case .absoluteY:
            guard bytes.count >= 3 else { return "$????,Y" }
            let addr = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            return String(format: "$%04X,Y", addr)
        case .indirect:
            guard bytes.count >= 3 else { return "($????)" }
            let addr = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            return String(format: "($%04X)", addr)
        case .indexedIndirect:
            guard bytes.count >= 2 else { return "($??,X)" }
            return String(format: "($%02X,X)", bytes[1])
        case .indirectIndexed:
            guard bytes.count >= 2 else { return "($??),Y" }
            return String(format: "($%02X),Y", bytes[1])
        case .relative:
            guard bytes.count >= 2 else { return "$????" }
            let offset = Int8(bitPattern: bytes[1])
            let target = Int(address) + 2 + Int(offset)
            return String(format: "$%04X", UInt16(truncatingIfNeeded: target))
        case .invalid:
            return ""
        }
    }

    /// Get a comment for known addresses
    private static func getComment(mode: AddressMode6502, bytes: [UInt8], address: UInt16) -> String? {
        var targetAddr: UInt16?

        switch mode {
        case .absolute, .absoluteX, .absoluteY:
            if bytes.count >= 3 {
                targetAddr = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            }
        case .indirect:
            if bytes.count >= 3 {
                targetAddr = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            }
        case .zeroPage, .zeroPageX, .zeroPageY, .indexedIndirect, .indirectIndexed:
            if bytes.count >= 2 {
                targetAddr = UInt16(bytes[1])
            }
        case .relative:
            if bytes.count >= 2 {
                let offset = Int8(bitPattern: bytes[1])
                targetAddr = UInt16(truncatingIfNeeded: Int(address) + 2 + Int(offset))
            }
        default:
            break
        }

        if let addr = targetAddr, let name = knownAddresses[addr] {
            return name
        }
        return nil
    }

    /// Convert disassembly to plain text
    static func toPlainText(data: Data, startAddress: UInt16) -> String {
        let instructions = disassemble(data: data, startAddress: startAddress)
        var result = ""

        for instr in instructions {
            let addrStr = String(format: "%04X:", instr.address)
            let bytesStr = instr.bytesString.padding(toLength: 9, withPad: " ", startingAt: 0)
            let instrStr = instr.fullInstruction.padding(toLength: 14, withPad: " ", startingAt: 0)

            if let comment = instr.comment {
                result += "\(addrStr) \(bytesStr) \(instrStr) ; \(comment)\n"
            } else {
                result += "\(addrStr) \(bytesStr) \(instrStr)\n"
            }
        }

        return result
    }
}

// MARK: - Disassembly View

struct DisassemblyView: View {
    let entry: DiskCatalogEntry

    @State private var instructions: [DisassembledInstruction] = []
    @State private var startAddress: UInt16 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with address info
            HStack {
                Text("6502 Disassembly")
                    .font(.headline)
                Spacer()
                Text(String(format: "Org: $%04X  Size: %d bytes", startAddress, entry.data.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Disassembly listing
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(instructions.enumerated()), id: \.offset) { _, instr in
                        DisassemblyLineView(instruction: instr)
                    }
                }
                .padding(12)
            }
            .font(.system(size: 12, design: .monospaced))
            .background(Color(NSColor.textBackgroundColor))
        }
        .onAppear {
            disassembleCode()
        }
    }

    private func disassembleCode() {
        // Determine start address from aux type (load address) or default
        if let loadAddr = entry.loadAddress {
            startAddress = UInt16(loadAddr & 0xFFFF)
        } else if entry.auxType != 0 {
            startAddress = entry.auxType
        } else {
            // Default addresses based on file type
            switch entry.fileType {
            case 0xFF:  // SYS
                startAddress = 0x2000
            case 0x06:  // BIN
                startAddress = entry.auxType != 0 ? entry.auxType : 0x0800
            default:
                startAddress = 0x0800
            }
        }

        instructions = Disassembler6502.disassemble(
            data: entry.data,
            startAddress: startAddress
        )
    }
}

struct DisassemblyLineView: View {
    let instruction: DisassembledInstruction

    // Syntax highlighting colors
    private let addressColor = Color.secondary
    private let bytesColor = Color.gray
    private let mnemonicColor = Color.blue
    private let operandColor = Color.primary
    private let commentColor = Color.green

    var body: some View {
        HStack(spacing: 0) {
            // Address
            Text(String(format: "%04X: ", instruction.address))
                .foregroundColor(addressColor)

            // Bytes
            Text(instruction.bytesString.padding(toLength: 9, withPad: " ", startingAt: 0))
                .foregroundColor(bytesColor)

            // Mnemonic
            Text(instruction.mnemonic.padding(toLength: 4, withPad: " ", startingAt: 0))
                .foregroundColor(mnemonicColor)
                .fontWeight(.semibold)

            // Operand
            Text(instruction.operand.padding(toLength: 12, withPad: " ", startingAt: 0))
                .foregroundColor(operandColor)

            // Comment
            if let comment = instruction.comment {
                Text("; \(comment)")
                    .foregroundColor(commentColor)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Preview

#Preview {
    // Sample 6502 code
    let sampleCode = Data([
        0xA9, 0x00,       // LDA #$00
        0x8D, 0x30, 0xC0, // STA $C030 (SPKR)
        0xA2, 0xFF,       // LDX #$FF
        0xCA,             // DEX
        0xD0, 0xFD,       // BNE $XXXX
        0x4C, 0x00, 0x08, // JMP $0800
        0x60,             // RTS
    ])

    return DisassemblyView(entry: DiskCatalogEntry(
        name: "SAMPLE.BIN",
        fileType: 0x06,
        fileTypeString: "BIN",
        auxType: 0x0800,
        size: sampleCode.count,
        blocks: 1,
        loadAddress: 0x0800,
        length: sampleCode.count,
        data: sampleCode,
        isImage: false,
        isDirectory: false,
        children: nil,
        modificationDate: "01-Jan-25",
        creationDate: "01-Jan-25"
    ))
}
