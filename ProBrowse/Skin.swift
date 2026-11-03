//
//  Skin.swift
//  ProBrowse
//
//  Window skins: follow the system, light, dark, Norton Commander, or the Apple IIGS
//  Finder in 640 mode.
//  - Norton Commander: Modern DOS 9x16 font (CC0, Fonts/ModernDOS-LICENSE.txt) and the
//    16-colour CGA/VGA text-mode palette.
//  - Apple IIGS 640: Shaston 640 font by Kreative Software (Relay Fonts Free Use License,
//    Fonts/Shaston-LICENSE.txt), black on white with the yellow GS/OS Finder highlight.
//

import SwiftUI
import AppKit
import CoreText

enum Skin: String, CaseIterable, Identifiable {
    case system, light, dark, norton, iigs

    static let storageKey = "skin"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .norton: return "Norton Commander"
        case .iigs: return "Apple IIGS 640"
        }
    }

    /// Appearance for the whole app, so sheets and menus suit the skin
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light, .iigs: return NSAppearance(named: .aqua)
        case .dark, .norton: return NSAppearance(named: .darkAqua)
        }
    }

    var isNorton: Bool { self == .norton }
    /// Skins with their own font and colours; System, Light and Dark use the macOS look
    var isRetro: Bool { self == .norton || self == .iigs }

    // MARK: Colours

    // CGA/VGA text-mode palette
    private static let dosBlue = Color(red: 0, green: 0, blue: 0xAA / 255)
    private static let dosCyan = Color(red: 0, green: 0xAA / 255, blue: 0xAA / 255)
    private static let dosLightCyan = Color(red: 0x55 / 255, green: 1, blue: 1)
    private static let dosYellow = Color(red: 1, green: 1, blue: 0x55 / 255)
    // GS/OS Finder desktop blue and the yellow of its selection highlight
    private static let gsBlue = Color(red: 0x55 / 255, green: 0x99 / 255, blue: 1)
    private static let gsYellow = Color(red: 1, green: 1, blue: 0)

    /// Background of the file lists
    var paneBackground: Color {
        switch self {
        case .norton: return Skin.dosBlue
        case .iigs: return .white
        default: return .clear
        }
    }
    /// Background of the volume line and column headers
    var headerBackground: Color {
        switch self {
        case .norton: return Skin.dosBlue
        case .iigs: return .white
        default: return Color(NSColor.controlBackgroundColor)
        }
    }
    var toolbarBackground: Color {
        switch self {
        case .norton: return Skin.dosCyan
        case .iigs: return Skin.gsBlue
        default: return Color(NSColor.controlBackgroundColor)
        }
    }
    var toolbarForeground: Color { isRetro ? .black : .primary }

    var fileText: Color {
        switch self {
        case .norton: return Skin.dosLightCyan
        case .iigs: return .black
        default: return .primary
        }
    }
    var folderText: Color {
        switch self {
        case .norton: return .white
        case .iigs: return .black
        default: return .primary
        }
    }
    var secondaryText: Color {
        switch self {
        case .norton: return Skin.dosLightCyan
        case .iigs: return .black
        default: return .secondary
        }
    }
    var columnHeaderText: Color {
        switch self {
        case .norton: return Skin.dosYellow
        case .iigs: return .black
        default: return .secondary
        }
    }
    var selectionBackground: Color {
        switch self {
        case .norton: return Skin.dosCyan
        case .iigs: return Skin.gsYellow
        default: return Color.accentColor.opacity(0.3)
        }
    }
    var selectionText: Color {
        switch self {
        case .norton, .iigs: return .black
        default: return .primary
        }
    }
    var lines: Color {
        switch self {
        case .norton: return Skin.dosLightCyan.opacity(0.7)
        case .iigs: return .black
        default: return Color.secondary.opacity(0.3)
        }
    }

    // MARK: Fonts

    static let dosFontName = "ModernDOS9x16"
    static let shastonFontName = "Shaston640"

    /// The skin's own font, otherwise the system font at `size`
    func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch self {
        case .norton: return .custom(Skin.dosFontName, fixedSize: 16)
        case .iigs: return .custom(Skin.shastonFontName, fixedSize: 16)
        default: return .system(size: size, weight: weight)
        }
    }

    /// Registers the bundled fonts for this process
    static func registerFonts() {
        for name in [dosFontName, shastonFontName] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

private struct SkinKey: EnvironmentKey {
    static let defaultValue: Skin = .system
}

extension EnvironmentValues {
    var skin: Skin {
        get { self[SkinKey.self] }
        set { self[SkinKey.self] = newValue }
    }
}
