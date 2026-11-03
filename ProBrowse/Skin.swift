//
//  Skin.swift
//  ProBrowse
//
//  Window skins: follow the system, light, dark, or Norton Commander.
//  The Norton Commander skin uses the Modern DOS 9x16 font (CC0, see
//  Fonts/ModernDOS-LICENSE.txt) and the 16-colour CGA/VGA text-mode palette.
//

import SwiftUI
import AppKit
import CoreText

enum Skin: String, CaseIterable, Identifiable {
    case system, light, dark, norton

    static let storageKey = "skin"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .norton: return "Norton Commander"
        }
    }

    /// Appearance for the whole app; Norton Commander pairs its blue panes with dark sheets and menus
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark, .norton: return NSAppearance(named: .darkAqua)
        }
    }

    var isNorton: Bool { self == .norton }

    // MARK: Colours

    // CGA/VGA text-mode palette
    private static let dosBlue = Color(red: 0, green: 0, blue: 0xAA / 255)
    private static let dosCyan = Color(red: 0, green: 0xAA / 255, blue: 0xAA / 255)
    private static let dosLightCyan = Color(red: 0x55 / 255, green: 1, blue: 1)
    private static let dosYellow = Color(red: 1, green: 1, blue: 0x55 / 255)

    /// Background of the file lists
    var paneBackground: Color { isNorton ? Skin.dosBlue : .clear }
    /// Background of the volume line and column headers
    var headerBackground: Color { isNorton ? Skin.dosBlue : Color(NSColor.controlBackgroundColor) }
    var toolbarBackground: Color { isNorton ? Skin.dosCyan : Color(NSColor.controlBackgroundColor) }
    var toolbarForeground: Color { isNorton ? .black : .primary }

    var fileText: Color { isNorton ? Skin.dosLightCyan : .primary }
    var folderText: Color { isNorton ? .white : .primary }
    var secondaryText: Color { isNorton ? Skin.dosLightCyan : .secondary }
    var columnHeaderText: Color { isNorton ? Skin.dosYellow : .secondary }
    var selectionBackground: Color { isNorton ? Skin.dosCyan : Color.accentColor.opacity(0.3) }
    var selectionText: Color { isNorton ? .black : .primary }
    var lines: Color { isNorton ? Skin.dosLightCyan.opacity(0.7) : Color.secondary.opacity(0.3) }

    // MARK: Fonts

    static let dosFontName = "ModernDOS9x16"

    /// The DOS font in Norton Commander, otherwise the system font at `size`
    func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        isNorton ? .custom(Skin.dosFontName, fixedSize: 16) : .system(size: size, weight: weight)
    }

    /// Registers the bundled DOS font for this process
    static func registerFonts() {
        guard let url = Bundle.main.url(forResource: "ModernDOS9x16", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
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
