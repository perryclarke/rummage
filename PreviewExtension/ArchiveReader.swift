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
        } catch {
            // A bare .gz/.bz2/.xz that isn't a tarball: present the decompressed file as a single entry.
            if let listing = try? list(raw: true), !listing.entries.isEmpty {
                return listing
            }
            throw error
        }
    }

    /// Extracts the entry at `index` of `listing` to `destination`. Returns false if `isCancelled` became true.
    func extract(index: Int, of listing: ArchiveListing, to destination: URL, isCancelled: @Sendable () -> Bool) throws -> Bool {
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

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
        defer { buffer.deallocate() }
        while true {
            if isCancelled() { return false }
            let n = archive_read_data(a, buffer, bufferSize)
            if n == 0 { break }
            if n < 0 { throw error(a) }
            try handle.write(contentsOf: Data(bytesNoCopy: buffer, count: n, deallocator: .none))
        }
        return true
    }

    // MARK: - Private

    private func list(raw: Bool) throws -> ArchiveListing {
        let a = try open(raw: raw)
        defer { archive_read_free(a) }

        var entries: [ArchiveEntry] = []
        var entry: OpaquePointer?
        var index = 0
        while true {
            let r = archive_read_next_header(a, &entry)
            if r == ARCHIVE_EOF { break }
            if r < ARCHIVE_WARN { throw error(a) }
            guard let entry else { break }

            let path = raw ? rawEntryName : pathname(entry)
            let components = path.split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
            if !components.isEmpty {
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
            // Skipping is cheap for zip (central directory); for compressed tars it decompresses.
            archive_read_data_skip(a)
        }

        // libarchive's mtree reader accepts almost any text file, so a gzipped CSV would be
        // listed as an "archive" of its lines. Treat it as unrecognized so list() falls back to raw.
        if !raw, archive_format_name(a).map({ String(cString: $0).hasPrefix("mtree") }) == true {
            throw ArchiveError(message: "Not a recognized archive.")
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
