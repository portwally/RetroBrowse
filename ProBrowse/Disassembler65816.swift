//
//  Disassembler65816.swift
//  ProBrowse
//
//  65C816 Disassembler for Apple IIgs machine code
//  Supports both 6502 emulation mode and 65816 native mode
//

import SwiftUI

// MARK: - 65816 Addressing Modes

enum AddressMode65816: Equatable {
    case implied            // No operand (e.g., NOP, RTS)
    case accumulator        // Operates on A register (e.g., ASL A)
    case immediate8         // #$nn - Always 8-bit immediate
    case immediateM         // #$nn or #$nnnn - Size depends on M flag
    case immediateX         // #$nn or #$nnnn - Size depends on X flag
    case directPage         // $nn - Direct page address
    case directPageX        // $nn,X - Direct page indexed by X
    case directPageY        // $nn,Y - Direct page indexed by Y
    case dpIndirect         // ($nn) - Direct page indirect
    case dpIndirectLong     // [$nn] - Direct page indirect long
    case dpIndexedIndirect  // ($nn,X) - Direct page indexed indirect
    case dpIndirectIndexed  // ($nn),Y - Direct page indirect indexed Y
    case dpIndirectLongY    // [$nn],Y - Direct page indirect long indexed Y
    case absolute           // $nnnn - 16-bit absolute address
    case absoluteX          // $nnnn,X - Absolute indexed by X
    case absoluteY          // $nnnn,Y - Absolute indexed by Y
    case absoluteLong       // $nnnnnn - 24-bit absolute address
    case absoluteLongX      // $nnnnnn,X - Absolute long indexed by X
    case absoluteIndirect   // ($nnnn) - Absolute indirect (JMP only)
    case absoluteIndirectX  // ($nnnn,X) - Absolute indexed indirect (JMP/JSR)
    case absoluteIndirectLong // [$nnnn] - Absolute indirect long (JMP)
    case relative           // Branch offset (signed 8-bit)
    case relativeLong       // Long branch offset (signed 16-bit)
    case stackRelative      // $nn,S - Stack relative
    case stackRelIndirectY  // ($nn,S),Y - Stack relative indirect indexed Y
    case blockMove          // MVN/MVP - Two 1-byte bank operands
    case wdm                // WDM - Reserved, 1 byte operand
    case invalid            // Invalid opcode
}

// MARK: - 65816 Opcode Definition

struct Opcode65816 {
    let mnemonic: String
    let mode: AddressMode65816
    let baseBytes: Int      // Base instruction length (may vary for immediateM/X)
    let cycles: Int

    init(_ mnemonic: String, _ mode: AddressMode65816, _ bytes: Int, _ cycles: Int) {
        self.mnemonic = mnemonic
        self.mode = mode
        self.baseBytes = bytes
        self.cycles = cycles
    }

    /// Get actual instruction length based on processor flags
    func getLength(mFlag: Bool, xFlag: Bool) -> Int {
        switch mode {
        case .immediateM:
            return mFlag ? 2 : 3  // 8-bit if M=1, 16-bit if M=0
        case .immediateX:
            return xFlag ? 2 : 3  // 8-bit if X=1, 16-bit if X=0
        default:
            return baseBytes
        }
    }
}

// MARK: - Processor Status Flags

struct ProcessorFlags65816 {
    var mFlag: Bool = true   // M=1: 8-bit accumulator (default)
    var xFlag: Bool = true   // X=1: 8-bit index registers (default)
    var eFlag: Bool = true   // E=1: Emulation mode (6502 compatible)

    /// Update flags based on SEP instruction
    mutating func applySEP(_ value: UInt8) {
        if (value & 0x20) != 0 { mFlag = true }  // Set M
        if (value & 0x10) != 0 { xFlag = true }  // Set X
    }

    /// Update flags based on REP instruction
    mutating func applyREP(_ value: UInt8) {
        if (value & 0x20) != 0 { mFlag = false } // Clear M
        if (value & 0x10) != 0 { xFlag = false } // Clear X
    }

    /// Switch to native mode (XCE with C=0)
    mutating func enterNativeMode() {
        eFlag = false
        // Don't change M and X - they retain their values
    }

    /// Switch to emulation mode (XCE with C=1)
    mutating func enterEmulationMode() {
        eFlag = true
        mFlag = true  // Forced to 8-bit in emulation mode
        xFlag = true
    }
}

// MARK: - Disassembled 65816 Instruction

struct DisassembledInstruction65816 {
    let address: UInt32     // 24-bit address (bank + offset)
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

// MARK: - 65816 Disassembler

class Disassembler65816 {

    // Complete 65C816 opcode table (256 entries)
    static let opcodes: [Opcode65816] = [
        // $00-$0F
        Opcode65816("BRK", .immediate8, 2, 7),       // $00 - BRK has signature byte
        Opcode65816("ORA", .dpIndexedIndirect, 2, 6), // $01
        Opcode65816("COP", .immediate8, 2, 7),       // $02 - Coprocessor interrupt
        Opcode65816("ORA", .stackRelative, 2, 4),    // $03
        Opcode65816("TSB", .directPage, 2, 5),       // $04
        Opcode65816("ORA", .directPage, 2, 3),       // $05
        Opcode65816("ASL", .directPage, 2, 5),       // $06
        Opcode65816("ORA", .dpIndirectLong, 2, 6),   // $07
        Opcode65816("PHP", .implied, 1, 3),          // $08
        Opcode65816("ORA", .immediateM, 2, 2),       // $09
        Opcode65816("ASL", .accumulator, 1, 2),      // $0A
        Opcode65816("PHD", .implied, 1, 4),          // $0B - Push Direct Page
        Opcode65816("TSB", .absolute, 3, 6),         // $0C
        Opcode65816("ORA", .absolute, 3, 4),         // $0D
        Opcode65816("ASL", .absolute, 3, 6),         // $0E
        Opcode65816("ORA", .absoluteLong, 4, 5),     // $0F

        // $10-$1F
        Opcode65816("BPL", .relative, 2, 2),         // $10
        Opcode65816("ORA", .dpIndirectIndexed, 2, 5), // $11
        Opcode65816("ORA", .dpIndirect, 2, 5),       // $12
        Opcode65816("ORA", .stackRelIndirectY, 2, 7), // $13
        Opcode65816("TRB", .directPage, 2, 5),       // $14
        Opcode65816("ORA", .directPageX, 2, 4),      // $15
        Opcode65816("ASL", .directPageX, 2, 6),      // $16
        Opcode65816("ORA", .dpIndirectLongY, 2, 6),  // $17
        Opcode65816("CLC", .implied, 1, 2),          // $18
        Opcode65816("ORA", .absoluteY, 3, 4),        // $19
        Opcode65816("INC", .accumulator, 1, 2),      // $1A - INC A (65C02/816)
        Opcode65816("TCS", .implied, 1, 2),          // $1B - Transfer C to Stack
        Opcode65816("TRB", .absolute, 3, 6),         // $1C
        Opcode65816("ORA", .absoluteX, 3, 4),        // $1D
        Opcode65816("ASL", .absoluteX, 3, 7),        // $1E
        Opcode65816("ORA", .absoluteLongX, 4, 5),    // $1F

        // $20-$2F
        Opcode65816("JSR", .absolute, 3, 6),         // $20
        Opcode65816("AND", .dpIndexedIndirect, 2, 6), // $21
        Opcode65816("JSL", .absoluteLong, 4, 8),     // $22 - Jump Subroutine Long
        Opcode65816("AND", .stackRelative, 2, 4),    // $23
        Opcode65816("BIT", .directPage, 2, 3),       // $24
        Opcode65816("AND", .directPage, 2, 3),       // $25
        Opcode65816("ROL", .directPage, 2, 5),       // $26
        Opcode65816("AND", .dpIndirectLong, 2, 6),   // $27
        Opcode65816("PLP", .implied, 1, 4),          // $28
        Opcode65816("AND", .immediateM, 2, 2),       // $29
        Opcode65816("ROL", .accumulator, 1, 2),      // $2A
        Opcode65816("PLD", .implied, 1, 5),          // $2B - Pull Direct Page
        Opcode65816("BIT", .absolute, 3, 4),         // $2C
        Opcode65816("AND", .absolute, 3, 4),         // $2D
        Opcode65816("ROL", .absolute, 3, 6),         // $2E
        Opcode65816("AND", .absoluteLong, 4, 5),     // $2F

        // $30-$3F
        Opcode65816("BMI", .relative, 2, 2),         // $30
        Opcode65816("AND", .dpIndirectIndexed, 2, 5), // $31
        Opcode65816("AND", .dpIndirect, 2, 5),       // $32
        Opcode65816("AND", .stackRelIndirectY, 2, 7), // $33
        Opcode65816("BIT", .directPageX, 2, 4),      // $34
        Opcode65816("AND", .directPageX, 2, 4),      // $35
        Opcode65816("ROL", .directPageX, 2, 6),      // $36
        Opcode65816("AND", .dpIndirectLongY, 2, 6),  // $37
        Opcode65816("SEC", .implied, 1, 2),          // $38
        Opcode65816("AND", .absoluteY, 3, 4),        // $39
        Opcode65816("DEC", .accumulator, 1, 2),      // $3A - DEC A (65C02/816)
        Opcode65816("TSC", .implied, 1, 2),          // $3B - Transfer Stack to C
        Opcode65816("BIT", .absoluteX, 3, 4),        // $3C
        Opcode65816("AND", .absoluteX, 3, 4),        // $3D
        Opcode65816("ROL", .absoluteX, 3, 7),        // $3E
        Opcode65816("AND", .absoluteLongX, 4, 5),    // $3F

        // $40-$4F
        Opcode65816("RTI", .implied, 1, 6),          // $40
        Opcode65816("EOR", .dpIndexedIndirect, 2, 6), // $41
        Opcode65816("WDM", .wdm, 2, 2),              // $42 - Reserved
        Opcode65816("EOR", .stackRelative, 2, 4),    // $43
        Opcode65816("MVP", .blockMove, 3, 7),        // $44 - Block Move Positive
        Opcode65816("EOR", .directPage, 2, 3),       // $45
        Opcode65816("LSR", .directPage, 2, 5),       // $46
        Opcode65816("EOR", .dpIndirectLong, 2, 6),   // $47
        Opcode65816("PHA", .implied, 1, 3),          // $48
        Opcode65816("EOR", .immediateM, 2, 2),       // $49
        Opcode65816("LSR", .accumulator, 1, 2),      // $4A
        Opcode65816("PHK", .implied, 1, 3),          // $4B - Push Program Bank
        Opcode65816("JMP", .absolute, 3, 3),         // $4C
        Opcode65816("EOR", .absolute, 3, 4),         // $4D
        Opcode65816("LSR", .absolute, 3, 6),         // $4E
        Opcode65816("EOR", .absoluteLong, 4, 5),     // $4F

        // $50-$5F
        Opcode65816("BVC", .relative, 2, 2),         // $50
        Opcode65816("EOR", .dpIndirectIndexed, 2, 5), // $51
        Opcode65816("EOR", .dpIndirect, 2, 5),       // $52
        Opcode65816("EOR", .stackRelIndirectY, 2, 7), // $53
        Opcode65816("MVN", .blockMove, 3, 7),        // $54 - Block Move Negative
        Opcode65816("EOR", .directPageX, 2, 4),      // $55
        Opcode65816("LSR", .directPageX, 2, 6),      // $56
        Opcode65816("EOR", .dpIndirectLongY, 2, 6),  // $57
        Opcode65816("CLI", .implied, 1, 2),          // $58
        Opcode65816("EOR", .absoluteY, 3, 4),        // $59
        Opcode65816("PHY", .implied, 1, 3),          // $5A - Push Y (65C02/816)
        Opcode65816("TCD", .implied, 1, 2),          // $5B - Transfer C to Direct
        Opcode65816("JML", .absoluteLong, 4, 4),     // $5C - Jump Long
        Opcode65816("EOR", .absoluteX, 3, 4),        // $5D
        Opcode65816("LSR", .absoluteX, 3, 7),        // $5E
        Opcode65816("EOR", .absoluteLongX, 4, 5),    // $5F

        // $60-$6F
        Opcode65816("RTS", .implied, 1, 6),          // $60
        Opcode65816("ADC", .dpIndexedIndirect, 2, 6), // $61
        Opcode65816("PER", .relativeLong, 3, 6),     // $62 - Push Effective Relative
        Opcode65816("ADC", .stackRelative, 2, 4),    // $63
        Opcode65816("STZ", .directPage, 2, 3),       // $64 - Store Zero
        Opcode65816("ADC", .directPage, 2, 3),       // $65
        Opcode65816("ROR", .directPage, 2, 5),       // $66
        Opcode65816("ADC", .dpIndirectLong, 2, 6),   // $67
        Opcode65816("PLA", .implied, 1, 4),          // $68
        Opcode65816("ADC", .immediateM, 2, 2),       // $69
        Opcode65816("ROR", .accumulator, 1, 2),      // $6A
        Opcode65816("RTL", .implied, 1, 6),          // $6B - Return Long
        Opcode65816("JMP", .absoluteIndirect, 3, 5), // $6C
        Opcode65816("ADC", .absolute, 3, 4),         // $6D
        Opcode65816("ROR", .absolute, 3, 6),         // $6E
        Opcode65816("ADC", .absoluteLong, 4, 5),     // $6F

        // $70-$7F
        Opcode65816("BVS", .relative, 2, 2),         // $70
        Opcode65816("ADC", .dpIndirectIndexed, 2, 5), // $71
        Opcode65816("ADC", .dpIndirect, 2, 5),       // $72
        Opcode65816("ADC", .stackRelIndirectY, 2, 7), // $73
        Opcode65816("STZ", .directPageX, 2, 4),      // $74
        Opcode65816("ADC", .directPageX, 2, 4),      // $75
        Opcode65816("ROR", .directPageX, 2, 6),      // $76
        Opcode65816("ADC", .dpIndirectLongY, 2, 6),  // $77
        Opcode65816("SEI", .implied, 1, 2),          // $78
        Opcode65816("ADC", .absoluteY, 3, 4),        // $79
        Opcode65816("PLY", .implied, 1, 4),          // $7A - Pull Y (65C02/816)
        Opcode65816("TDC", .implied, 1, 2),          // $7B - Transfer Direct to C
        Opcode65816("JMP", .absoluteIndirectX, 3, 6), // $7C
        Opcode65816("ADC", .absoluteX, 3, 4),        // $7D
        Opcode65816("ROR", .absoluteX, 3, 7),        // $7E
        Opcode65816("ADC", .absoluteLongX, 4, 5),    // $7F

        // $80-$8F
        Opcode65816("BRA", .relative, 2, 3),         // $80 - Branch Always (65C02/816)
        Opcode65816("STA", .dpIndexedIndirect, 2, 6), // $81
        Opcode65816("BRL", .relativeLong, 3, 4),     // $82 - Branch Long
        Opcode65816("STA", .stackRelative, 2, 4),    // $83
        Opcode65816("STY", .directPage, 2, 3),       // $84
        Opcode65816("STA", .directPage, 2, 3),       // $85
        Opcode65816("STX", .directPage, 2, 3),       // $86
        Opcode65816("STA", .dpIndirectLong, 2, 6),   // $87
        Opcode65816("DEY", .implied, 1, 2),          // $88
        Opcode65816("BIT", .immediateM, 2, 2),       // $89 - BIT immediate (65C02/816)
        Opcode65816("TXA", .implied, 1, 2),          // $8A
        Opcode65816("PHB", .implied, 1, 3),          // $8B - Push Data Bank
        Opcode65816("STY", .absolute, 3, 4),         // $8C
        Opcode65816("STA", .absolute, 3, 4),         // $8D
        Opcode65816("STX", .absolute, 3, 4),         // $8E
        Opcode65816("STA", .absoluteLong, 4, 5),     // $8F

        // $90-$9F
        Opcode65816("BCC", .relative, 2, 2),         // $90
        Opcode65816("STA", .dpIndirectIndexed, 2, 6), // $91
        Opcode65816("STA", .dpIndirect, 2, 5),       // $92
        Opcode65816("STA", .stackRelIndirectY, 2, 7), // $93
        Opcode65816("STY", .directPageX, 2, 4),      // $94
        Opcode65816("STA", .directPageX, 2, 4),      // $95
        Opcode65816("STX", .directPageY, 2, 4),      // $96
        Opcode65816("STA", .dpIndirectLongY, 2, 6),  // $97
        Opcode65816("TYA", .implied, 1, 2),          // $98
        Opcode65816("STA", .absoluteY, 3, 5),        // $99
        Opcode65816("TXS", .implied, 1, 2),          // $9A
        Opcode65816("TXY", .implied, 1, 2),          // $9B - Transfer X to Y
        Opcode65816("STZ", .absolute, 3, 4),         // $9C - Store Zero
        Opcode65816("STA", .absoluteX, 3, 5),        // $9D
        Opcode65816("STZ", .absoluteX, 3, 5),        // $9E - Store Zero
        Opcode65816("STA", .absoluteLongX, 4, 5),    // $9F

        // $A0-$AF
        Opcode65816("LDY", .immediateX, 2, 2),       // $A0
        Opcode65816("LDA", .dpIndexedIndirect, 2, 6), // $A1
        Opcode65816("LDX", .immediateX, 2, 2),       // $A2
        Opcode65816("LDA", .stackRelative, 2, 4),    // $A3
        Opcode65816("LDY", .directPage, 2, 3),       // $A4
        Opcode65816("LDA", .directPage, 2, 3),       // $A5
        Opcode65816("LDX", .directPage, 2, 3),       // $A6
        Opcode65816("LDA", .dpIndirectLong, 2, 6),   // $A7
        Opcode65816("TAY", .implied, 1, 2),          // $A8
        Opcode65816("LDA", .immediateM, 2, 2),       // $A9
        Opcode65816("TAX", .implied, 1, 2),          // $AA
        Opcode65816("PLB", .implied, 1, 4),          // $AB - Pull Data Bank
        Opcode65816("LDY", .absolute, 3, 4),         // $AC
        Opcode65816("LDA", .absolute, 3, 4),         // $AD
        Opcode65816("LDX", .absolute, 3, 4),         // $AE
        Opcode65816("LDA", .absoluteLong, 4, 5),     // $AF

        // $B0-$BF
        Opcode65816("BCS", .relative, 2, 2),         // $B0
        Opcode65816("LDA", .dpIndirectIndexed, 2, 5), // $B1
        Opcode65816("LDA", .dpIndirect, 2, 5),       // $B2
        Opcode65816("LDA", .stackRelIndirectY, 2, 7), // $B3
        Opcode65816("LDY", .directPageX, 2, 4),      // $B4
        Opcode65816("LDA", .directPageX, 2, 4),      // $B5
        Opcode65816("LDX", .directPageY, 2, 4),      // $B6
        Opcode65816("LDA", .dpIndirectLongY, 2, 6),  // $B7
        Opcode65816("CLV", .implied, 1, 2),          // $B8
        Opcode65816("LDA", .absoluteY, 3, 4),        // $B9
        Opcode65816("TSX", .implied, 1, 2),          // $BA
        Opcode65816("TYX", .implied, 1, 2),          // $BB - Transfer Y to X
        Opcode65816("LDY", .absoluteX, 3, 4),        // $BC
        Opcode65816("LDA", .absoluteX, 3, 4),        // $BD
        Opcode65816("LDX", .absoluteY, 3, 4),        // $BE
        Opcode65816("LDA", .absoluteLongX, 4, 5),    // $BF

        // $C0-$CF
        Opcode65816("CPY", .immediateX, 2, 2),       // $C0
        Opcode65816("CMP", .dpIndexedIndirect, 2, 6), // $C1
        Opcode65816("REP", .immediate8, 2, 3),       // $C2 - Reset Processor Status
        Opcode65816("CMP", .stackRelative, 2, 4),    // $C3
        Opcode65816("CPY", .directPage, 2, 3),       // $C4
        Opcode65816("CMP", .directPage, 2, 3),       // $C5
        Opcode65816("DEC", .directPage, 2, 5),       // $C6
        Opcode65816("CMP", .dpIndirectLong, 2, 6),   // $C7
        Opcode65816("INY", .implied, 1, 2),          // $C8
        Opcode65816("CMP", .immediateM, 2, 2),       // $C9
        Opcode65816("DEX", .implied, 1, 2),          // $CA
        Opcode65816("WAI", .implied, 1, 3),          // $CB - Wait for Interrupt
        Opcode65816("CPY", .absolute, 3, 4),         // $CC
        Opcode65816("CMP", .absolute, 3, 4),         // $CD
        Opcode65816("DEC", .absolute, 3, 6),         // $CE
        Opcode65816("CMP", .absoluteLong, 4, 5),     // $CF

        // $D0-$DF
        Opcode65816("BNE", .relative, 2, 2),         // $D0
        Opcode65816("CMP", .dpIndirectIndexed, 2, 5), // $D1
        Opcode65816("CMP", .dpIndirect, 2, 5),       // $D2
        Opcode65816("CMP", .stackRelIndirectY, 2, 7), // $D3
        Opcode65816("PEI", .dpIndirect, 2, 6),       // $D4 - Push Effective Indirect
        Opcode65816("CMP", .directPageX, 2, 4),      // $D5
        Opcode65816("DEC", .directPageX, 2, 6),      // $D6
        Opcode65816("CMP", .dpIndirectLongY, 2, 6),  // $D7
        Opcode65816("CLD", .implied, 1, 2),          // $D8
        Opcode65816("CMP", .absoluteY, 3, 4),        // $D9
        Opcode65816("PHX", .implied, 1, 3),          // $DA - Push X (65C02/816)
        Opcode65816("STP", .implied, 1, 3),          // $DB - Stop Processor
        Opcode65816("JMP", .absoluteIndirectLong, 3, 6), // $DC - JMP [abs]
        Opcode65816("CMP", .absoluteX, 3, 4),        // $DD
        Opcode65816("DEC", .absoluteX, 3, 7),        // $DE
        Opcode65816("CMP", .absoluteLongX, 4, 5),    // $DF

        // $E0-$EF
        Opcode65816("CPX", .immediateX, 2, 2),       // $E0
        Opcode65816("SBC", .dpIndexedIndirect, 2, 6), // $E1
        Opcode65816("SEP", .immediate8, 2, 3),       // $E2 - Set Processor Status
        Opcode65816("SBC", .stackRelative, 2, 4),    // $E3
        Opcode65816("CPX", .directPage, 2, 3),       // $E4
        Opcode65816("SBC", .directPage, 2, 3),       // $E5
        Opcode65816("INC", .directPage, 2, 5),       // $E6
        Opcode65816("SBC", .dpIndirectLong, 2, 6),   // $E7
        Opcode65816("INX", .implied, 1, 2),          // $E8
        Opcode65816("SBC", .immediateM, 2, 2),       // $E9
        Opcode65816("NOP", .implied, 1, 2),          // $EA
        Opcode65816("XBA", .implied, 1, 3),          // $EB - Exchange B and A
        Opcode65816("CPX", .absolute, 3, 4),         // $EC
        Opcode65816("SBC", .absolute, 3, 4),         // $ED
        Opcode65816("INC", .absolute, 3, 6),         // $EE
        Opcode65816("SBC", .absoluteLong, 4, 5),     // $EF

        // $F0-$FF
        Opcode65816("BEQ", .relative, 2, 2),         // $F0
        Opcode65816("SBC", .dpIndirectIndexed, 2, 5), // $F1
        Opcode65816("SBC", .dpIndirect, 2, 5),       // $F2
        Opcode65816("SBC", .stackRelIndirectY, 2, 7), // $F3
        Opcode65816("PEA", .absolute, 3, 5),         // $F4 - Push Effective Absolute
        Opcode65816("SBC", .directPageX, 2, 4),      // $F5
        Opcode65816("INC", .directPageX, 2, 6),      // $F6
        Opcode65816("SBC", .dpIndirectLongY, 2, 6),  // $F7
        Opcode65816("SED", .implied, 1, 2),          // $F8
        Opcode65816("SBC", .absoluteY, 3, 4),        // $F9
        Opcode65816("PLX", .implied, 1, 4),          // $FA - Pull X (65C02/816)
        Opcode65816("XCE", .implied, 1, 2),          // $FB - Exchange Carry and Emulation
        Opcode65816("JSR", .absoluteIndirectX, 3, 8), // $FC - JSR (abs,X)
        Opcode65816("SBC", .absoluteX, 3, 4),        // $FD
        Opcode65816("INC", .absoluteX, 3, 7),        // $FE
        Opcode65816("SBC", .absoluteLongX, 4, 5),    // $FF
    ]

    // Known Apple IIgs addresses
    static let knownAddresses: [UInt32: String] = [
        // ProDOS 16/GS/OS
        0xE100A8: "GSOS",
        0xE10000: "TOOLFUNC",
        0xE10004: "INTFUNC",
        0xE10008: "USERTOOLFUNC",

        // ROM Entry Points
        0xFA0000: "ROM01",
        0xFE0000: "ROM03",

        // Soft Switches (E0/C0xx)
        0x00C000: "KBD",
        0x00C010: "KBDSTRB",
        0x00C020: "TAPEOUT",
        0x00C030: "SPKR",
        0x00C050: "TXTCLR",
        0x00C051: "TXTSET",
        0x00C052: "MIXCLR",
        0x00C053: "MIXSET",
        0x00C054: "LOWSCR",
        0x00C055: "HISCR",
        0x00C056: "LORES",
        0x00C057: "HIRES",
        0x00C068: "STATEREG",
        0x00C034: "BORDER",

        // SHR Graphics
        0xE12000: "SHRSCB",
        0xE19E00: "SHRPALETTE",
    ]

    /// Disassemble 65816 code with flag tracking
    /// - Parameters:
    ///   - data: Binary data to disassemble
    ///   - startAddress: 24-bit starting address
    ///   - startInNativeMode: Whether to start in native mode (16-bit)
    ///   - maxInstructions: Maximum number of instructions
    /// - Returns: Array of disassembled instructions
    static func disassemble(
        data: Data,
        startAddress: UInt32,
        startInNativeMode: Bool = true,
        maxInstructions: Int = 2000
    ) -> [DisassembledInstruction65816] {
        var instructions: [DisassembledInstruction65816] = []
        var offset = 0
        var address = startAddress

        // Initialize processor flags. Both modes start with 8-bit registers;
        // only native mode lets REP widen them.
        var flags = ProcessorFlags65816()
        flags.eFlag = !startInNativeMode
        
        // Carry as set by a CLC or SEC directly before the current instruction, if any
        var knownCarry: Bool? = nil

        while offset < data.count && instructions.count < maxInstructions {
            let opcodeByte = data[offset]
            let opcode = opcodes[Int(opcodeByte)]

            // Calculate actual instruction length
            let instrLength = opcode.getLength(mFlag: flags.mFlag, xFlag: flags.xFlag)

            // Collect bytes for this instruction
            var bytes: [UInt8] = [opcodeByte]
            let bytesAvailable = min(instrLength, data.count - offset)

            for i in 1..<bytesAvailable {
                bytes.append(data[offset + i])
            }

            // Update flags for SEP/REP instructions
            if opcodeByte == 0xE2 && bytes.count >= 2 {  // SEP
                flags.applySEP(bytes[1])
            } else if opcodeByte == 0xC2 && bytes.count >= 2 {  // REP
                // M and X are fixed at 8 bits in emulation mode
                if !flags.eFlag {
                    flags.applyREP(bytes[1])
                }
            } else if opcodeByte == 0xFB {  // XCE swaps carry and the emulation flag
                if knownCarry == true {
                    flags.enterEmulationMode()
                } else if knownCarry == false || flags.eFlag {
                    // Without a CLC/SEC in front the carry is unknown; assume a switch to native
                    flags.enterNativeMode()
                }
            }
            
            switch opcodeByte {
            case 0x18: knownCarry = false  // CLC
            case 0x38: knownCarry = true   // SEC
            default: knownCarry = nil
            }

            // Format operand
            let operand = formatOperand(
                mode: opcode.mode,
                bytes: bytes,
                address: address,
                mFlag: flags.mFlag,
                xFlag: flags.xFlag
            )

            // Get comment
            let comment = getComment(mode: opcode.mode, bytes: bytes, address: address, opcodeByte: opcodeByte)

            let instruction = DisassembledInstruction65816(
                address: address,
                bytes: bytes,
                mnemonic: opcode.mnemonic,
                operand: operand,
                comment: comment
            )
            instructions.append(instruction)

            // Move to next instruction
            offset += instrLength
            address = address &+ UInt32(instrLength)
        }

        return instructions
    }

    /// Format operand based on addressing mode
    private static func formatOperand(
        mode: AddressMode65816,
        bytes: [UInt8],
        address: UInt32,
        mFlag: Bool,
        xFlag: Bool
    ) -> String {
        switch mode {
        case .implied:
            return ""
        case .accumulator:
            return "A"

        case .immediate8:
            guard bytes.count >= 2 else { return "#$??" }
            return String(format: "#$%02X", bytes[1])

        case .immediateM:
            if mFlag {  // 8-bit
                guard bytes.count >= 2 else { return "#$??" }
                return String(format: "#$%02X", bytes[1])
            } else {  // 16-bit
                guard bytes.count >= 3 else { return "#$????" }
                let val = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
                return String(format: "#$%04X", val)
            }

        case .immediateX:
            if xFlag {  // 8-bit
                guard bytes.count >= 2 else { return "#$??" }
                return String(format: "#$%02X", bytes[1])
            } else {  // 16-bit
                guard bytes.count >= 3 else { return "#$????" }
                let val = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
                return String(format: "#$%04X", val)
            }

        case .directPage:
            guard bytes.count >= 2 else { return "$??" }
            return String(format: "$%02X", bytes[1])

        case .directPageX:
            guard bytes.count >= 2 else { return "$??,X" }
            return String(format: "$%02X,X", bytes[1])

        case .directPageY:
            guard bytes.count >= 2 else { return "$??,Y" }
            return String(format: "$%02X,Y", bytes[1])

        case .dpIndirect:
            guard bytes.count >= 2 else { return "($??)" }
            return String(format: "($%02X)", bytes[1])

        case .dpIndirectLong:
            guard bytes.count >= 2 else { return "[$??]" }
            return String(format: "[$%02X]", bytes[1])

        case .dpIndexedIndirect:
            guard bytes.count >= 2 else { return "($??,X)" }
            return String(format: "($%02X,X)", bytes[1])

        case .dpIndirectIndexed:
            guard bytes.count >= 2 else { return "($??),Y" }
            return String(format: "($%02X),Y", bytes[1])

        case .dpIndirectLongY:
            guard bytes.count >= 2 else { return "[$??],Y" }
            return String(format: "[$%02X],Y", bytes[1])

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

        case .absoluteLong:
            guard bytes.count >= 4 else { return "$??????" }
            let addr = UInt32(bytes[1]) | (UInt32(bytes[2]) << 8) | (UInt32(bytes[3]) << 16)
            return String(format: "$%06X", addr)

        case .absoluteLongX:
            guard bytes.count >= 4 else { return "$??????,X" }
            let addr = UInt32(bytes[1]) | (UInt32(bytes[2]) << 8) | (UInt32(bytes[3]) << 16)
            return String(format: "$%06X,X", addr)

        case .absoluteIndirect:
            guard bytes.count >= 3 else { return "($????)" }
            let addr = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            return String(format: "($%04X)", addr)

        case .absoluteIndirectX:
            guard bytes.count >= 3 else { return "($????,X)" }
            let addr = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            return String(format: "($%04X,X)", addr)

        case .absoluteIndirectLong:
            guard bytes.count >= 3 else { return "[$????]" }
            let addr = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            return String(format: "[$%04X]", addr)

        case .relative:
            guard bytes.count >= 2 else { return "$????" }
            let offset = Int8(bitPattern: bytes[1])
            let target = Int(address) + 2 + Int(offset)
            return String(format: "$%04X", UInt16(truncatingIfNeeded: target))

        case .relativeLong:
            guard bytes.count >= 3 else { return "$????" }
            let offset = Int16(bitPattern: UInt16(bytes[1]) | (UInt16(bytes[2]) << 8))
            let target = Int(address) + 3 + Int(offset)
            return String(format: "$%04X", UInt16(truncatingIfNeeded: target))

        case .stackRelative:
            guard bytes.count >= 2 else { return "$??,S" }
            return String(format: "$%02X,S", bytes[1])

        case .stackRelIndirectY:
            guard bytes.count >= 2 else { return "($??,S),Y" }
            return String(format: "($%02X,S),Y", bytes[1])

        case .blockMove:
            guard bytes.count >= 3 else { return "$??,??" }
            return String(format: "$%02X,$%02X", bytes[1], bytes[2])

        case .wdm:
            guard bytes.count >= 2 else { return "$??" }
            return String(format: "$%02X", bytes[1])

        case .invalid:
            return ""
        }
    }

    /// Get comment for instruction
    private static func getComment(
        mode: AddressMode65816,
        bytes: [UInt8],
        address: UInt32,
        opcodeByte: UInt8
    ) -> String? {
        // Special comments for flag-changing instructions
        if opcodeByte == 0xE2 && bytes.count >= 2 {  // SEP
            return describeFlagChange(bytes[1], isSet: true)
        } else if opcodeByte == 0xC2 && bytes.count >= 2 {  // REP
            return describeFlagChange(bytes[1], isSet: false)
        }

        // Look up target address
        var targetAddr: UInt32?

        switch mode {
        case .absolute, .absoluteX, .absoluteY, .absoluteIndirect, .absoluteIndirectX, .absoluteIndirectLong:
            if bytes.count >= 3 {
                let offset = UInt32(bytes[1]) | (UInt32(bytes[2]) << 8)
                // Use current bank for absolute addressing
                targetAddr = (address & 0xFF0000) | offset
            }
        case .absoluteLong, .absoluteLongX:
            if bytes.count >= 4 {
                targetAddr = UInt32(bytes[1]) | (UInt32(bytes[2]) << 8) | (UInt32(bytes[3]) << 16)
            }
        case .directPage, .directPageX, .directPageY, .dpIndirect, .dpIndirectLong,
             .dpIndexedIndirect, .dpIndirectIndexed, .dpIndirectLongY:
            if bytes.count >= 2 {
                targetAddr = UInt32(bytes[1])
            }
        default:
            break
        }

        if let addr = targetAddr, let name = knownAddresses[addr] {
            return name
        }

        // Check 16-bit address in bank 0 (common soft switches)
        if let addr = targetAddr, addr < 0x10000 {
            let addr16 = UInt16(addr)
            if let name = Disassembler6502.knownAddresses[addr16] {
                return name
            }
        }

        return nil
    }

    /// Describe flag changes for SEP/REP
    private static func describeFlagChange(_ value: UInt8, isSet: Bool) -> String {
        var flags: [String] = []
        let action = isSet ? "Set" : "Clear"

        if (value & 0x80) != 0 { flags.append("N") }
        if (value & 0x40) != 0 { flags.append("V") }
        if (value & 0x20) != 0 { flags.append("M (8-bit A)") }
        if (value & 0x10) != 0 { flags.append("X (8-bit XY)") }
        if (value & 0x08) != 0 { flags.append("D") }
        if (value & 0x04) != 0 { flags.append("I") }
        if (value & 0x02) != 0 { flags.append("Z") }
        if (value & 0x01) != 0 { flags.append("C") }

        return "\(action): \(flags.joined(separator: ", "))"
    }

    /// Convert to plain text
    static func toPlainText(data: Data, startAddress: UInt32, nativeMode: Bool = true) -> String {
        let instructions = disassemble(data: data, startAddress: startAddress, startInNativeMode: nativeMode)
        var result = ""

        for instr in instructions {
            let bank = (instr.address >> 16) & 0xFF
            let offset = instr.address & 0xFFFF
            let addrStr = String(format: "%02X/%04X:", bank, offset)
            let bytesStr = instr.bytesString.padding(toLength: 12, withPad: " ", startingAt: 0)
            let instrStr = instr.fullInstruction.padding(toLength: 16, withPad: " ", startingAt: 0)

            if let comment = instr.comment {
                result += "\(addrStr) \(bytesStr) \(instrStr) ; \(comment)\n"
            } else {
                result += "\(addrStr) \(bytesStr) \(instrStr)\n"
            }
        }

        return result
    }
}

// MARK: - 65816 Disassembly View

struct Disassembly65816View: View {
    let entry: DiskCatalogEntry

    @State private var instructions: [DisassembledInstruction65816] = []
    @State private var startAddress: UInt32 = 0
    @State private var nativeMode: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("65C816 Disassembly")
                    .font(.headline)

                Spacer()

                Toggle("Native Mode", isOn: $nativeMode)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: nativeMode) { _, _ in
                        disassembleCode()
                    }

                Text(String(format: "Org: $%06X  Size: %d bytes", startAddress, entry.data.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Disassembly listing
            // A two-axis scroll view centres content smaller than itself, so the listing
            // is given at least the visible size and pinned to the top left
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(instructions.enumerated()), id: \.offset) { _, instr in
                            Disassembly65816LineView(instruction: instr)
                        }
                    }
                    .padding(12)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .background(Color(NSColor.textBackgroundColor))
        }
        .onAppear {
            disassembleCode()
        }
    }

    private func disassembleCode() {
        // Determine start address
        if let loadAddr = entry.loadAddress {
            startAddress = UInt32(loadAddr & 0xFFFFFF)
        } else if entry.auxType != 0 {
            startAddress = UInt32(entry.auxType)
        } else {
            // Default based on file type
            switch entry.fileType {
            case 0xB3:  // S16 - GS/OS application
                startAddress = 0x010000
            case 0xB5:  // EXE - GS/OS executable
                startAddress = 0x010000
            case 0xFF:  // SYS
                startAddress = 0x002000
            default:
                startAddress = 0x000800
            }
        }

        instructions = Disassembler65816.disassemble(
            data: entry.data,
            startAddress: startAddress,
            startInNativeMode: nativeMode
        )
    }
}

struct Disassembly65816LineView: View {
    let instruction: DisassembledInstruction65816

    private let addressColor = Color.secondary
    private let bytesColor = Color.gray
    private let mnemonicColor = Color.blue
    private let operandColor = Color.primary
    private let commentColor = Color.green

    var body: some View {
        HStack(spacing: 0) {
            // Bank/Address
            let bank = (instruction.address >> 16) & 0xFF
            let offset = instruction.address & 0xFFFF
            Text(String(format: "%02X/%04X: ", bank, offset))
                .foregroundColor(addressColor)

            // Bytes
            Text(instruction.bytesString.padding(toLength: 12, withPad: " ", startingAt: 0))
                .foregroundColor(bytesColor)

            // Mnemonic
            Text(instruction.mnemonic.padding(toLength: 4, withPad: " ", startingAt: 0))
                .foregroundColor(mnemonicColor)
                .fontWeight(.semibold)

            // Operand
            Text(instruction.operand.padding(toLength: 14, withPad: " ", startingAt: 0))
                .foregroundColor(operandColor)

            // Comment
            if let comment = instruction.comment {
                Text("; \(comment)")
                    .foregroundColor(commentColor)
            }

        }
        .fixedSize()
    }
}

// MARK: - Preview

#Preview {
    // Sample 65816 code
    let sampleCode = Data([
        0x18,             // CLC
        0xFB,             // XCE - Switch to native mode
        0xC2, 0x30,       // REP #$30 - 16-bit A and XY
        0xA9, 0x34, 0x12, // LDA #$1234
        0x8D, 0x00, 0x20, // STA $2000
        0xE2, 0x20,       // SEP #$20 - 8-bit A
        0xA9, 0x00,       // LDA #$00
        0x22, 0x00, 0x00, 0xE1, // JSL $E10000
        0x6B,             // RTL
    ])

    return Disassembly65816View(entry: DiskCatalogEntry(
        name: "SAMPLE.S16",
        fileType: 0xB3,
        fileTypeString: "S16",
        auxType: 0x0000,
        size: sampleCode.count,
        blocks: 1,
        loadAddress: 0x010000,
        length: sampleCode.count,
        data: sampleCode,
        isImage: false,
        isDirectory: false,
        children: nil,
        modificationDate: "01-Jan-25",
        creationDate: "01-Jan-25"
    ))
}
