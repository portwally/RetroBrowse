//
//  SheetSizing.swift
//  ProBrowse
//
//  When a sheet would reach below the bottom of the screen (or behind the Dock), macOS
//  moves the whole window up to make room, and the window jumps every time the sheet
//  opens. Sheets take at most the space they have where macOS puts them: centred on the
//  window from macOS 26 on, hanging from the title bar before that.
//

import AppKit
import SwiftUI

extension View {
    /// A fixed width, and `height` or less: as much as fits without the main window moving
    func sheetFrame(width: CGFloat, height: CGFloat, minimumHeight: CGFloat = 360) -> some View {
        frame(width: width, height: SheetSizing.fittingHeight(height, minimum: minimumHeight))
    }
}

enum SheetSizing {
    static func fittingHeight(_ preferred: CGFloat, minimum: CGFloat) -> CGFloat {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow,
              let screen = window.screen ?? NSScreen.main else { return preferred }
        let visible = screen.visibleFrame
        let margin: CGFloat = 12
        let available: CGFloat
        if #available(macOS 26, *) {
            // Centred on the window: as much above the centre as below it
            let centre = window.frame.midY
            available = 2 * min(centre - visible.minY, visible.maxY - centre) - 2 * margin
        } else {
            // Hanging from the bottom of the title bar and toolbar (screen coordinates)
            let sheetTop = window.frame.minY + window.contentLayoutRect.maxY
            available = sheetTop - visible.minY - margin
        }
        return max(minimum, min(preferred, available))
    }
}
