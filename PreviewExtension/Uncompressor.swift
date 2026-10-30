import Foundation

/// Copies chosen items (and the contents of chosen folders) out of an archive into a folder.
struct Uncompressor: Sendable {
    /// The new top-level items, in the order the nodes were given.
    private(set) var items: [URL] = []
    /// Encrypted entries, which can't be uncompressed without a password.
    private(set) var skippedCount = 0
    private var folders: [URL] = []
    private var targets: [ArchiveReader.Target] = []

    /// Plans uncompressing `nodes` into `folder`. An item whose name is already taken gets a
    /// numbered name ("notes 2.txt"), like in Finder, instead of replacing what's there.
    init(nodes: [ArchiveNode], into folder: URL) {
        var taken = Set<String>()
        for node in nodes where node.name != ".." {
            let url = Self.availableURL(for: node, in: folder, taken: &taken)
            items.append(url)
            add(node, at: url)
        }
    }

    func run(archive: URL, listing: ArchiveListing) throws {
        if targets.isEmpty, folders.isEmpty, skippedCount > 0 {
            throw ArchiveError(message: "Encrypted files can’t be uncompressed.")
        }
        let fm = FileManager.default
        do {
            for folder in folders {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try ArchiveReader(url: archive).extract(targets, of: listing)
        } catch {
            for item in items {
                try? fm.removeItem(at: item)
            }
            throw error
        }
    }

    private mutating func add(_ node: ArchiveNode, at url: URL) {
        if node.isDirectory {
            // Folders are created up front, since archives don't always have entries for them.
            folders.append(url)
            if let entry = node.entry {
                targets.append(.init(entry: entry, url: url))
            }
            // ".." would point outside the folder being created.
            for child in node.children where child.name != ".." {
                add(child, at: url.appendingPathComponent(child.name))
            }
        } else if let entry = node.entry {
            if entry.isEncrypted {
                skippedCount += 1
            } else if entry.kind != .other {
                targets.append(.init(entry: entry, url: url))
            }
        }
    }

    private static func availableURL(for node: ArchiveNode, in folder: URL, taken: inout Set<String>) -> URL {
        let name = node.name as NSString
        let base = node.isDirectory ? node.name : name.deletingPathExtension
        let ext = node.isDirectory ? "" : name.pathExtension
        var candidate = node.name
        var number = 2
        // attributesOfItem doesn't follow symlinks, so a broken link counts as taken too.
        while taken.contains(candidate.lowercased())
            || (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(candidate).path)) != nil {
            candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            number += 1
        }
        taken.insert(candidate.lowercased())
        return folder.appendingPathComponent(candidate, isDirectory: node.isDirectory)
    }
}
