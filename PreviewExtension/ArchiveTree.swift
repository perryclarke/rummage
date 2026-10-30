import Foundation

/// A node in the folder tree shown in the outline view. Archives don't always contain
/// explicit directory entries, so intermediate folders are synthesized as needed.
final class ArchiveNode: NSObject {
    let name: String
    let path: [String]
    private(set) var entry: ArchiveEntry?
    private(set) var children: [ArchiveNode] = []
    private var childIndex: [String: Int] = [:]

    init(name: String, path: [String], entry: ArchiveEntry? = nil) {
        self.name = name
        self.path = path
        self.entry = entry
    }

    var isDirectory: Bool { entry == nil || entry?.kind == .directory }

    /// Uncompressed size: the entry's own size for files, the sum of descendants for folders.
    private(set) lazy var totalSize: Int64 = isDirectory ? children.reduce(0) { $0 + $1.totalSize } : (entry?.size ?? 0)

    private(set) lazy var fileCount: Int = isDirectory ? children.reduce(0) { $0 + $1.fileCount } : 1

    static func build(from entries: [ArchiveEntry]) -> ArchiveNode {
        let root = ArchiveNode(name: "", path: [])
        for entry in entries where !isHidden(entry.components) {
            var node = root
            for (depth, component) in entry.components.enumerated() {
                let isLast = depth == entry.components.count - 1
                node = node.child(named: component, entry: isLast ? entry : nil)
            }
        }
        root.sortRecursively()
        return root
    }

    /// Mac metadata that shows up in zips created by Finder; never useful to browse.
    private static func isHidden(_ components: [String]) -> Bool {
        components.first == "__MACOSX" || components.last == ".DS_Store"
    }

    private func child(named name: String, entry: ArchiveEntry?) -> ArchiveNode {
        if let i = childIndex[name] {
            // A later entry with the same path (e.g. an explicit directory entry, or a
            // re-appended file in a tar) replaces what we had.
            if let entry { children[i].entry = entry }
            return children[i]
        }
        let node = ArchiveNode(name: name, path: path + [name], entry: entry)
        childIndex[name] = children.count
        children.append(node)
        return node
    }

    private func sortRecursively() {
        children.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        childIndex = [:]
        children.forEach { $0.sortRecursively() }
    }
}
