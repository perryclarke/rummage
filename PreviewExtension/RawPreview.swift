import Foundation

/// Finds the JPEG preview a camera RAW file embeds, from just the start of the file. RAW files are
/// often 25–60 MB, but their previews are usually within the first few MB (a full-size one in Canon
/// CR3 and Fuji RAF, about 1600 pixels in Sony ARW, 1024 in most DNGs), so a thumbnail needs only
/// that much of the file read from the archive, and none of it written to disk.
///
/// The container is parsed to find where its previews are: TIFF-based formats (CR2, NEF, ARW, DNG,
/// ORF, RW2, PEF…) list them in their image directories, CR3 in its boxes, and RAF in its header.
/// If none is big enough, the start of the file is scanned for a JPEG, which finds previews kept
/// elsewhere (e.g. in maker notes). Failing that, the RAW itself has to be decoded.
enum RawPreview {
    /// Smaller previews are passed over for thumbnails, in favor of decoding the RAW itself.
    static let minPreviewSide = 1024
    /// The most of a file kept in memory while looking.
    static let maxBytes = 64 << 20
    /// How much of a file is scanned for a JPEG when no listed preview will do.
    static let scanBytes = 8 << 20

    enum Result: Sendable {
        /// The preview needs at least this many bytes from the start of the file.
        case needMore(Int)
        /// A JPEG, and the orientation (an EXIF value, 1–8) the file says to show it with, if any.
        case found(Data, orientation: Int?)
        /// There's no preview to use.
        case none
    }

    /// Looks for a preview whose longest side is at least `minSide`, in `data`, the start of a file
    /// (all of it, if `isWhole`).
    static func find(in data: Data, isWhole: Bool, minSide: Int = minPreviewSide) -> Result {
        let bytes = Bytes(data: data)
        let canRead = !isWhole && bytes.count < maxBytes
        if bytes.count < 128, canRead { return .needMore(128) }

        let listing: Listing
        if let tiff = TIFF(bytes, at: 0) {
            listing = tiff.listing()
        } else if bytes.string(at: 4, count: 4) == "ftyp" {
            listing = isoListing(bytes)
        } else if bytes.string(at: 0, count: 16) == "FUJIFILMCCD-RAW " {
            listing = rafListing(bytes)
        } else {
            listing = Listing()
        }
        if let need = listing.need, canRead { return .needMore(min(need, maxBytes)) }

        // The largest listed preview, judged by its size in bytes until its header can be read.
        let limit = isWhole ? bytes.count : maxBytes
        for candidate in listing.candidates.sorted(by: { $0.length > $1.length }) where candidate.end <= limit {
            switch jpegHeader(bytes, at: candidate.offset) {
            case .incomplete:
                if canRead { return .needMore(min(candidate.end, max(candidate.offset, bytes.count) + 256 << 10)) }
            case .size(let width, let height) where max(width, height) >= minSide:
                if candidate.end > bytes.count {
                    if canRead { return .needMore(candidate.end) }
                    continue
                }
                guard let jpeg = bytes.slice(candidate.offset, candidate.length) else { continue }
                return .found(jpeg, orientation: listing.orientation)
            default:
                continue
            }
        }

        if canRead, bytes.count < scanBytes { return .needMore(scanBytes) }
        guard let jpeg = scanForJPEG(bytes, minSide: minSide) else { return .none }
        return .found(jpeg, orientation: listing.orientation)
    }

    // MARK: - Containers

    /// What a container says about its previews.
    private struct Listing {
        var candidates: [Candidate] = []
        var orientation: Int?
        /// More of the file is needed to see the whole listing.
        var need: Int?

        mutating func needs(_ count: Int) {
            need = max(need ?? 0, count)
        }
    }

    private struct Candidate {
        let offset: Int
        let length: Int
        var end: Int { offset + length }
    }

    /// A TIFF structure (the basis of most RAW formats), from its header at `base`.
    private struct TIFF {
        let bytes: Bytes
        let base: Int
        let little: Bool

        init?(_ bytes: Bytes, at base: Int) {
            switch bytes.string(at: base, count: 2) {
            case "II": little = true
            case "MM": little = false
            default: return nil
            }
            self.bytes = bytes
            self.base = base
            // 42 is TIFF; Olympus ORF and Panasonic RW2 use their own numbers.
            guard let magic = bytes.u16(base + 2, little: little), [42, 0x4F52, 0x5352, 0x55].contains(magic) else { return nil }
        }

        private static let typeSizes = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4]

        /// The JPEGs listed in the image directories: IFD0 and those it chains to, and their SubIFDs.
        func listing() -> Listing {
            var listing = Listing()
            guard let first = bytes.u32(base + 4, little: little) else {
                listing.needs(base + 8)
                return listing
            }
            var queue = [first]
            var visited: Set<Int> = []
            while let offset = queue.first, visited.count < 32 {
                queue.removeFirst()
                guard offset > 0, visited.insert(offset).inserted else { continue }
                let start = base + offset
                guard let count = bytes.u16(start, little: little) else {
                    listing.needs(start + 2)
                    continue
                }
                let end = start + 2 + 12 * count + 4
                guard end <= bytes.count else {
                    listing.needs(end)
                    continue
                }
                var tags: [Int: Int] = [:]
                for i in 0..<count {
                    let entry = start + 2 + 12 * i
                    guard let tag = bytes.u16(entry, little: little), let type = bytes.u16(entry + 2, little: little),
                          let n = bytes.u32(entry + 4, little: little), let size = Self.typeSizes[type], n > 0, n < 1 << 24
                    else { continue }
                    // Values that fit in 4 bytes are stored in the entry itself.
                    let inline = size * n <= 4
                    guard let field = bytes.u32(entry + 8, little: little) else { continue }
                    let location = inline ? entry + 8 : base + field
                    switch tag {
                    case 0x14A: // SubIFDs
                        for j in 0..<min(n, 16) {
                            if let sub = bytes.u32(location + 4 * j, little: little) { queue.append(sub) } else { listing.needs(location + 4 * n) }
                        }
                    case 0x2E where !inline: // Panasonic's embedded JPEG
                        listing.candidates.append(Candidate(offset: location, length: n))
                    default:
                        // The first value of the tags used below.
                        let value = type == 3 ? bytes.u16(location, little: little) : type == 4 ? bytes.u32(location, little: little) : nil
                        if let value { tags[tag] = value }
                    }
                }
                if visited.count == 1, let orientation = tags[0x112], (1...8).contains(orientation) {
                    listing.orientation = orientation
                }
                if let offset = tags[0x201], let length = tags[0x202], length > 0 {
                    listing.candidates.append(Candidate(offset: base + offset, length: length))
                }
                // A strip of JPEG, as long as it's a picture (RGB or YCbCr) rather than raw sensor data;
                // CR2's raw data gives no interpretation, but also no dimensions or 8-bit samples.
                let photometric = tags[0x106]
                let isPicture = photometric.map { [2, 6].contains($0) }
                    ?? (tags[0x100] != nil && tags[0x101] != nil && (tags[0x102] ?? 8) == 8)
                if let compression = tags[0x103], [6, 7].contains(compression), isPicture,
                   let offset = tags[0x111], let length = tags[0x117], length > 0 {
                    listing.candidates.append(Candidate(offset: base + offset, length: length))
                }
                if let next = bytes.u32(end - 4, little: little), next > 0 { queue.append(next) }
            }
            return listing
        }
    }

    /// Canon CR3, an ISO media file: a full-size JPEG is the first track's sample, and a smaller
    /// one is in a PRVW box. The orientation is in the CMT1 box, a TIFF directory.
    private static func isoListing(_ bytes: Bytes) -> Listing {
        var listing = Listing()
        for box in boxes(bytes, in: 0..<bytes.count, listing: &listing) {
            switch box.type {
            case "moov":
                guard box.end <= bytes.count else {
                    listing.needs(box.end)
                    return listing
                }
                for child in boxes(bytes, in: box.body, listing: &listing) {
                    if child.type == "uuid", bytes.hex(at: child.body.lowerBound, count: 16) == "85c0b687820f11e08111f4ce462b6a48" {
                        let canon = (child.body.lowerBound + 16)..<child.body.upperBound
                        if let cmt1 = boxes(bytes, in: canon, listing: &listing).first(where: { $0.type == "CMT1" }),
                           let tiff = TIFF(bytes, at: cmt1.body.lowerBound) {
                            listing.orientation = tiff.listing().orientation
                        }
                    }
                }
                if let trak = boxes(bytes, in: box.body, listing: &listing).first(where: { $0.type == "trak" }),
                   let jpeg = firstSample(bytes, in: trak, listing: &listing) {
                    listing.candidates.append(jpeg)
                }
            case "uuid" where bytes.hex(at: box.body.lowerBound, count: 16) == "eaf42b5e1c984b88b9fbb7dc406e4d16":
                // A PRVW box follows the UUID and 8 more bytes; in its body, the JPEG's length is at 12
                // and the JPEG at 16.
                let prvw = box.body.lowerBound + 16 + 8
                if bytes.string(at: prvw + 4, count: 4) == "PRVW", let length = bytes.u32(prvw + 8 + 12, little: false) {
                    listing.candidates.append(Candidate(offset: prvw + 8 + 16, length: length))
                }
            case "mdat":
                return listing
            default:
                break
            }
        }
        return listing
    }

    /// The offset and size of a track's first sample, from its sample tables.
    private static func firstSample(_ bytes: Bytes, in trak: Box, listing: inout Listing) -> Candidate? {
        var box = trak
        for type in ["mdia", "minf", "stbl"] {
            guard let child = boxes(bytes, in: box.body, listing: &listing).first(where: { $0.type == type }) else { return nil }
            box = child
        }
        let table = boxes(bytes, in: box.body, listing: &listing)
        guard let stsz = table.first(where: { $0.type == "stsz" }) else { return nil }
        let body = stsz.body.lowerBound
        guard let fixedSize = bytes.u32(body + 4, little: false),
              let size = fixedSize != 0 ? fixedSize : bytes.u32(body + 12, little: false) else { return nil }
        if let co64 = table.first(where: { $0.type == "co64" }), let offset = bytes.u64(co64.body.lowerBound + 8) {
            return Candidate(offset: offset, length: size)
        }
        if let stco = table.first(where: { $0.type == "stco" }), let offset = bytes.u32(stco.body.lowerBound + 8, little: false) {
            return Candidate(offset: offset, length: size)
        }
        return nil
    }

    private struct Box {
        let type: String
        let body: Range<Int>
        let end: Int
    }

    /// The boxes in `range` whose headers are present (a box's body may extend past the data).
    private static func boxes(_ bytes: Bytes, in range: Range<Int>, listing: inout Listing) -> [Box] {
        var result: [Box] = []
        var position = range.lowerBound
        while position + 8 <= range.upperBound, result.count < 256 {
            guard let size32 = bytes.u32(position, little: false), let type = bytes.string(at: position + 4, count: 4) else {
                listing.needs(position + 8)
                break
            }
            var header = 8
            var size = size32
            if size32 == 1 {
                guard let size64 = bytes.u64(position + 8) else {
                    listing.needs(position + 16)
                    break
                }
                header = 16
                size = size64
            } else if size32 == 0 {
                size = Int.max / 2 - position // to the end of the file
            }
            guard size >= header, size <= Int.max / 2 - position else { break }
            let end = position + size
            result.append(Box(type: type, body: (position + header)..<min(end, range.upperBound), end: end))
            position = end
        }
        return result
    }

    /// Fujifilm RAF: the header gives the offset and length of a large JPEG.
    private static func rafListing(_ bytes: Bytes) -> Listing {
        var listing = Listing()
        if let offset = bytes.u32(84, little: false), let length = bytes.u32(88, little: false) {
            listing.candidates.append(Candidate(offset: offset, length: length))
        }
        return listing
    }

    // MARK: - JPEG

    private enum JPEGHeader {
        case size(width: Int, height: Int)
        /// Not a JPEG, or a lossless one (how some RAW formats store sensor data), which ImageIO can't show.
        case unusable
        case incomplete
    }

    /// The pixel size from a JPEG's frame header.
    private static func jpegHeader(_ bytes: Bytes, at offset: Int) -> JPEGHeader {
        guard let soi = bytes.u16(offset, little: false) else { return .incomplete }
        guard soi == 0xFFD8 else { return .unusable }
        var position = offset + 2
        while true {
            guard let marker = bytes.u16(position, little: false), let length = bytes.u16(position + 2, little: false) else {
                return .incomplete
            }
            guard marker >> 8 == 0xFF, length >= 2 else { return .unusable }
            switch marker & 0xFF {
            case 0xC0, 0xC1, 0xC2: // baseline, extended and progressive frames
                guard let height = bytes.u16(position + 5, little: false), let width = bytes.u16(position + 7, little: false) else {
                    return .incomplete
                }
                return width > 0 && height > 0 ? .size(width: width, height: height) : .unusable
            case 0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF, 0xDA: // other frames, or image data before any frame
                return .unusable
            default:
                position += 2 + length
            }
        }
    }

    /// The largest complete JPEG, of at least `minSide`, in the first `scanBytes` of the file.
    private static func scanForJPEG(_ bytes: Bytes, minSide: Int) -> Data? {
        let limit = min(bytes.count, scanBytes)
        var best: (range: Range<Int>, pixels: Int)?
        var position = 0
        var tried = 0
        while let start = bytes.find([0xFF, 0xD8, 0xFF], from: position, before: limit), tried < 1000 {
            tried += 1
            position = start + 3
            guard case .size(let width, let height) = jpegHeader(bytes, at: start), max(width, height) >= minSide,
                  width * height > best?.pixels ?? 0 else { continue }
            // One that doesn't end in range ends the scan, so a damaged file can't make it rescan the same data.
            guard let end = jpegEnd(bytes, from: start, before: limit) else { break }
            best = (start..<end, width * height)
            position = end
        }
        return best.flatMap { bytes.slice($0.range.lowerBound, $0.range.count) }
    }

    /// Where a JPEG ends: past its end-of-image marker, found by stepping over its segments and
    /// through its entropy-coded data (where 0xFF is followed by 0 or a restart marker).
    private static func jpegEnd(_ bytes: Bytes, from offset: Int, before limit: Int) -> Int? {
        var position = offset + 2
        while position + 4 <= limit {
            guard let marker = bytes.u16(position, little: false), marker >> 8 == 0xFF else { return nil }
            let code = marker & 0xFF
            if code == 0xD9 { return position + 2 }
            if code == 0xFF { position += 1; continue } // fill byte
            guard let length = bytes.u16(position + 2, little: false), length >= 2 else { return nil }
            position += 2 + length
            if code == 0xDA { // scan data follows the header; find the next marker
                while true {
                    guard let ff = bytes.find([0xFF], from: position, before: limit), let next = bytes.u8(ff + 1) else { return nil }
                    if next == 0 || (0xD0...0xD7).contains(next) {
                        position = ff + 2
                    } else {
                        position = ff
                        break
                    }
                }
            }
        }
        return nil
    }
}

/// Bounds-checked reads from the start of a file.
private struct Bytes {
    let data: Data
    var count: Int { data.count }

    func u8(_ offset: Int) -> Int? {
        offset >= 0 && offset < count ? Int(data[data.startIndex + offset]) : nil
    }

    func u16(_ offset: Int, little: Bool) -> Int? {
        guard let a = u8(offset), let b = u8(offset + 1) else { return nil }
        return little ? a | b << 8 : a << 8 | b
    }

    func u32(_ offset: Int, little: Bool) -> Int? {
        guard let a = u16(offset, little: little), let b = u16(offset + 2, little: little) else { return nil }
        return little ? a | b << 16 : a << 16 | b
    }

    /// A big-endian 64-bit value, if it fits comfortably in an Int.
    func u64(_ offset: Int) -> Int? {
        guard let high = u32(offset, little: false), let low = u32(offset + 4, little: false), high < 1 << 30 else { return nil }
        return high << 32 | low
    }

    func string(at offset: Int, count length: Int) -> String? {
        slice(offset, length).map { String(decoding: $0, as: UTF8.self) }
    }

    func hex(at offset: Int, count length: Int) -> String? {
        slice(offset, length).map { $0.map { String(format: "%02x", $0) }.joined() }
    }

    func slice(_ offset: Int, _ length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset <= count - length else { return nil }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + length))
    }

    /// The offset of the first occurrence of `pattern` starting in `from..<before`.
    func find(_ pattern: [UInt8], from: Int, before: Int) -> Int? {
        let end = min(before, count)
        guard from >= 0, from < end, let first = pattern.first else { return nil }
        return data.withUnsafeBytes { buffer -> Int? in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var position = from
            while position < end {
                guard let hit = memchr(base + position, Int32(first), end - position) else { return nil }
                let offset = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
                if offset + pattern.count <= count, (1..<pattern.count).allSatisfy({ base[offset + $0] == pattern[$0] }) {
                    return offset
                }
                position = offset + 1
            }
            return nil
        }
    }
}
