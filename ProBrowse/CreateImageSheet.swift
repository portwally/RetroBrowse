//
//  CreateImageSheet.swift
//  ProBrowse
//
//  Sheet for creating new disk images using Cadius
//

import SwiftUI

struct CreateImageSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var volumeName = "NEWDISK"
    @State private var diskSize: DiskSize = .size800kb
    @State private var imageFormat: ImageFormat = .po
    @State private var savePath: URL?
    @State private var showingSavePanel = false
    @State private var isCreating = false
    @State private var errorMessage: String?
    
    // ProDOS Volume Name validation
    private var isVolumeNameValid: Bool {
        // ProDOS rules:
        // - 1-15 characters
        // - Only A-Z, 0-9, and period (.)
        // - Must start with a letter
        // - All uppercase
        
        guard !volumeName.isEmpty && volumeName.count <= 15 else { return false }
        
        // Check all characters are valid
        guard volumeName.allSatisfy(Self.isAllowedInVolumeName) else {
            return false
        }
        
        // Must start with a letter
        guard let firstChar = volumeName.first, firstChar.isLetter else {
            return false
        }
        
        return true
    }
    
    /// ProDOS names use ASCII A-Z, 0-9 and period only
    nonisolated private static func isAllowedInVolumeName(_ character: Character) -> Bool {
        return character.isASCII && (character.isUppercase || character.isNumber || character == ".")
    }
    
    private var volumeNameHelp: String {
        if volumeName.isEmpty {
            return "Volume name cannot be empty"
        }
        if volumeName.count > 15 {
            return "Volume name too long (max 15 characters)"
        }
        if let firstChar = volumeName.first, !firstChar.isLetter {
            return "Volume name must start with a letter"
        }
        if volumeName.unicodeScalars.contains(where: { $0.value >= 128 }) {
            return "Volume name contains invalid characters"
        }
        if volumeName != volumeName.uppercased() {
            return "Volume name must be uppercase (A-Z, 0-9, period)"
        }
        let allowedSet = CharacterSet.uppercaseLetters
            .union(CharacterSet.decimalDigits)
            .union(CharacterSet(charactersIn: "."))
        if !volumeName.unicodeScalars.allSatisfy({ allowedSet.contains($0) }) {
            return "Only A-Z, 0-9, and period allowed"
        }
        return ""
    }
    
    enum DiskSize: String, CaseIterable {
        case size140kb = "140KB"
        case size800kb = "800KB"
        case size32mb = "32MB"
        
        var sizeString: String {
            switch self {
            case .size140kb: return "140KB"     // Standard 5.25" floppy (280 blocks)
            case .size800kb: return "800KB"     // Standard 3.5" disk
            case .size32mb: return "32MB"       // Maximum ProDOS size
            }
        }
        
        var displayName: String {
            return self.rawValue
        }
    }
    
    enum ImageFormat: String, CaseIterable {
        case po = ".po (ProDOS Order)"
        case twoimg = ".2mg (Universal 2IMG)"
        case hdv = ".hdv (Hard Disk Volume)"
        
        var fileExtension: String {
            switch self {
            case .po: return "po"
            case .twoimg: return "2mg"
            case .hdv: return "hdv"
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Create New Disk Image")
                .font(.title2)
                .fontWeight(.semibold)
            
            Form {
                Section("Volume Name") {
                    TextField("Volume Name", text: $volumeName)
                        .textFieldStyle(.roundedBorder)
                        .textCase(.uppercase)
                        .onChange(of: volumeName) { oldValue, newValue in
                            // Auto-convert to uppercase
                            volumeName = newValue.uppercased()
                            
                            // Remove invalid characters
                            volumeName = volumeName.filter(Self.isAllowedInVolumeName)
                            
                            // Limit to 15 characters
                            if volumeName.count > 15 {
                                volumeName = String(volumeName.prefix(15))
                            }
                        }
                    
                    if !volumeNameHelp.isEmpty {
                        Text(volumeNameHelp)
                            .font(.caption)
                            .foregroundColor(isVolumeNameValid ? .secondary : .red)
                    } else if isVolumeNameValid {
                        Text("Valid ProDOS volume name")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                
                Section("Disk Size") {
                    Picker("Size", selection: $diskSize) {
                        ForEach(DiskSize.allCases, id: \.self) { size in
                            Text(size.displayName).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                Section("Image Format") {
                    Picker("Format", selection: $imageFormat) {
                        ForEach(ImageFormat.allCases, id: \.self) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
                
                Section("Save Location") {
                    HStack {
                        if let path = savePath {
                            Text(path.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundColor(.secondary)
                        } else {
                            Text("No location selected")
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Button("Choose...") {
                            showSavePanel()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Create") {
                    createDiskImage()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isVolumeNameValid || savePath == nil || isCreating)
            }
            .padding(.top)
        }
        .padding(24)
        .frame(width: 500)
    }
    
    private func showSavePanel() {
        let panel = NSSavePanel()
        
        // Set allowed content types based on selected format
        switch imageFormat {
        case .po:
            panel.allowedContentTypes = [.po]
        case .twoimg:
            panel.allowedContentTypes = [.twoimg]
        case .hdv:
            panel.allowedContentTypes = [.hdv]
        }
        
        panel.nameFieldStringValue = volumeName + "." + imageFormat.fileExtension
        panel.canCreateDirectories = true
        
        if panel.runModal() == .OK {
            savePath = panel.url
        }
    }
    
    private func createDiskImage() {
        guard let outputPath = savePath else { return }
        
        // The save panel confirmed this exact file. If the format was changed afterwards the
        // name no longer matches it, and a different file must be confirmed in the panel again.
        let expectedExtension = imageFormat.fileExtension
        guard outputPath.pathExtension.lowercased() == expectedExtension.lowercased() else {
            savePath = nil
            errorMessage = "The format changed. Choose where to save the .\(expectedExtension) image."
            return
        }
        
        isCreating = true
        errorMessage = nil
        
        print("Creating disk image:")
        print("   Volume Name: \(volumeName)")
        print("   Image Path: \(outputPath.path)")
        print("   Size: \(diskSize.sizeString)")
        print("   Format: \(imageFormat.fileExtension)")
        
        ProDOSWriter.shared.createDiskImage(
            at: outputPath,
            volumeName: volumeName,
            sizeString: diskSize.sizeString
        ) { success, message in
            isCreating = false
            
            if success {
                print("✅ Disk image created successfully: \(outputPath.path)")
                dismiss()
            } else {
                errorMessage = "Failed to create disk image: \(message)"
            }
        }
    }
}

#Preview {
    CreateImageSheet()
}
