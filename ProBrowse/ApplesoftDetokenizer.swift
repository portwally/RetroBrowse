//
//  ApplesoftDetokenizer.swift
//  ProBrowse
//
//  Converts tokenized Applesoft BASIC programs to readable text
//

import Foundation

class ApplesoftDetokenizer {

    // Complete Applesoft BASIC token table ($80-$EA)
    static let tokens: [UInt8: String] = [
        // Statement tokens ($80-$BF)
        0x80: "END",
        0x81: "FOR",
        0x82: "NEXT",
        0x83: "DATA",
        0x84: "INPUT",
        0x85: "DEL",
        0x86: "DIM",
        0x87: "READ",
        0x88: "GR",
        0x89: "TEXT",
        0x8A: "PR#",
        0x8B: "IN#",
        0x8C: "CALL",
        0x8D: "PLOT",
        0x8E: "HLIN",
        0x8F: "VLIN",
        0x90: "HGR2",
        0x91: "HGR",
        0x92: "HCOLOR=",
        0x93: "HPLOT",
        0x94: "DRAW",
        0x95: "XDRAW",
        0x96: "HTAB",
        0x97: "HOME",
        0x98: "ROT=",
        0x99: "SCALE=",
        0x9A: "SHLOAD",
        0x9B: "TRACE",
        0x9C: "NOTRACE",
        0x9D: "NORMAL",
        0x9E: "INVERSE",
        0x9F: "FLASH",
        0xA0: "COLOR=",
        0xA1: "POP",
        0xA2: "VTAB",
        0xA3: "HIMEM:",
        0xA4: "LOMEM:",
        0xA5: "ONERR",
        0xA6: "RESUME",
        0xA7: "RECALL",
        0xA8: "STORE",
        0xA9: "SPEED=",
        0xAA: "LET",
        0xAB: "GOTO",
        0xAC: "RUN",
        0xAD: "IF",
        0xAE: "RESTORE",
        0xAF: "&",
        0xB0: "GOSUB",
        0xB1: "RETURN",
        0xB2: "REM",
        0xB3: "STOP",
        0xB4: "ON",
        0xB5: "WAIT",
        0xB6: "LOAD",
        0xB7: "SAVE",
        0xB8: "DEF",
        0xB9: "POKE",
        0xBA: "PRINT",
        0xBB: "CONT",
        0xBC: "LIST",
        0xBD: "CLEAR",
        0xBE: "GET",
        0xBF: "NEW",

        // Operator/function tokens ($C0-$EA)
        0xC0: "TAB(",
        0xC1: "TO",
        0xC2: "FN",
        0xC3: "SPC(",
        0xC4: "THEN",
        0xC5: "AT",
        0xC6: "NOT",
        0xC7: "STEP",
        0xC8: "+",
        0xC9: "-",
        0xCA: "*",
        0xCB: "/",
        0xCC: "^",
        0xCD: "AND",
        0xCE: "OR",
        0xCF: ">",
        0xD0: "=",
        0xD1: "<",
        0xD2: "SGN",
        0xD3: "INT",
        0xD4: "ABS",
        0xD5: "USR",
        0xD6: "FRE",
        0xD7: "SCRN(",
        0xD8: "PDL",
        0xD9: "POS",
        0xDA: "SQR",
        0xDB: "RND",
        0xDC: "LOG",
        0xDD: "EXP",
        0xDE: "COS",
        0xDF: "SIN",
        0xE0: "TAN",
        0xE1: "ATN",
        0xE2: "PEEK",
        0xE3: "LEN",
        0xE4: "STR$",
        0xE5: "VAL",
        0xE6: "ASC",
        0xE7: "CHR$",
        0xE8: "LEFT$",
        0xE9: "RIGHT$",
        0xEA: "MID$"
    ]

    /// Detokenize an Applesoft BASIC program
    /// - Parameter data: Raw tokenized BASIC data
    /// - Returns: Human-readable BASIC listing
    static func detokenize(_ data: Data) -> String {
        guard data.count >= 2 else {
            return "// Invalid BASIC program (too short)"
        }

        var result = ""
        var pos = 0

        // Applesoft programs start with a 2-byte pointer to the next line
        // The actual program data follows
        while pos + 4 <= data.count {
            // Read next line pointer (2 bytes, little-endian)
            let nextLinePtrLow = Int(data[pos])
            let nextLinePtrHigh = Int(data[pos + 1])
            let nextLinePtr = nextLinePtrLow | (nextLinePtrHigh << 8)

            // End of program marker
            if nextLinePtr == 0 {
                break
            }

            pos += 2

            // Check if we have enough data for line number
            guard pos + 2 <= data.count else { break }

            // Read line number (2 bytes, little-endian)
            let lineNumLow = Int(data[pos])
            let lineNumHigh = Int(data[pos + 1])
            let lineNumber = lineNumLow | (lineNumHigh << 8)

            pos += 2

            // Format line number with padding
            result += String(format: "%5d ", lineNumber)

            // Process line content until null terminator
            var inQuote = false
            var inREM = false
            var inDATA = false

            while pos < data.count {
                let byte = data[pos]
                pos += 1

                // End of line
                if byte == 0x00 {
                    break
                }

                if inQuote {
                    // Inside quotes: treat all bytes as literal characters
                    if byte == 0x22 {  // End quote
                        inQuote = false
                        result += "\""
                    } else {
                        // Convert to printable ASCII
                        let printable = byte & 0x7F
                        if printable >= 0x20 && printable < 0x7F {
                            result += String(UnicodeScalar(printable))
                        } else {
                            result += "."
                        }
                    }
                } else if inREM {
                    // Inside REM: everything is literal until end of line
                    let printable = byte & 0x7F
                    if printable >= 0x20 && printable < 0x7F {
                        result += String(UnicodeScalar(printable))
                    } else if byte >= 0x80 {
                        // High-ASCII character
                        result += String(UnicodeScalar(printable))
                    } else {
                        result += "."
                    }
                } else if inDATA {
                    // Inside DATA: tokens are not expanded, but colons end DATA
                    if byte == 0x3A {  // Colon ends DATA statement
                        inDATA = false
                        result += ":"
                    } else if byte == 0x22 {
                        inQuote = true
                        result += "\""
                    } else {
                        let printable = byte & 0x7F
                        if printable >= 0x20 && printable < 0x7F {
                            result += String(UnicodeScalar(printable))
                        }
                    }
                } else if byte >= 0x80 {
                    // Token
                    if let token = tokens[byte] {
                        // Operators that need space before and after
                        let comparisonOps: Set<String> = ["=", "<", ">", "AND", "OR", "NOT"]

                        // Add space before token if needed
                        if let lastChar = result.last {
                            if comparisonOps.contains(token) {
                                // Always add space before comparison operators (unless already space)
                                if lastChar != " " && lastChar != "(" {
                                    result += " "
                                }
                            } else if (lastChar.isLetter || lastChar.isNumber) {
                                // Don't add space before math ops, parens, comma, semicolon
                                let noSpaceBefore: Set<String> = ["+", "-", "*", "/", "^", "(", ")", ",", ";"]
                                if !noSpaceBefore.contains(token) && !token.hasSuffix("(") && !token.hasSuffix("=") && !token.hasSuffix(":") {
                                    result += " "
                                }
                            }
                        }

                        result += token

                        // Add space after comparison operators
                        if comparisonOps.contains(token) {
                            result += " "
                        }

                        // Add space after certain statement tokens
                        let needsSpaceAfter: Set<String> = [
                            "GOTO", "GOSUB", "THEN", "IF", "FOR", "NEXT", "TO", "STEP",
                            "LET", "DIM", "DEF", "ON", "PRINT", "INPUT", "READ", "DATA",
                            "POKE", "CALL", "HTAB", "VTAB", "HCOLOR=", "COLOR=", "SPEED=",
                            "HPLOT", "PLOT", "DRAW", "XDRAW", "AT", "ONERR", "RESUME",
                            "HIMEM:", "LOMEM:", "WAIT", "GET", "HOME", "TEXT", "GR", "HGR", "HGR2",
                            "LOAD", "SAVE", "DEL", "RUN", "LIST", "ROT=", "SCALE=", "PR#", "IN#"
                        ]
                        if needsSpaceAfter.contains(token) {
                            result += " "
                        }
                        if token == "REM" {
                            inREM = true
                        } else if token == "DATA" {
                            inDATA = true
                        }
                    } else {
                        // Unknown token
                        result += "[?\(String(format: "%02X", byte))]"
                    }
                } else if byte == 0x22 {
                    // Start quote
                    inQuote = true
                    result += "\""
                } else if byte == 0x3A {
                    // Colon - statement separator, add spaces around it
                    result += " : "
                } else if byte >= 0x20 && byte < 0x7F {
                    // Regular printable ASCII
                    result += String(UnicodeScalar(byte))
                } else if byte == 0x0D {
                    // Carriage return (shouldn't appear but handle it)
                    result += "\n"
                }
            }

            result += "\n"
        }

        if result.isEmpty {
            return "// Unable to detokenize BASIC program"
        }

        return result
    }

    /// Check if data appears to be a valid Applesoft BASIC program
    /// - Parameter data: Data to check
    /// - Returns: true if it looks like Applesoft BASIC
    static func isValidBasicProgram(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }

        // First two bytes should be a valid pointer
        let nextLinePtr = Int(data[0]) | (Int(data[1]) << 8)

        // Should be a reasonable address (usually $0801 to $9600 range)
        if nextLinePtr < 0x0800 || nextLinePtr > 0xC000 {
            return false
        }

        // Line number should be reasonable (0-63999)
        let lineNumber = Int(data[2]) | (Int(data[3]) << 8)
        if lineNumber > 63999 {
            return false
        }

        return true
    }
}

/// Integer BASIC detokenizer (for type $FA files)
/// Based on CiderPress2 implementation by faddenSoft
class IntegerBasicDetokenizer {

    // Integer BASIC token table ($00-$7F)
    // Some tokens are invalid in programs but included for completeness
    static let tokens: [String] = [
        /*$00*/ "HIMEM:",   "",         "_ ",       ":",
                "LOAD ",    "SAVE ",    "CON ",     "RUN ",
        /*$08*/ "RUN ",     "DEL ",     ",",        "NEW ",
                "CLR ",     "AUTO ",    ",",        "MAN ",
        /*$10*/ "HIMEM:",   "LOMEM:",   "+",        "-",
                "*",        "/",        "=",        "#",
        /*$18*/ ">=",       ">",        "<=",       "<>",
                "<",        "AND ",     "OR ",      "MOD ",
        /*$20*/ "^ ",       "+",        "(",        ",",
                "THEN ",    "THEN ",    ",",        ",",
        /*$28*/ "\"",       "\"",       "(",        "!",
                "!",        "(",        "PEEK ",    "RND ",
        /*$30*/ "SGN ",     "ABS ",     "PDL ",     "RNDX ",
                "(",        "+",        "-",        "NOT ",
        /*$38*/ "(",        "=",        "#",        "LEN(",
                "ASC(",     "SCRN(",    ",",        "(",
        /*$40*/ "$",        "$",        "(",        ",",
                ",",        ";",        ";",        ";",
        /*$48*/ ",",        ",",        ",",        "TEXT ",
                "GR ",      "CALL ",    "DIM ",     "DIM ",
        /*$50*/ "TAB ",     "END ",     "INPUT ",   "INPUT ",
                "INPUT ",   "FOR ",     "=",        "TO ",
        /*$58*/ "STEP ",    "NEXT ",    ",",        "RETURN ",
                "GOSUB ",   "REM ",     "LET ",     "GOTO ",
        /*$60*/ "IF ",      "PRINT ",   "PRINT ",   "PRINT ",
                "POKE ",    ",",        "COLOR=",   "PLOT ",
        /*$68*/ ",",        "HLIN ",    ",",        "AT ",
                "VLIN ",    ",",        "AT ",      "VTAB ",
        /*$70*/ "=",        "=",        ")",        ")",
                "LIST ",    ",",        "LIST ",    "POP ",
        /*$78*/ "NODSP ",   "NODSP ",   "NOTRACE ", "DSP ",
                "DSP ",     "TRACE ",   "PR#",      "IN#"
    ]

    // Special token values
    private static let TOK_EOL: UInt8 = 0x01
    private static let TOK_COLON: UInt8 = 0x03
    private static let TOK_OPEN_QUOTE: UInt8 = 0x28
    private static let TOK_CLOSE_QUOTE: UInt8 = 0x29
    private static let TOK_REM: UInt8 = 0x5D

    /// Detokenize an Integer BASIC program
    /// - Parameter data: Raw tokenized Integer BASIC data
    /// - Returns: Human-readable BASIC listing
    static func detokenize(_ data: Data) -> String {
        // Minimum: length byte + line number (2) + EOL = 4 bytes
        guard data.count >= 4 else {
            return "// Invalid Integer BASIC program (too short)"
        }

        var result = ""
        var offset = 0
        let length = data.count

        while offset < length {
            // Check if we have enough for line header
            guard length - offset >= 3 else {
                break
            }

            let startOffset = offset

            // Get line length byte (includes itself)
            let lineLen = Int(data[offset])
            offset += 1

            // Zero length marks end of program
            if lineLen == 0 {
                break
            }

            // Check for truncation
            if startOffset + lineLen > length {
                result += "// Warning: File may be truncated\n"
                break
            }

            // Read 16-bit line number (little-endian)
            let lineNumLow = Int(data[offset])
            let lineNumHigh = Int(data[offset + 1])
            let lineNum = lineNumLow | (lineNumHigh << 8)
            offset += 2

            // Format line number with padding (like LIST command)
            result += String(format: "%5d ", lineNum)

            // Process line tokens
            var trailingSpace = true  // Line number ends with space
            var newTrailingSpace = false

            while offset < length && data[offset] != TOK_EOL {
                let curByte = data[offset]
                offset += 1

                if curByte == TOK_OPEN_QUOTE {
                    // Start of quoted text
                    result += "\""
                    while offset < length && data[offset] != TOK_CLOSE_QUOTE {
                        let charByte = data[offset] & 0x7F
                        if charByte >= 0x20 && charByte < 0x7F {
                            result += String(UnicodeScalar(charByte))
                        } else {
                            result += "."
                        }
                        offset += 1
                    }
                    if offset < length {
                        offset += 1  // Skip close quote token
                    }
                    result += "\""
                } else if curByte == TOK_REM {
                    // REM statement - consume to end of line
                    if !trailingSpace {
                        result += " "
                    }
                    result += tokens[Int(curByte)]
                    while offset < length && data[offset] != TOK_EOL {
                        let charByte = data[offset] & 0x7F
                        if charByte >= 0x20 && charByte < 0x7F {
                            result += String(UnicodeScalar(charByte))
                        } else {
                            result += "."
                        }
                        offset += 1
                    }
                } else if curByte >= 0xB0 && curByte <= 0xB9 {
                    // Integer constant ('0'-'9' with high bit set)
                    // Followed by 16-bit value
                    guard length - offset >= 2 else {
                        result += "??"
                        break
                    }
                    let valLow = Int(data[offset])
                    let valHigh = Int(data[offset + 1])
                    let value = valLow | (valHigh << 8)
                    offset += 2
                    result += String(value)
                } else if curByte >= 0xC1 && curByte <= 0xDA {
                    // Variable name ('A'-'Z' with high bit set)
                    result += String(UnicodeScalar(curByte & 0x7F))
                    // Continue with more variable name characters
                    while offset < length {
                        let nextByte = data[offset]
                        if (nextByte >= 0xC1 && nextByte <= 0xDA) ||
                           (nextByte >= 0xB0 && nextByte <= 0xB9) {
                            result += String(UnicodeScalar(nextByte & 0x7F))
                            offset += 1
                        } else {
                            break  // End of variable name (hit a token)
                        }
                    }
                } else if curByte < 0x80 {
                    // Language token
                    let tokStr = tokens[Int(curByte)]

                    // Check if we need a leading space
                    if !tokStr.isEmpty {
                        let firstChar = tokStr.first!
                        // Punctuation and special chars don't need leading space
                        if firstChar >= "!" && firstChar <= "?" || curByte < 0x12 {
                            // No leading space needed
                        } else if !trailingSpace {
                            result += " "
                        }

                        result += tokStr

                        // Track trailing space
                        if tokStr.last == " " {
                            newTrailingSpace = true
                        }
                    }
                }
                // Bytes >= $80 that aren't handled above are invalid

                trailingSpace = newTrailingSpace
                newTrailingSpace = false
            }

            // Skip the EOL token
            if offset < length && data[offset] == TOK_EOL {
                offset += 1
            }

            result += "\n"

            // Verify line length matches
            if offset - startOffset != lineLen {
                // Length mismatch - file may be corrupt, but continue
            }
        }

        if result.isEmpty {
            return "// Unable to detokenize Integer BASIC program"
        }

        return result
    }

    /// Check if data appears to be a valid Integer BASIC program
    /// - Parameter data: Data to check
    /// - Returns: true if it looks like Integer BASIC
    static func isValidBasicProgram(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }

        // First byte is line length
        let lineLen = Int(data[0])
        if lineLen < 4 || lineLen > data.count {
            return false
        }

        // Check that last byte of first line is EOL token ($01)
        if data[lineLen - 1] != TOK_EOL {
            return false
        }

        // Line number should be reasonable (0-32767)
        let lineNumber = Int(data[1]) | (Int(data[2]) << 8)
        if lineNumber > 32767 {
            return false
        }

        return true
    }
}
