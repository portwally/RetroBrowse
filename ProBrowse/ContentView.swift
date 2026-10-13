//
//  ContentView.swift
//  ProBrowse
//
//  Apple IIgs Disk Image Browser with Dual Pane View
//

import SwiftUI
import UniformTypeIdentifiers
import Combine

struct ContentView: View {
    @StateObject private var leftPaneVM = DiskPaneViewModel()
    @StateObject private var rightPaneVM = DiskPaneViewModel()
    @State private var showingCreateImageSheet = false
    @State private var inspectorPane: PaneLocation? = nil
    @State private var keyboardMonitor: Any? = nil
    @State private var hostWindow: NSWindow? = nil
    
    enum PaneLocation: Identifiable {
        case left, right
        
        var id: Self { self }
    }
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Toolbar
                ToolbarView(
                    onOpenLeft: { leftPaneVM.showingFilePicker = true },
                    onOpenRight: { rightPaneVM.showingFilePicker = true },
                    onCreate: { showingCreateImageSheet = true },
                    onDeleteLeft: { leftPaneVM.deleteSelected() },
                    onDeleteRight: { rightPaneVM.deleteSelected() },
                    onExportLeft: { leftPaneVM.exportSelectedToFinder() },
                    onExportRight: { rightPaneVM.exportSelectedToFinder() },
                    onCreateDirLeft: { leftPaneVM.showCreateDirectoryDialog() },
                    onCreateDirRight: { rightPaneVM.showCreateDirectoryDialog() },
                    onEjectLeft: { leftPaneVM.ejectDisk() },
                    onEjectRight: { rightPaneVM.ejectDisk() },
                    onInspectLeft: { leftPaneVM.inspectSelectedFile() },
                    onInspectRight: { rightPaneVM.inspectSelectedFile() },
                    leftSelectionCount: leftPaneVM.selectedEntries.count,
                    rightSelectionCount: rightPaneVM.selectedEntries.count,
                    leftHasDisk: leftPaneVM.catalog != nil,
                    rightHasDisk: rightPaneVM.catalog != nil,
                    canInspectLeft: leftPaneVM.canInspect,
                    canInspectRight: rightPaneVM.canInspect
                )
                
                Divider()
                
                // Dual Pane Browser
                HStack(spacing: 0) {
                    // Left Pane
                    DiskBrowserPane(
                        viewModel: leftPaneVM,
                        targetViewModel: rightPaneVM,
                        columnWidths: ColumnWidths.leftPane,
                        paneTitle: "Left Disk",
                        paneId: .left
                    )
                    .frame(minWidth: 400)
                    
                    Divider()
                    
                    // Right Pane
                    DiskBrowserPane(
                        viewModel: rightPaneVM,
                        targetViewModel: leftPaneVM,
                        columnWidths: ColumnWidths.rightPane,
                        paneTitle: "Right Disk",
                        paneId: .right
                    )
                    .frame(minWidth: 400)
                }
            }
            .overlay(
                // Vertical divider in toolbar aligned with browser divider
                Divider()
                    .frame(width: 1)
                    .offset(x: geometry.size.width / 2, y: 30) // Center, toolbar height/2
                    .frame(height: 60)
                , alignment: .topLeading
            )
        }
        .sheet(isPresented: $showingCreateImageSheet) {
            CreateImageSheet()
        }
        .sheet(item: $inspectorPane) { pane in
            ImageInspectorSheet(viewModel: pane == .left ? leftPaneVM : rightPaneVM)
        }
        .background(WindowReader { window in
            if hostWindow !== window { hostWindow = window }
        })
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.createDiskImage)) { _ in
            showingCreateImageSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDiskImage)) { notification in
            if notification.object as? PaneIdentifier == .right {
                rightPaneVM.showingFilePicker = true
            } else {
                leftPaneVM.showingFilePicker = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDiskImageInfo)) { _ in
            inspectorPane = FocusManager.shared.activePaneId == .left ? .left : .right
        }
        .onDisappear {
            if let monitor = keyboardMonitor {
                NSEvent.removeMonitor(monitor)
                keyboardMonitor = nil
            }
        }
        .onAppear {
            // Guard against duplicate registration
            if keyboardMonitor != nil { return }
            // Setup keyboard shortcuts
            keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Leave the keys alone while a sheet, alert or other window (Help) is in front,
                // or while text is being edited, so they keep their normal meaning there
                guard let window = event.window, window === hostWindow,
                      window.sheetParent == nil, window.attachedSheet == nil,
                      NSApp.modalWindow == nil,
                      !(window.firstResponder is NSText) else {
                    return event
                }
                
                let activeVM = FocusManager.shared.activePaneId == .left ? leftPaneVM : rightPaneVM
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                
                // Delete and forward delete remove the selection (after confirmation)
                if modifiers.isEmpty && (event.keyCode == 51 || event.keyCode == 117) && !activeVM.selectedEntries.isEmpty {
                    activeVM.deleteSelected()
                    return nil
                }
                
                if modifiers == .command {
                    switch event.charactersIgnoringModifiers {
                    case "c":
                        activeVM.copySelected()
                        return nil
                    case "x":
                        activeVM.cutSelected()
                        return nil
                    case "v":
                        activeVM.pasteClipboard()
                        return nil
                    case "i":
                        activeVM.inspectSelectedFile()
                        return nil
                    default:
                        break
                    }
                }
                return event
            }
        }
    }
}

// MARK: - Window Reader

/// Reports the window that hosts a view
private struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onChange(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onChange(nsView.window) }
    }
}

// MARK: - Toolbar View

struct ToolbarView: View {
    let onOpenLeft: () -> Void
    let onOpenRight: () -> Void
    let onCreate: () -> Void
    let onDeleteLeft: () -> Void
    let onDeleteRight: () -> Void
    let onExportLeft: () -> Void
    let onExportRight: () -> Void
    let onCreateDirLeft: () -> Void
    let onCreateDirRight: () -> Void
    let onEjectLeft: () -> Void
    let onEjectRight: () -> Void
    let onInspectLeft: () -> Void
    let onInspectRight: () -> Void
    let leftSelectionCount: Int
    let rightSelectionCount: Int
    let leftHasDisk: Bool
    let rightHasDisk: Bool
    let canInspectLeft: Bool
    let canInspectRight: Bool
    
    var body: some View {
        HStack(spacing: 0) {
            // Left Pane Controls
            HStack(spacing: 16) {
                ToolbarButton(
                    icon: "folder.badge.plus",
                    label: "Open Left",
                    action: onOpenLeft
                )
                .help("Open disk image in left pane (⌘O)")
                
                ToolbarButton(
                    icon: "eject",
                    label: "Eject",
                    action: onEjectLeft,
                    disabled: !leftHasDisk
                )
                .help("Eject disk image from left pane")
                
                ToolbarButton(
                    icon: "plus.square.on.square",
                    label: "New Folder",
                    action: onCreateDirLeft
                )
                .help("Create new directory")
                
                ToolbarButton(
                    icon: "trash",
                    label: "Delete",
                    action: onDeleteLeft,
                    disabled: leftSelectionCount == 0,
                    destructive: true
                )
                .help("Delete selected files (⌫)")
                
                ToolbarButton(
                    icon: "square.and.arrow.up",
                    label: "Export",
                    action: onExportLeft,
                    disabled: leftSelectionCount == 0
                )
                .help("Export selected files to Finder")

                ToolbarButton(
                    icon: "doc.text.magnifyingglass",
                    label: "Inspect",
                    action: onInspectLeft,
                    disabled: !canInspectLeft
                )
                .help("Inspect selected file (⌘I)")

                if leftSelectionCount > 0 {
                    Text("\(leftSelectionCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                }
            }
            .padding(.leading, 16)
            
            Spacer()
            
            // Global Controls (centered)
            ToolbarButton(
                icon: "doc.badge.plus",
                label: "Create Image",
                action: onCreate
            )
            .help("Create new disk image (⌘N)")
            
            Spacer()
            
            // Right Pane Controls
            HStack(spacing: 16) {
                if rightSelectionCount > 0 {
                    Text("\(rightSelectionCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 4)
                }

                ToolbarButton(
                    icon: "doc.text.magnifyingglass",
                    label: "Inspect",
                    action: onInspectRight,
                    disabled: !canInspectRight
                )
                .help("Inspect selected file (⌘I)")

                ToolbarButton(
                    icon: "square.and.arrow.up",
                    label: "Export",
                    action: onExportRight,
                    disabled: rightSelectionCount == 0
                )
                .help("Export selected files to Finder")
                
                ToolbarButton(
                    icon: "trash",
                    label: "Delete",
                    action: onDeleteRight,
                    disabled: rightSelectionCount == 0,
                    destructive: true
                )
                .help("Delete selected files (⌫)")
                
                ToolbarButton(
                    icon: "plus.square.on.square",
                    label: "New Folder",
                    action: onCreateDirRight
                )
                .help("Create new directory")
                
                ToolbarButton(
                    icon: "eject",
                    label: "Eject",
                    action: onEjectRight,
                    disabled: !rightHasDisk
                )
                .help("Eject disk image from right pane")
                
                ToolbarButton(
                    icon: "folder.badge.plus",
                    label: "Open Right",
                    action: onOpenRight
                )
                .help("Open disk image in right pane (⌘⇧O)")
            }
            .padding(.trailing, 16)
        }
        .frame(height: 60) // Compact height
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Toolbar Button Component

struct ToolbarButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var disabled: Bool = false
    var destructive: Bool = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .frame(height: 20)
                
                Text(label)
                    .font(.system(size: 9))
            }
            .frame(width: 60)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .foregroundColor(
            disabled ? .secondary : (destructive ? .red : .primary)
        )
    }
}

#Preview {
    ContentView()
        .frame(width: 1200, height: 800)
}
