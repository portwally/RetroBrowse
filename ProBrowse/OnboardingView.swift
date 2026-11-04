//
//  OnboardingView.swift
//  ProBrowse
//
//  The welcome shown on first launch, and again from Help: what RetroBrowse does, the
//  backup warning (which has to be confirmed), the two panes, looking inside files, and
//  a choice of skin.
//

import SwiftUI

struct OnboardingView: View {
    /// Raise to show the welcome again to people who saw an older one
    static let currentVersion = 1
    static let storageKey = "onboardingVersion"

    /// Called when the welcome closes; `openDisk` is true for "Open a Disk…"
    let onFinish: (_ openDisk: Bool) -> Void

    @AppStorage(Skin.storageKey) private var skinName = Skin.system.rawValue
    @AppStorage(OnboardingView.storageKey) private var seenVersion = 0
    @State private var page = 0
    @State private var understood = false

    private enum Page: Int, CaseIterable { case welcome, backup, panes, inspect, look }
    private static let backupPage = Page.backup.rawValue
    private var isLast: Bool { page == Page.allCases.count - 1 }
    /// Pages after the backup warning are only reached once it has been confirmed
    private var canGoOn: Bool { page != Self.backupPage || understood }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch Page(rawValue: page) ?? .welcome {
                case .welcome: welcome
                case .backup: backup
                case .panes: panes
                case .inspect: inspect
                case .look: look
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)

            Divider()

            HStack {
                // Page dots
                HStack(spacing: 6) {
                    ForEach(Page.allCases, id: \.self) { p in
                        Circle()
                            .fill(p.rawValue == page ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if !isLast {
                    // Skipping still stops at the backup warning until it is confirmed
                    Button("Skip") { understood ? finish(openDisk: false) : (page = Self.backupPage) }
                }
                if page > 0 {
                    Button("Back") { page -= 1 }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                }
                if isLast {
                    Button("Start") { finish(openDisk: false) }
                    Button("Open a Disk…") { finish(openDisk: true) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Next") { page += 1 }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canGoOn)
                }
            }
            .padding(16)
            // The right arrow pages forward too
            .background(Button("") { if canGoOn && !isLast { page += 1 } }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .opacity(0)
                .accessibilityHidden(true))
        }
        .frame(width: 620, height: 470)
    }

    private func finish(openDisk: Bool) {
        seenVersion = Self.currentVersion
        onFinish(openDisk)
    }

    // MARK: - Pages

    private var welcome: some View {
        PageLayout(icon: nil, title: "Welcome to RetroBrowse") {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Browse, copy and look inside Apple II and Apple IIgs disk images and archives, right on your Mac.")
                .multilineTextAlignment(.center)
            Text("ProDOS, DOS 3.3 and Pascal disks · .po .2mg .hdv .dsk .do .img .woz · ShrinkIt, Binary II, ZIP and gzip archives")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var backup: some View {
        PageLayout(icon: "exclamationmark.triangle.fill", iconColor: .orange, title: "Back up your disk images") {
            VStack(alignment: .leading, spacing: 10) {
                Bullet("RetroBrowse writes straight into your image files when you copy, delete, rename or change files.")
                Bullet("Keep copies of any disk image you care about before you change it.")
                Bullet("Quit an emulator before changing a disk it has mounted. It keeps its own copy of the disk and can write over your changes.")
            }
            Toggle("I understand", isOn: $understood)
                .toggleStyle(.checkbox)
                .padding(.top, 8)
        }
    }

    private var panes: some View {
        PageLayout(icon: "rectangle.split.2x1", title: "Two panes") {
            VStack(alignment: .leading, spacing: 10) {
                Bullet("Open a disk with **Open Left** or **Open Right**, or drop it on a pane from the Finder.")
                Bullet("Drag files from one pane to the other to copy them.")
                Bullet("Drag files to the Finder to export them, or drop Mac files on a pane to import them.")
                Bullet("Drop an archive on an open disk and RetroBrowse asks whether to copy it as a file, unpack it or open it.")
            }
        }
    }

    private var inspect: some View {
        PageLayout(icon: "eye", title: "Look inside") {
            VStack(alignment: .leading, spacing: 10) {
                Bullet("Press **Space** to open a file in the inspector, and Space again to close it. The arrow keys move to the next file.")
                Bullet("Click **Preview** above a pane to turn it into a live preview of the file selected in the other pane.")
                Bullet("The preview also changes a file's type and aux type, and edits the song and sample texts of MOD files.")
                Bullet("Pictures, BASIC, text, fonts, icons, sounds and music are shown as what they are. **Help › File Types** lists everything.")
            }
        }
    }

    private var look: some View {
        PageLayout(icon: nil, title: "Pick a look") {
            Text("You can change it any time in **RetroBrowse › Settings**.")
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                ForEach(Skin.allCases) { skin in
                    Button { skinName = skin.rawValue } label: {
                        SkinThumbnail(skin: skin, isSelected: skin.rawValue == skinName)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(skin.title)
                }
            }
            .padding(.top, 8)
        }
    }
}

// MARK: - Building blocks

private struct PageLayout<Content: View>: View {
    let icon: String?
    var iconColor: Color = .accentColor
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 16) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 44))
                    .foregroundColor(iconColor)
            }
            Text(title).font(.title.bold())
            content
        }
        .frame(maxWidth: 520)
    }
}

private struct Bullet: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A tiny pane drawn in a skin's own colours and font
private struct SkinThumbnail: View {
    let skin: Skin
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// System, Light and Dark use the macOS look; draw them in the scheme they stand for
    private var scheme: ColorScheme? {
        switch skin {
        case .light: return .light
        case .dark: return .dark
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(skin.toolbarBackground).frame(height: 10)
                ForEach(Array(["PRODOS", "SYSTEM", "GAMES"].enumerated()), id: \.offset) { index, name in
                    Text(name)
                        .font(skin.isRetro ? skin.font(9) : .system(size: 9))
                        .foregroundColor(index == 1 ? skin.selectionText : (index == 0 ? skin.fileText : skin.folderText))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(index == 1 ? skin.selectionBackground : Color.clear)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 96, height: 72)
            .background(skin.isRetro ? skin.paneBackground : Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: isSelected ? 3 : 1))
            .environment(\.colorScheme, scheme ?? colorScheme)

            Text(skin.title).font(.caption)
        }
        .contentShape(Rectangle())
    }
}
