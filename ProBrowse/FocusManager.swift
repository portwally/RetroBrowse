//
//  FocusManager.swift
//  ProBrowse
//
//  Manages which pane is currently active/focused
//

import SwiftUI
import Combine

enum PaneIdentifier {
    case left
    case right
}

enum ClipboardOperation {
    case copy
    case cut
}

class FocusManager: ObservableObject {
    @Published var activePaneId: PaneIdentifier = .left
    
    // Shared clipboard
    var clipboardEntries: [DiskCatalogEntry] = []
    var clipboardOperation: ClipboardOperation = .copy
    var clipboardSourcePath: URL?
    var clipboardSourceIsDOS33 = false
    weak var clipboardSourceVM: DiskPaneViewModel?
    
    static let shared = FocusManager()
    
    private init() {}
    
    func setActivePane(_ paneId: PaneIdentifier) {
        activePaneId = paneId
        print("🎯 Active pane: \(paneId)")
    }
    
    func isActive(_ paneId: PaneIdentifier) -> Bool {
        return activePaneId == paneId
    }
    
    func copyToClipboard(entries: [DiskCatalogEntry], operation: ClipboardOperation, sourcePath: URL, source: DiskPaneViewModel) {
        clipboardEntries = entries
        clipboardOperation = operation
        clipboardSourcePath = sourcePath
        clipboardSourceIsDOS33 = source.isDOS33
        clipboardSourceVM = source
        print("📋 Clipboard: \(entries.count) items (\(operation))")
    }
    
    func clearClipboard() {
        clipboardEntries.removeAll()
        clipboardSourcePath = nil
        clipboardSourceVM = nil
        print("🗑️ Clipboard cleared")
    }
    
    func hasClipboard() -> Bool {
        return !clipboardEntries.isEmpty
    }
}
