import CArchive
import Foundation

struct ArchiveEntry: Sendable {
    enum Kind: Sendable { case file, directory, symlink, other }

    /// Position of the entry in the archive stream; used to find it again when extracting.
    let index: Int
    /// Normalized path components, e.g. ["docs", "readme.md"].
    let components: [String]
    let kind: Kind
    let size: Int64?
    let modified: Date?
    let isEncrypted: Bool
}

struct ArchiveListing: Sendable {
    let entries: [ArchiveEntry]
    /// Human-readable format, e.g. "ZIP 2.0 (deflation)" or "GNU tar format + gzip".
    let formatDescription: String
    /// True for a single compressed file (e.g. data.csv.gz) rather than a real archive.
    let isRaw: Bool
}

struct ArchiveError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Thin synchronous wrapper around libarchive. Each call opens the archive afresh,
/// since libarchive reads archives as a forward-only stream.
struct ArchiveReader: Sendable {
    let url: URL

    func list() throws -> ArchiveListing {
        do {
            return try list(raw: false)
        } catch let error as UnrecognizedArchive {
            // A bare .gz/.bz2/.xz that isn't a tarball: present the decompressed file as a single entry.
            if let listing = try? list(raw: true), !listing.entries.isEmpty {
                return listing
            }
            throw error.underlying
        }
    }

    /// Extracts the entry at `index` of `listing` to `destination`, giving up with an error once
    /// more than `maxBytes` have been written (sizes in headers can't be trusted, and raw entries
    /// have none). Returns false if `isCancelled` became true.
    func extract(index: Int, of listing: ArchiveListing, to destination: URL, maxBytes: Int64,
                 isCancelled: @Sendable () -> Bool) throws -> Bool {
        let a = try open(raw: listing.isRaw)
        defer { archive_read_free(a) }

        var entry: OpaquePointer?
        var current = 0
        while true {
            let r = archive_read_next_header(a, &entry)
            if r == ARCHIVE_EOF { throw ArchiveError(message: "Entry not found in archive.") }
            if r < ARCHIVE_WARN { throw error(a) }
            if current == index { break }
            current += 1
            if isCancelled() { return false }
        }
        return try writeData(a, to: destination, maxBytes: maxBytes, isCancelled: isCancelled)
    }

    struct Target: Sendable {
        let entry: ArchiveEntry
        let url: URL
    }

    /// Writes each target entry to its URL in a single pass over the archive, recreating files,
    /// folders and symlinks with their permissions and modification dates. Parent folders must exist.
    func extract(_ targets: [Target], of listing: ArchiveListing) throws {
        let a = try open(raw: listing.isRaw)
        defer { archive_read_free(a) }

        let fm = FileManager.default
        var pending = Dictionary(targets.map { ($0.entry.index, $0) }, uniquingKeysWith: { $1 })
        var symlinks: [(url: URL, destination: String)] = []
        var folderDates: [(url: URL, date: Date)] = []
        var entry: OpaquePointer?
        var index = 0
        while !pending.isEmpty {
            let r = archive_read_next_header(a, &entry)
            if r == ARCHIVE_EOF { break }
            if r < ARCHIVE_WARN { throw error(a) }
            defer { index += 1 }
            guard let entry, let target = pending.removeValue(forKey: index) else { continue }

            switch target.entry.kind {
            case .directory:
                try fm.createDirectory(at: target.url, withIntermediateDirectories: true)
                if let date = target.entry.modified { folderDates.append((target.url, date)) }
            case .symlink:
                if let destination = symlinkDestination(entry) { symlinks.append((target.url, destination)) }
            case .file:
                _ = try writeData(a, to: target.url, maxBytes: .max, isCancelled: { false })
                var attributes: [FileAttributeKey: Any] = [:]
                let permissions = archive_entry_perm(entry) & 0o777
                // Some zips (e.g. made on Windows) carry no permissions; keep the default then.
                if permissions & 0o400 != 0 { attributes[.posixPermissions] = permissions }
                if let date = target.entry.modified { attributes[.modificationDate] = date }
                try? fm.setAttributes(attributes, ofItemAtPath: target.url.path)
            case .other:
                break
            }
        }
        if let missing = pending.values.first {
            throw ArchiveError(message: "“\(missing.entry.components.last ?? "")” wasn’t found in the archive.")
        }

        // Symlinks are created last so that one can't redirect where a later entry is written.
        for link in symlinks {
            try? fm.createSymbolicLink(atPath: link.url.path, withDestinationPath: link.destination)
        }
        // Adding contents changes a folder's date, so restore folder dates at the very end.
        for folder in folderDates {
            try? fm.setAttributes([.modificationDate: folder.date], ofItemAtPath: folder.url.path)
        }
    }

    /// Reads the entries whose paths pass `include` into memory in a single pass, e.g. the XML
    /// parts of an .xlsx file (which is itself a zip archive).
    func readEntries(maxTotalBytes: Int, where include: (String) -> Bool) throws -> [String: Data] {
        let a = try open(raw: false)
        defer { archive_read_free(a) }

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
        defer { buffer.deallocate() }
        var result: [String: Data] = [:]
        var total = 0
        var entry: OpaquePointer?
        while true {
            let r = archive_read_next_header(a, &entry)
            if r == ARCHIVE_EOF { break }
            if r < ARCHIVE_WARN { throw error(a) }
            guard let entry else { break }
            let path = pathname(entry)
            guard include(path) else { continue }

            var data = Data()
            while true {
                let n = archive_read_data(a, buffer, bufferSize)
                if n == 0 { break }
                if n < 0 { throw error(a) }
                total += n
                if total > maxTotalBytes { throw ArchiveError(message: "Too large to preview.") }
                data.append(buffer.assumingMemoryBound(to: UInt8.self), count: n)
            }
            result[path] = data
        }
        return result
    }

    // MARK: - Private

    /// Writes the data of the current entry to `destination`. Returns false if `isCancelled` became true.
    private func writeData(_ a: OpaquePointer, to destination: URL, maxBytes: Int64, isCancelled: () -> Bool) throws -> Bool {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
        defer { buffer.deallocate() }
        var written: Int64 = 0
        while true {
            if isCancelled() { return false }
            let n = archive_read_data(a, buffer, bufferSize)
            if n == 0 { break }
            if n < 0 { throw error(a) }
            written += Int64(n)
            if written > maxBytes { throw ArchiveError(message: "Too large to preview.") }
            try handle.write(contentsOf: Data(bytesNoCopy: buffer, count: n, deallocator: .none))
        }
        return true
    }

    private func symlinkDestination(_ entry: OpaquePointer) -> String? {
        if let p = archive_entry_symlink_utf8(entry) { return String(cString: p) }
        if let p = archive_entry_symlink(entry) { return String(decoding: Data(bytes: p, count: strlen(p)), as: UTF8.self) }
        return nil
    }

    /// Thrown by `list(raw: false)` when the file isn't an archive libarchive knows, as opposed to
    /// a recognized archive that is damaged; only the former falls back to raw mode.
    private struct UnrecognizedArchive: Error {
        let underlying: ArchiveError
    }

    private func list(raw: Bool) throws -> ArchiveListing {
        let a: OpaquePointer
        do {
            a = try open(raw: raw)
        } catch let error as ArchiveError {
            throw raw ? error : UnrecognizedArchive(underlying: error)
        }
        defer { archive_read_free(a) }

        var entries: [ArchiveEntry] = []
        var entry: OpaquePointer?
        var index = 0
        while true {
            let r = archive_read_next_header(a, &entry)
            if r == ARCHIVE_EOF { break }
            if r < ARCHIVE_WARN {
                // Failing on the very first header means the format wasn't recognized; failing
                // later means a recognized archive is truncated or corrupt, which is worth reporting.
                let err = error(a)
                throw raw || index > 0 ? err : UnrecognizedArchive(underlying: err)
            }
            guard let entry else { break }

            let path = raw ? rawEntryName : pathname(entry)
            let components = path.split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
            // Entries with ".." in their path are left out, as bsdtar does: they would point outside
            // the folder they're uncompressed into (and outside the preview's own folder).
            if !components.isEmpty, !components.contains("..") {
                let kind: ArchiveEntry.Kind
                switch archive_entry_filetype(entry) & AE_IFMT {
                case AE_IFREG: kind = path.hasSuffix("/") ? .directory : .file
                case AE_IFDIR: kind = .directory
                case AE_IFLNK: kind = .symlink
                default: kind = .other
                }
                entries.append(ArchiveEntry(
                    index: index,
                    components: components,
                    kind: kind,
                    size: archive_entry_size_is_set(entry) != 0 ? archive_entry_size(entry) : nil,
                    modified: archive_entry_mtime_is_set(entry) != 0
                        ? Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(entry))) : nil,
                    isEncrypted: archive_entry_is_encrypted(entry) != 0
                ))
            }
            index += 1
            // Skipping is cheap for zip (central directory); for compressed tars it decompresses,
            // which is where a truncated or corrupt archive usually shows up.
            if archive_read_data_skip(a) < ARCHIVE_WARN { throw error(a) }
        }

        // libarchive's mtree reader accepts almost any text file, so a gzipped CSV would be
        // listed as an "archive" of its lines. Treat it as unrecognized so list() falls back to raw.
        if !raw, archive_format_name(a).map({ String(cString: $0).hasPrefix("mtree") }) == true {
            throw UnrecognizedArchive(underlying: ArchiveError(message: "Not a recognized archive."))
        }
        if raw {
            // libarchive accepts anything in raw mode; only trust it if a real filter was applied.
            guard archive_filter_count(a) > 1 else {
                throw ArchiveError(message: "Not a recognized archive.")
            }
        }
        return ArchiveListing(entries: entries, formatDescription: formatDescription(a, raw: raw), isRaw: raw)
    }

    private func open(raw: Bool) throws -> OpaquePointer {
        guard let a = archive_read_new() else { throw ArchiveError(message: "Out of memory.") }
        archive_read_support_filter_all(a)
        if raw {
            archive_read_support_format_raw(a)
        } else {
            archive_read_support_format_all(a)
        }
        if archive_read_open_filename(a, url.path, 64 * 1024) != ARCHIVE_OK {
            let err = error(a)
            archive_read_free(a)
            throw err
        }
        return a
    }

    private var rawEntryName: String {
        url.deletingPathExtension().lastPathComponent
    }

    private func pathname(_ entry: OpaquePointer) -> String {
        if let p = archive_entry_pathname_utf8(entry) { return String(cString: p) }
        if let p = archive_entry_pathname(entry) { return String(decoding: Data(bytes: p, count: strlen(p)), as: UTF8.self) }
        return ""
    }

    private func formatDescription(_ a: OpaquePointer, raw: Bool) -> String {
        let filters = (0..<archive_filter_count(a))
            .compactMap { archive_filter_name(a, $0).map { String(cString: $0) } }
            .filter { $0 != "none" }
        var format = raw ? nil : archive_format_name(a).map { String(cString: $0) }
        // For zip, libarchive reports the last entry's compression method ("ZIP 2.0 (deflation)"),
        // which says nothing about the archive as a whole.
        if format?.hasPrefix("ZIP") == true { format = "ZIP archive" }
        return ([format].compactMap { $0 } + filters).joined(separator: " + ")
    }

    private func error(_ a: OpaquePointer) -> ArchiveError {
        ArchiveError(message: archive_error_string(a).map { String(cString: $0) } ?? "Unreadable archive.")
    }
}
