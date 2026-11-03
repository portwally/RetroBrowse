//
//  CatalogEntryRow.swift
//  ProBrowse
//
//  Row view for catalog entries with checkbox and hierarchy support
//

import SwiftUI

struct CatalogEntryRow: View {
    let entry: DiskCatalogEntry
    let isSelected: (DiskCatalogEntry) -> Bool
    let onToggle: (DiskCatalogEntry, Bool, Bool) -> Void
    let onDoubleClick: ((DiskCatalogEntry) -> Void)?
    let onRename: ((DiskCatalogEntry) -> Void)?
    let onGetInfo: ((DiskCatalogEntry) -> Void)?
    let onChangeFileType: ((DiskCatalogEntry) -> Void)?
    let onInspect: ((DiskCatalogEntry) -> Void)?
    let onCopy: ((DiskCatalogEntry) -> Void)?
    let onCut: ((DiskCatalogEntry) -> Void)?
    let onPaste: (() -> Void)?
    let onExport: ((DiskCatalogEntry) -> Void)?
    let onDelete: ((DiskCatalogEntry) -> Void)?
    let dragProvider: ((DiskCatalogEntry) -> NSItemProvider)?
    let level: Int
    let expansion: ExpansionCommand
    @ObservedObject var columnWidths: ColumnWidths
    
    @State private var isExpanded: Bool
    
    init(entry: DiskCatalogEntry, isSelected: @escaping (DiskCatalogEntry) -> Bool, onToggle: @escaping (DiskCatalogEntry, Bool, Bool) -> Void, onDoubleClick: ((DiskCatalogEntry) -> Void)? = nil, onRename: ((DiskCatalogEntry) -> Void)? = nil, onGetInfo: ((DiskCatalogEntry) -> Void)? = nil, onChangeFileType: ((DiskCatalogEntry) -> Void)? = nil, onInspect: ((DiskCatalogEntry) -> Void)? = nil, onCopy: ((DiskCatalogEntry) -> Void)? = nil, onCut: ((DiskCatalogEntry) -> Void)? = nil, onPaste: (() -> Void)? = nil, onExport: ((DiskCatalogEntry) -> Void)? = nil, onDelete: ((DiskCatalogEntry) -> Void)? = nil, dragProvider: ((DiskCatalogEntry) -> NSItemProvider)? = nil, level: Int, expansion: ExpansionCommand, columnWidths: ColumnWidths) {
        self.entry = entry
        self.isSelected = isSelected
        self.onToggle = onToggle
        self.onDoubleClick = onDoubleClick
        self.onRename = onRename
        self.onGetInfo = onGetInfo
        self.onChangeFileType = onChangeFileType
        self.onInspect = onInspect
        self.onCopy = onCopy
        self.onCut = onCut
        self.onPaste = onPaste
        self.onExport = onExport
        self.onDelete = onDelete
        self.dragProvider = dragProvider
        self.level = level
        self.expansion = expansion
        self.columnWidths = columnWidths
        // Folders that appear after Expand All (inside an expanded folder) open too
        _isExpanded = State(initialValue: expansion.expand)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Main Row with columns
            CatalogEntryRowContent(
                entry: entry,
                isSelected: isSelected(entry),
                isExpanded: $isExpanded,
                level: level,
                onToggle: onToggle,
                onDoubleClick: onDoubleClick,
                onRename: onRename,
                onGetInfo: onGetInfo,
                onChangeFileType: onChangeFileType,
                onInspect: onInspect,
                onCopy: onCopy,
                onCut: onCut,
                onPaste: onPaste,
                onExport: onExport,
                onDelete: onDelete,
                columnWidths: columnWidths
            )
            // Each row is its own drag source, so the drag image is this row
            // and not the folder with everything shown inside it
            .onDrag {
                dragProvider?(entry) ?? NSItemProvider()
            }
            
            // Children (if expanded)
            if isExpanded, let children = entry.children, !children.isEmpty {
                ForEach(children) { child in
                    CatalogEntryRow(
                        entry: child,
                        isSelected: isSelected,
                        onToggle: onToggle,
                        onDoubleClick: onDoubleClick,
                        onRename: onRename,
                        onGetInfo: onGetInfo,
                        onChangeFileType: onChangeFileType,
                        onInspect: onInspect,
                        onCopy: onCopy,
                        onCut: onCut,
                        onPaste: onPaste,
                        onExport: onExport,
                        onDelete: onDelete,
                        dragProvider: dragProvider,
                        level: level + 1,
                        expansion: expansion,
                        columnWidths: columnWidths
                    )
                }
            }
        }
        .onChange(of: expansion) { _, command in
            if entry.isDirectory {
                isExpanded = command.expand
            }
        }
    }
}

// MARK: - Catalog Entry Row Content

struct CatalogEntryRowContent: View {
    let entry: DiskCatalogEntry
    let isSelected: Bool
    @Binding var isExpanded: Bool
    let level: Int
    let onToggle: (DiskCatalogEntry, Bool, Bool) -> Void
    let onDoubleClick: ((DiskCatalogEntry) -> Void)?
    let onRename: ((DiskCatalogEntry) -> Void)?
    let onGetInfo: ((DiskCatalogEntry) -> Void)?
    let onChangeFileType: ((DiskCatalogEntry) -> Void)?
    let onInspect: ((DiskCatalogEntry) -> Void)?
    let onCopy: ((DiskCatalogEntry) -> Void)?
    let onCut: ((DiskCatalogEntry) -> Void)?
    let onPaste: (() -> Void)?
    let onExport: ((DiskCatalogEntry) -> Void)?
    let onDelete: ((DiskCatalogEntry) -> Void)?
    @ObservedObject var columnWidths: ColumnWidths
    @Environment(\.skin) private var skin

    /// Text colour for this row in the current skin
    private var textColor: Color {
        if isSelected && skin.isRetro { return skin.selectionText }
        return entry.isDirectory ? skin.folderText : skin.fileText
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                (isSelected ? skin.selectionBackground : Color.clear)
                
                HStack(spacing: 0) {
                    // Name Column (with indentation and expand button)
                    HStack(spacing: 4) {
                        // Padding at start
                        Spacer().frame(width: 8)
                        
                        // Indentation
                        if level > 0 {
                            Spacer()
                                .frame(width: CGFloat(level * 16))
                        }
                        
                        // Expand/Collapse for ALL directories (even empty ones)
                        if entry.isDirectory {
                            Button(action: { isExpanded.toggle() }) {
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10))
                                    .foregroundColor(skin.isRetro ? textColor : .secondary)
                                    .frame(width: 16, height: 16)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        } else {
                            Spacer().frame(width: 16)
                        }
                        
                        Text(entry.icon)
                            .font(.body)
                        
                        Text(entry.isLocked ? entry.name + " 🔒" : entry.name)
                            .font(skin.isRetro ? skin.font(13) : .body)
                            .lineLimit(1)
                            .fontWeight(entry.isDirectory && !skin.isRetro ? .semibold : .regular)
                        
                        Spacer(minLength: 0)
                    }
                    .frame(width: columnWidths.nameWidth, alignment: .leading)
                    
                    Divider().frame(width: 1).opacity(skin.isRetro ? 0 : 0.3).background(skin.isRetro ? skin.lines : .clear)
                    
                    // Type Column
                    HStack(spacing: 0) {
                        Spacer().frame(width: 8)
                        Text(entry.fileTypeString)
                            .font(skin.isRetro ? skin.font(11) : .caption)
                        Spacer(minLength: 0)
                    }
                    .frame(width: columnWidths.typeWidth, alignment: .leading)
                    
                    Divider().frame(width: 1).opacity(skin.isRetro ? 0 : 0.3).background(skin.isRetro ? skin.lines : .clear)
                    
                    // Aux Column
                    HStack(spacing: 0) {
                        Spacer().frame(width: 8)
                        Text(String(format: "$%04X", entry.auxType))
                            .font(skin.isRetro ? skin.font(11) : .caption)
                            .monospacedDigit()
                        Spacer(minLength: 0)
                    }
                    .frame(width: columnWidths.auxWidth, alignment: .leading)
                    
                    Divider().frame(width: 1).opacity(skin.isRetro ? 0 : 0.3).background(skin.isRetro ? skin.lines : .clear)
                    
                    // Size Column (in bytes)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Text("\(entry.size)")
                            .font(skin.isRetro ? skin.font(11) : .caption)
                            .monospacedDigit()
                        Spacer().frame(width: 8)
                    }
                    .frame(width: columnWidths.sizeWidth, alignment: .trailing)
                    
                    Divider().frame(width: 1).opacity(skin.isRetro ? 0 : 0.3).background(skin.isRetro ? skin.lines : .clear)
                    
                    // Modified Column
                    HStack(spacing: 0) {
                        Spacer().frame(width: 8)
                        Text(entry.modificationDate ?? "—")
                            .font(skin.isRetro ? skin.font(11) : .caption)
                        Spacer(minLength: 0)
                    }
                    .frame(width: columnWidths.modifiedWidth, alignment: .leading)
                    
                    Divider().frame(width: 1).opacity(skin.isRetro ? 0 : 0.3).background(skin.isRetro ? skin.lines : .clear)
                    
                    // Created Column
                    HStack(spacing: 0) {
                        Spacer().frame(width: 8)
                        Text(entry.creationDate ?? "—")
                            .font(skin.isRetro ? skin.font(11) : .caption)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Retro skins colour the whole row; the macOS skins keep the system text colour
                .foregroundColor(skin.isRetro ? textColor : nil)
            }
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .contextMenu {
            // Copy/Cut/Paste
            Button("Copy") {
                if let onCopy = onCopy {
                    onCopy(entry)
                }
            }
            .keyboardShortcut("c", modifiers: .command)
            
            Button("Cut") {
                if let onCut = onCut {
                    onCut(entry)
                }
            }
            .keyboardShortcut("x", modifiers: .command)
            
            Button("Paste") {
                if let onPaste = onPaste {
                    onPaste()
                }
            }
            .keyboardShortcut("v", modifiers: .command)
            
            Divider()
            
            // Export & Delete
            Button("Export to Finder...") {
                if let onExport = onExport {
                    onExport(entry)
                }
            }
            
            Button("Delete") {
                if let onDelete = onDelete {
                    onDelete(entry)
                }
            }
            .keyboardShortcut(.delete, modifiers: [])
            
            Divider()
            
            // Rename & Info
            Button("Rename") {
                if let onRename = onRename {
                    onRename(entry)
                }
            }
            
            Button("Get Info") {
                if let onGetInfo = onGetInfo {
                    onGetInfo(entry)
                }
            }
            .keyboardShortcut("i", modifiers: .command)

            if !entry.isDirectory {
                Button("Change File Type...") {
                    if let onChangeFileType = onChangeFileType {
                        onChangeFileType(entry)
                    }
                }

                Button("Inspect File...") {
                    if let onInspect = onInspect {
                        onInspect(entry)
                    }
                }
            }
        }
        .onTapGesture(count: 2) {
            // Double-click: navigate into directory
            if entry.isDirectory, let onDoubleClick = onDoubleClick {
                print("🖱️ Double-click on directory: \(entry.name)")
                onDoubleClick(entry)
            }
        }
        .onTapGesture {
            let event = NSApp.currentEvent
            let commandPressed = event?.modifierFlags.contains(.command) ?? false
            let shiftPressed = event?.modifierFlags.contains(.shift) ?? false
            
            print("🔘 Toggle selection for: \(entry.name)")
            print("   Current selected count: \(isSelected ? 1 : 0)")
            print("   Command: \(commandPressed), Shift: \(shiftPressed)")
            
            onToggle(entry, commandPressed, shiftPressed)
        }
    }
}
