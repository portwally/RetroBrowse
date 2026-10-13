//
//  ProBrowseApp.swift
//  ProBrowse
//
//  Created by Walter
//

import SwiftUI

@main
struct ProBrowseApp: App {
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // A single main window. Unlike a window group, this scene keeps an entry in the
        // Window menu, so the window can be brought back after it has been closed.
        Window("RetroBrowse", id: "main-window") {
            ContentView()
                .onReceive(NotificationCenter.default.publisher(for: .showHelp)) { _ in
                    openWindow(id: "help-window")
                }
        }
        // The main window always opens at launch, whatever was open when the app last quit
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Disk Image...") {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("createDiskImage"),
                        object: nil
                    )
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("Open in Left Pane...") {
                    NotificationCenter.default.post(name: .openDiskImage, object: PaneIdentifier.left)
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Open in Right Pane...") {
                    NotificationCenter.default.post(name: .openDiskImage, object: PaneIdentifier.right)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("Disk Image Info...") {
                    NotificationCenter.default.post(name: .showDiskImageInfo, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }

            CommandGroup(replacing: .help) {
                Button("ProBrowse Help") {
                    // Opened directly, so Help also works while the main window is closed
                    openWindow(id: "help-window")
                }
                .keyboardShortcut("?", modifiers: .command)

                Divider()

                Button("Visit ProBrowse on GitHub") {
                    if let url = URL(string: "https://github.com/portwally/ProBrowse") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        Window("ProBrowse Help", id: "help-window") {
            HelpWindow()
        }
        .defaultSize(width: 700, height: 500)
        // Help opens on request only, never on its own at launch
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

// Notification Names
extension NSNotification.Name {
    static let createDiskImage = NSNotification.Name("createDiskImage")
    static let openDiskImage = NSNotification.Name("openDiskImage")
    static let showHelp = NSNotification.Name("showHelp")
    static let showDiskImageInfo = NSNotification.Name("showDiskImageInfo")
}
