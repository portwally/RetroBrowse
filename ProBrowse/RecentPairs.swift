//
//  RecentPairs.swift
//  ProBrowse
//
//  File > Open Recent: the last ten combinations of disks in the left and right panes.
//  Each disk is kept as a security-scoped bookmark, so the sandboxed app can open it
//  again after a relaunch, even if it has been moved or renamed.
//

import Combine
import Foundation

struct RecentDisk: Codable, Equatable {
    let path: String
    let bookmark: Data

    var name: String { (path as NSString).lastPathComponent }

    static func == (a: RecentDisk, b: RecentDisk) -> Bool { a.path == b.path }
}

struct RecentPair: Codable, Equatable, Identifiable {
    var left: RecentDisk?
    var right: RecentDisk?

    var id: String { (left?.path ?? "") + "\n" + (right?.path ?? "") }

    /// The menu title, e.g. "dos33.do ↔ NEWDISK.po"
    var title: String { "\(left?.name ?? "—")  ↔  \(right?.name ?? "—")" }
}

final class RecentPairs: ObservableObject {
    static let shared = RecentPairs()
    static let maximumCount = 10
    private static let storageKey = "recentPanePairs"

    @Published private(set) var pairs: [RecentPair] = []
    private let defaults: UserDefaults
    /// Images opened from here (temporary copies of dropped data) can't be opened again
    private let ignoredFolder: String

    init(defaults: UserDefaults = .standard, ignoring ignoredFolder: URL = FileManager.default.temporaryDirectory) {
        self.defaults = defaults
        self.ignoredFolder = ignoredFolder.resolvingSymlinksInPath().path
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([RecentPair].self, from: data) {
            pairs = saved
        }
    }

    /// Records the disks now open in the two panes. Called when a pane opens a new disk,
    /// while the pane still holds access to it (which a bookmark needs).
    func record(left: URL?, right: URL?) {
        let pair = RecentPair(left: left.flatMap(disk), right: right.flatMap(disk))
        guard pair.left != nil || pair.right != nil else { return }

        var list = pairs
        // Opening the second disk completes the first one's entry instead of adding another
        if let top = list.first,
           (top.right == nil && top.left == pair.left) || (top.left == nil && top.right == pair.right) {
            list.removeFirst()
        }
        list.removeAll { $0.id == pair.id }
        list.insert(pair, at: 0)
        pairs = Array(list.prefix(Self.maximumCount))
        save()
    }

    func clear() {
        pairs = []
        save()
    }

    /// The file a recent disk points to now, or nil if it is gone
    static func resolve(_ disk: RecentDisk) -> URL? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: disk.bookmark, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &isStale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func disk(_ url: URL) -> RecentDisk? {
        guard !url.resolvingSymlinksInPath().path.hasPrefix(ignoredFolder),
              let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return nil }
        return RecentDisk(path: url.path, bookmark: bookmark)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pairs) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
