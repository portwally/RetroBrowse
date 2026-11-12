//
//  SheetSizing.swift
//  ProBrowse
//
//  A sheet hangs from the bottom of the window's title bar. When it is taller than the
//  space from there to the bottom of the screen, macOS moves the whole window up to make
//  room, and the window jumps every time the sheet opens. Sheets take at most that space.
//

import AppKit
import SwiftUI

extension View {
    /// A fixed width, and `height` or less: as much as fits below the main window's title bar
    func sheetFrame(width: CGFloat, height: CGFloat, minimumHeight: CGFloat = 360) -> some View {
        frame(width: width, height: SheetSizing.fittingHeight(height, minimum: minimumHeight))
    }
}

enum SheetSizing {
    static func fittingHeight(_ preferred: CGFloat, minimum: CGFloat) -> CGFloat {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow,
              let screen = window.screen ?? NSScreen.main else { return preferred }
        // Where the sheet starts (bottom of title bar and toolbar), in screen coordinates
        let sheetTop = window.frame.minY + window.contentLayoutRect.maxY
        let available = sheetTop - screen.visibleFrame.minY - 8
        return max(minimum, min(preferred, available))
    }
}
