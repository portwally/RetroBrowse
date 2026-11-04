//
//  DiskBrowserPane.swift
//  ProBrowse
//
//  Individual disk browser pane with drag & drop support
//

import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit

struct DiskBrowserPane: View {
    @ObservedObject var viewModel: DiskPaneViewModel
    @ObservedObject var targetViewModel: DiskPaneViewModel
    @ObservedObject var columnWidths: ColumnWidths
    let paneTitle: String
    let paneId: PaneIdentifier
    var hideHeader: Bool = false
    
    @State private var isTargeted = false
    @StateObject private var focusManager = FocusManager.shared
    @Environment(\.skin) private var skin
    
    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isPreviewing {
                // Shows the file highlighted in the other pane; this pane's disk stays open
                PreviewPaneView(source: targetViewModel)
            } else {
                // Header
                if !hideHeader {
                    headerView
                }
                
                // Browser Content
                if let catalog = viewModel.catalog {
                    browserContentView(catalog: catalog)
                } else {
                    emptyStateView
                }
            }
        }
        // The whole pane takes the click, empty space below the file list included
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(skin.paneBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            // Set this pane as active when clicked. A preview never takes over: the other
            // pane would lose its selection and with it the file being previewed.
            if !viewModel.isPreviewing {
                focusManager.setActivePane(paneId)
            }
        }
        .onChange(of: focusManager.activePaneId) { oldValue, newValue in
            // Clear selection when this pane loses focus
            if newValue != paneId && !viewModel.selectedEntries.isEmpty {
                print("🔄 Clearing selection in inactive \(paneId) pane")
                viewModel.selectedEntries.removeAll()
            }
        }
        .fileImporter(
            isPresented: $viewModel.showingFilePicker,
            allowedContentTypes: DiskPaneViewModel.openableExtensions.map { UTType(filenameExtension: $0) ?? .data },
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    viewModel.loadDiskImage(from: url)
                }
            case .failure(let error):
                print("Error selecting file: \(error)")
            }
        }
        .sheet(isPresented: $viewModel.showingFileInfo) {
            if let entry = viewModel.fileInfoEntry {
                FileInfoSheet(entry: entry)
            }
        }
        .sheet(isPresented: $viewModel.showingChangeFileType) {
            if let entry = viewModel.changeFileTypeEntry {
                ChangeFileTypeSheet(
                    entry: entry,
                    onSave: { newFileType, newAuxType in
                        viewModel.changeFileType(entry: entry, newFileType: newFileType, newAuxType: newAuxType)
                    }
                )
            }
        }
        .sheet(isPresented: $viewModel.showingInspector) {
            if let entry = viewModel.inspectorEntry {
                FileInspectorSheet(entry: entry, siblings: viewModel.siblings(of: entry),
                                   onMove: { viewModel.moveSelection(by: $0) })
            }
        }
    }
    
    // MARK: - Header View

    /// "Label: value" pair in the header line. Only the file name may shorten; the rest keep their width.
    private func headerItem(_ label: String, _ value: String?, canShorten: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(skin.font(11))
                .foregroundColor(skin.secondaryText)
                .fixedSize()
            Text(value ?? "—")
                .font(skin.font(11, weight: .medium))
                .foregroundColor(value == nil ? skin.secondaryText : skin.folderText)
                .lineLimit(1)
                .truncationMode(.middle)
                .fixedSize(horizontal: !canShorten, vertical: false)
        }
        .layoutPriority(canShorten ? 0 : 1)
    }

    private var headerView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                headerItem("Volume:", viewModel.catalog?.diskName)
                headerItem("Filesystem:", viewModel.catalog?.diskFormat)
                headerItem("Size:", viewModel.diskImageFileSize.map {
                    ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
                })

                // Back button and current path
                HStack(spacing: 8) {
                    Button(action: {
                        viewModel.navigateBack()
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12))
                            .foregroundColor(skin.folderText)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canGoBack && viewModel.currentDirectory == nil)
                    .opacity((viewModel.canGoBack || viewModel.currentDirectory != nil) ? 1.0 : 0.3)

                    if let currentDir = viewModel.currentDirectory {
                        Text("📂 \(currentDir.name)")
                            .font(skin.font(11, weight: .medium))
                            .foregroundColor(skin.folderText)
                    }
                }

                Spacer()

                headerItem("Filename:", viewModel.diskImagePath?.lastPathComponent, canShorten: true)

                // Open or close every folder in this pane
                HStack(spacing: 6) {
                    Button(action: { viewModel.expandAll() }) {
                        Image(systemName: "chevron.down.square")
                    }
                    .help("Expand all folders")
                    Button(action: { viewModel.collapseAll() }) {
                        Image(systemName: "chevron.right.square")
                    }
                    .help("Collapse all folders")
                }
                .buttonStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(skin.folderText)
                .disabled(viewModel.catalog == nil)
                .opacity(viewModel.catalog == nil ? 0.3 : 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(skin.headerBackground)

            Divider()
                .overlay(skin.lines)
        }
    }

    // MARK: - Browser Content View
    
    private func browserContentView(catalog: DiskCatalog) -> some View {
        VStack(spacing: 0) {
            // Column Headers
            ColumnHeadersView(columnWidths: columnWidths)
            
            Divider()
                .overlay(skin.lines)
            
            // File List
            fileListView(catalog: catalog)
        }
        .background(
            Color.clear
                .onDrop(of: Self.droppableTypes, isTargeted: $isTargeted) { providers in
                    handleDrop(providers: providers)
                }
        )
        .overlay(
            Group {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.blue, lineWidth: 2)
                        .padding(4)
                }
            }
        )
    }
    
    // MARK: - File List View
    
    private func fileListView(catalog: DiskCatalog) -> some View {
        let entriesToShow: [DiskCatalogEntry] = {
            if let currentDir = viewModel.currentDirectory {
                // Show children of current directory
                return currentDir.children ?? []
            } else {
                // Show root entries
                return catalog.rootEntries
            }
        }()
        
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(entriesToShow) { entry in
                        catalogEntryRowWithDrag(entry: entry)
                    }
                }
            }
            // Keep the row picked with the arrow keys on screen
            .onChange(of: viewModel.scrollTarget) { _, target in
                if let target { proxy.scrollTo(target) }
            }
        }
        .background(skin.paneBackground)
    }
    
    // MARK: - Catalog Entry Row with Drag
    
    private func catalogEntryRowWithDrag(entry: DiskCatalogEntry) -> some View {
        CatalogEntryRow(
            entry: entry,
            isSelected: { viewModel.isSelected($0) },
            onToggle: { entry, cmd, shift in
                // Set this pane as active when selecting entries
                focusManager.setActivePane(paneId)
                viewModel.toggleSelection(entry, commandPressed: cmd, shiftPressed: shift)
            },
            onDoubleClick: { entry in
                viewModel.navigateInto(entry)
            },
            onRename: { entry in
                viewModel.renameEntry(entry)
            },
            onGetInfo: { entry in
                viewModel.showFileInfo(entry)
            },
            onChangeFileType: { entry in
                viewModel.showChangeFileType(entry)
            },
            onInspect: { entry in
                viewModel.showInspector(entry)
            },
            onCopy: { entry in
                focusManager.setActivePane(paneId)
                if !viewModel.isSelected(entry) {
                    viewModel.selectedEntries.removeAll()
                    viewModel.selectedEntries.insert(entry.id)
                }
                viewModel.copySelected()
            },
            onCut: { entry in
                focusManager.setActivePane(paneId)
                if !viewModel.isSelected(entry) {
                    viewModel.selectedEntries.removeAll()
                    viewModel.selectedEntries.insert(entry.id)
                }
                viewModel.cutSelected()
            },
            onPaste: {
                focusManager.setActivePane(paneId)
                // Paste into THIS pane
                viewModel.pasteClipboard()
            },
            onExport: { entry in
                focusManager.setActivePane(paneId)
                if !viewModel.isSelected(entry) {
                    viewModel.selectedEntries.removeAll()
                    viewModel.selectedEntries.insert(entry.id)
                }
                viewModel.exportSelectedToFinder()
            },
            onDelete: { entry in
                focusManager.setActivePane(paneId)
                if !viewModel.isSelected(entry) {
                    viewModel.selectedEntries.removeAll()
                    viewModel.selectedEntries.insert(entry.id)
                }
                viewModel.deleteSelected()
            },
            dragProvider: { createDragProvider(for: $0) },
            level: 0,
            isExpanded: { viewModel.isExpanded($0) },
            setExpanded: { viewModel.setExpanded($0, $1) },
            columnWidths: columnWidths
        )
    }
    
    // MARK: - Drag Provider
    
    private func createDragProvider(for entry: DiskCatalogEntry) -> NSItemProvider {
        // Dragging a selected row takes the whole selection; any other row is dragged on its own
        let entries = viewModel.isSelected(entry) ? viewModel.topLevelEntries(viewModel.getSelectedEntries()) : [entry]

        // For Finder: the files themselves, written to a temporary folder (Finder only takes
        // a drag from a SwiftUI view when it carries a real file)
        let diskName = viewModel.catalog?.diskName ?? "Disk"
        let provider = DiskPaneViewModel.exportForDrag(entries, diskName: diskName)
            .map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider()

        // For the other pane: the entries, tagged with the image they come from
        let payload = DragPayload(sourceImagePath: viewModel.diskImagePath?.path ?? "", entries: entries)
        if let json = try? JSONEncoder().encode(payload) {
            provider.registerDataRepresentation(forTypeIdentifier: DragPayload.typeIdentifier, visibility: .all) { completion in
                completion(json, nil)
                return nil
            }
        }
        return provider
    }
    
    // MARK: - Empty State View
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "opticaldiscdrive")
                .font(.system(size: 64))
                .foregroundColor(skin.secondaryText)
            
            Text("No Disk Image Loaded")
                .font(skin.isRetro ? skin.font(15) : .title3)
                .foregroundColor(skin.secondaryText)
            
            Button("Open Disk Image") {
                viewModel.showingFilePicker = true
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color.clear
                .onDrop(of: Self.droppableTypes, isTargeted: $isTargeted) { providers in
                    handleDrop(providers: providers)
                }
        )
    }
    
    // MARK: - Drop Handler

    /// What a pane accepts. SwiftUI only hands over the types listed here, so the
    /// entries dragged from a pane must be named or they arrive as exported files.
    private static let droppableTypes: [UTType] = [DragPayload.type, .fileURL, .plainText, .item, .data]

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        print("📥 DROP: Received \(providers.count) providers")
        for (i, provider) in providers.enumerated() {
            print("   Provider \(i): \(provider.registeredTypeIdentifiers)")
        }

        // Entries dragged from a pane
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(DragPayload.typeIdentifier) }) {
            provider.loadDataRepresentation(forTypeIdentifier: DragPayload.typeIdentifier) { data, _ in
                DispatchQueue.main.async {
                    guard let payload = data.flatMap({ try? JSONDecoder().decode(DragPayload.self, from: $0) }) else { return }
                    // Dropping entries back onto the image they came from would only duplicate them
                    guard payload.sourceImagePath != self.viewModel.diskImagePath?.path else { return }
                    self.viewModel.importEntries(payload.entries, from: self.targetViewModel)
                }
            }
            return true
        }

        guard !providers.isEmpty else { return false }

        // Everything else is loaded first and sorted out afterwards: a drop can carry file
        // URLs, files that only come as data (Finder gives a text file that way), or text
        // dragged from another app.
        let group = DispatchGroup()
        var droppedURLs: [URL] = []
        var droppedFiles: [ImportedFile] = []

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (urlData, _) in
                    DispatchQueue.main.async {
                        if let data = urlData as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                            droppedURLs.append(url)
                        }
                        group.leave()
                    }
                }
            } else if let type = provider.registeredTypeIdentifiers.first {
                group.enter()
                // Finder can hand over a file under a type another app declares (Virtual II
                // claims .hdv) without a file URL. Asking for the file in place gets the
                // original, so changes are saved to it rather than to a temporary copy.
                provider.loadInPlaceFileRepresentation(forTypeIdentifier: type) { url, isInPlace, _ in
                    if let url = url, isInPlace {
                        DispatchQueue.main.async {
                            droppedURLs.append(url)
                            group.leave()
                        }
                        return
                    }
                    // A copy is removed when this block returns, so read it now
                    let file = url.flatMap { url in
                        (try? Data(contentsOf: url)).map { ImportedFile(filename: url.lastPathComponent, data: $0) }
                    }
                    DispatchQueue.main.async {
                        if let file = file {
                            droppedFiles.append(file)
                        }
                        group.leave()
                    }
                }
            }
        }

        group.notify(queue: .main) {
            self.viewModel.dropFiles(droppedURLs, and: droppedFiles)
        }

        return true
    }
}

// MARK: - Drag Payload

/// What travels between panes in a drag: the entries and the image they came from
struct DragPayload: Codable {
    /// Only RetroBrowse reads this type; other apps take the exported files
    static let typeIdentifier = "com.probrowse.entries"
    static let type = UTType(exportedAs: typeIdentifier, conformingTo: .data)

    let sourceImagePath: String
    let entries: [DiskCatalogEntry]
}

// MARK: - Column Headers View

struct ColumnHeadersView: View {
    @ObservedObject var columnWidths: ColumnWidths
    @Environment(\.skin) private var skin
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                skin.headerBackground
                
                HStack(spacing: 0) {
                    // Name Column
                    ColumnHeader(title: "Name", width: $columnWidths.nameWidth)
                    
                    // Divider resizes NAME column (to the left)
                    ColumnDivider(leftWidth: $columnWidths.nameWidth, minLeftWidth: 100, maxLeftWidth: 400)
                    
                    // Type Column
                    ColumnHeader(title: "Type", width: $columnWidths.typeWidth)
                    
                    // Divider resizes TYPE column (to the left)
                    ColumnDivider(leftWidth: $columnWidths.typeWidth, minLeftWidth: 40, maxLeftWidth: 150)
                    
                    // Aux Column
                    ColumnHeader(title: "Aux", width: $columnWidths.auxWidth)
                    
                    // Divider resizes AUX column (to the left)
                    ColumnDivider(leftWidth: $columnWidths.auxWidth, minLeftWidth: 60, maxLeftWidth: 150)
                    
                    // Size Column
                    ColumnHeader(title: "Size", width: $columnWidths.sizeWidth)
                    
                    // Divider resizes SIZE column (to the left)
                    ColumnDivider(leftWidth: $columnWidths.sizeWidth, minLeftWidth: 80, maxLeftWidth: 200)
                    
                    // Modified Column
                    ColumnHeader(title: "Modified", width: $columnWidths.modifiedWidth)
                    
                    // Divider resizes MODIFIED column (to the left)
                    ColumnDivider(leftWidth: $columnWidths.modifiedWidth, minLeftWidth: 100, maxLeftWidth: 200)
                    
                    // Created Column (fills remaining space)
                    HStack(spacing: 0) {
                        Spacer().frame(width: 8)
                        Text("Created")
                            .font(skin.font(11, weight: .semibold))
                            .foregroundColor(skin.columnHeaderText)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(height: 24)
    }
}

// MARK: - Column Header Component

struct ColumnHeader: View {
    let title: String
    @Binding var width: Double
    @Environment(\.skin) private var skin
    
    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 8)
            Text(title)
                .font(skin.font(11, weight: .semibold))
                .foregroundColor(skin.columnHeaderText)
            Spacer(minLength: 0)
        }
        .frame(width: width, alignment: .leading)
    }
}

// MARK: - Column Divider (Resizable)

struct ColumnDivider: View {
    @Binding var leftWidth: Double
    let minLeftWidth: Double
    let maxLeftWidth: Double
    
    @State private var isDragging = false
    @State private var dragStartWidth: Double = 0
    @State private var previewWidth: Double = 0
    
    var body: some View {
        Divider()
            .frame(width: 1)
            .background(isDragging ? Color.accentColor : Color.secondary.opacity(0.3))
            .overlay(
                // Invisible drag area
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if !isDragging {
                                    isDragging = true
                                    dragStartWidth = leftWidth
                                }
                                // Calculate preview width but don't update binding yet
                                let newWidth = dragStartWidth + value.translation.width
                                previewWidth = min(max(newWidth, minLeftWidth), maxLeftWidth)
                            }
                            .onEnded { value in
                                // Only update the actual width at the end
                                let newWidth = dragStartWidth + value.translation.width
                                leftWidth = min(max(newWidth, minLeftWidth), maxLeftWidth)
                                isDragging = false
                            }
                    )
            )
    }
}
