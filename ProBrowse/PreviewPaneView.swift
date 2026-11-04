//
//  PreviewPaneView.swift
//  ProBrowse
//
//  A pane turned into a live preview of the file highlighted in the other pane: its
//  content, every directory field with an editable file type and aux type, the resource
//  fork, the texts inside a MOD file (editable too) and a hex dump.
//

import SwiftUI

struct PreviewPaneView: View {
    /// The pane whose highlighted file is shown
    @ObservedObject var source: DiskPaneViewModel
    @Environment(\.skin) private var skin

    enum Tab: String, CaseIterable {
        case content = "Content", info = "Info", resources = "Resources", song = "Song", hex = "Hex"
    }
    @State private var tab: Tab = .content

    var body: some View {
        Group {
            if source.catalog == nil {
                message("Open a disk in the other pane", icon: "opticaldiscdrive")
            } else if let entry = source.previewEntry {
                preview(of: entry)
            } else {
                message("Select a file in the other pane", icon: "hand.point.up.left")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(skin.isRetro ? skin.paneBackground : Color.clear)
    }

    private func message(_ text: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40))
            Text(text).font(skin.isRetro ? skin.font(15) : .title3)
        }
        .foregroundColor(skin.secondaryText)
    }

    private func tabs(for entry: DiskCatalogEntry) -> [Tab] {
        if entry.isDirectory { return [.info] }
        var tabs: [Tab] = [.content, .info]
        if !(entry.resourceForkData ?? Data()).isEmpty { tabs.append(.resources) }
        if MODMetadata(data: entry.data) != nil { tabs.append(.song) }
        tabs.append(.hex)
        return tabs
    }

    private func preview(of entry: DiskCatalogEntry) -> some View {
        let available = tabs(for: entry)
        let shown = available.contains(tab) ? tab : available[0]
        return VStack(spacing: 0) {
            // Header: what is shown and where it lives
            VStack(spacing: 2) {
                Text(entry.name).font(.headline)
                Text("\(entry.parentPath) · \(ProDOSFileTypeInfo.getFileTypeInfo(fileType: entry.fileType, auxType: entry.auxType).description)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)

            if available.count > 1 {
                Picker("", selection: Binding(get: { shown }, set: { tab = $0 })) {
                    ForEach(available, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            Divider()

            // Rebuilt for each file, so viewers and players start fresh
            Group {
                switch shown {
                case .content:
                    FileContentView(entry: entry, siblings: source.siblings(of: entry))
                case .info:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if !entry.isDirectory {
                                FileTypeEditor(entry: entry, source: source)
                            }
                            FileInfoView(entry: entry)
                        }
                        .padding(.top, 12)
                    }
                case .resources:
                    ResourceListView(fork: entry.resourceForkData ?? Data())
                case .song:
                    MODTextEditor(entry: entry, source: source)
                case .hex:
                    HexDumpView(data: entry.data)
                }
            }
            .id(entry.id)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - File type and aux type

/// Edits a file's type and aux type, with the names from the file type table
private struct FileTypeEditor: View {
    let entry: DiskCatalogEntry
    @ObservedObject var source: DiskPaneViewModel

    @State private var typeText = ""
    @State private var auxText = ""

    private var newType: UInt8? { UInt8(typeText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: ""), radix: 16) }
    private var newAux: UInt16? { UInt16(auxText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: ""), radix: 16) }

    /// General entries of the file type table, for the type menu
    private static let types = ProDOSFileTypeInfo.allEntries.filter { $0.auxType == nil }

    var body: some View {
        GroupBox("File Type") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Type $").frame(width: 50, alignment: .trailing)
                    TextField("", text: $typeText).frame(width: 40)
                    Menu("Choose") {
                        ForEach(Self.types) { row in
                            Button(String(format: "$%02X  %@ – %@", row.fileType, row.info.shortName, row.info.description)) {
                                typeText = String(format: "%02X", row.fileType)
                            }
                        }
                    }
                    .frame(width: 90)
                }
                HStack {
                    Text("Aux $").frame(width: 50, alignment: .trailing)
                    TextField("", text: $auxText).frame(width: 60)
                    let knownAux = ProDOSFileTypeInfo.allEntries.filter { $0.fileType == newType && $0.auxType != nil }
                    if !knownAux.isEmpty {
                        Menu("Known") {
                            ForEach(knownAux) { row in
                                Button(String(format: "$%04X  %@", row.auxType ?? 0, row.info.description)) {
                                    auxText = String(format: "%04X", row.auxType ?? 0)
                                }
                            }
                        }
                        .frame(width: 80)
                    }
                }
                if let type = newType, let aux = newAux {
                    Text(ProDOSFileTypeInfo.getFileTypeInfo(fileType: type, auxType: aux).description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Type is 2 hex digits, aux 4").font(.caption).foregroundColor(.red)
                }
                HStack {
                    if let reason = source.fileEditBlockedReason {
                        Text(reason).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Revert") { load() }
                        .disabled(!isChanged)
                    Button("Apply") {
                        if let type = newType, let aux = newAux {
                            source.changeFileType(entry: entry, newFileType: type, newAuxType: aux)
                        }
                    }
                    .disabled(!isChanged || newType == nil || newAux == nil || source.fileEditBlockedReason != nil)
                }
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal)
        .onAppear(perform: load)
    }

    private var isChanged: Bool { newType != entry.fileType || newAux != entry.auxType }

    private func load() {
        typeText = String(format: "%02X", entry.fileType)
        auxText = String(format: "%04X", entry.auxType)
    }
}

// MARK: - Resource fork

/// The resources in a IIgs resource fork; the one picked is shown in hex
private struct ResourceListView: View {
    let fork: Data
    @State private var selection: IIgsResource.ID?

    var body: some View {
        if let resources = ResourceForkParser.parse(fork) {
            VSplitView {
                Table(resources, selection: $selection) {
                    TableColumn("Type") { r in
                        Text(String(format: "$%04X", r.type) + (r.typeName.map { "  \($0)" } ?? ""))
                    }
                    TableColumn("ID") { r in Text(String(format: "$%08X", r.resourceID)) }
                        .width(90)
                    TableColumn("Size") { r in Text("\(r.data.count)") }
                        .width(60)
                }
                .frame(minHeight: 120)

                if let resource = resources.first(where: { $0.id == selection }) {
                    HexDumpView(data: resource.data)
                        .frame(minHeight: 220)
                } else {
                    Text("\(resources.count) resources, \(fork.count) bytes. Pick one to see its bytes.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            VStack(spacing: 8) {
                Text("The resource fork has no readable resource map (\(fork.count) bytes).")
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
                HexDumpView(data: fork)
            }
        }
    }
}

// MARK: - MOD texts

/// The song title and sample names of a MOD file, editable at their fixed widths
private struct MODTextEditor: View {
    let entry: DiskCatalogEntry
    @ObservedObject var source: DiskPaneViewModel

    @State private var metadata: MODMetadata?
    @State private var saving = false

    var body: some View {
        if let original = MODMetadata(data: entry.data), let edited = metadata {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(original.tag) · \(original.channels) channels · \(original.patternCount) patterns · \(original.songLength) positions")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        GroupBox("Title") {
                            limitedField(Binding(get: { edited.title }, set: { metadata?.title = $0 }),
                                         limit: MODMetadata.titleLength)
                        }

                        GroupBox("Samples") {
                            VStack(spacing: 4) {
                                ForEach(0..<MODMetadata.sampleCount, id: \.self) { i in
                                    HStack {
                                        Text(String(format: "%02d", i + 1))
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.secondary)
                                        limitedField(Binding(get: { edited.sampleNames[i] }, set: { metadata?.sampleNames[i] = $0 }),
                                                     limit: MODMetadata.sampleNameLength)
                                        Text(original.sampleLengths[i] > 0 ? "\(original.sampleLengths[i])" : "–")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .frame(width: 50, alignment: .trailing)
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }

                Divider()

                HStack {
                    if let reason = source.fileEditBlockedReason {
                        Text(reason).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Revert") { metadata = original }
                        .disabled(edited == original || saving)
                    Button("Save") {
                        guard let data = edited.applied(to: entry.data) else { return }
                        saving = true
                        source.replaceFileData(entry: entry, data: data) { _ in saving = false }
                    }
                    .disabled(edited == original || saving || source.fileEditBlockedReason != nil)
                }
                .padding()
            }
        } else {
            Color.clear.onAppear { metadata = MODMetadata(data: entry.data) }
        }
    }

    /// A text field that keeps at most `limit` characters
    private func limitedField(_ text: Binding<String>, limit: Int) -> some View {
        TextField("", text: Binding(get: { text.wrappedValue },
                                    set: { text.wrappedValue = String($0.prefix(limit)) }))
            .font(.system(.body, design: .monospaced))
            .textFieldStyle(.roundedBorder)
    }
}
