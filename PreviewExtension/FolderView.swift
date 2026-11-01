import Cocoa
import ImageIO
import UniformTypeIdentifiers

/// The contents of a folder (or of the archive's top level) as a grid of icons, like Finder's icon
/// view, with thumbnails for images. The images are extracted in a single pass over the archive, to
/// where their own previews would go, so opening one afterwards doesn't extract it again. Large ones
/// are replaced by a smaller copy instead, so a folder of big photos doesn't fill the disk, and for
/// camera RAW files only the start is read, for the JPEG preview they embed (see `RawPreview`).
@MainActor
final class FolderView: NSView {
    /// Images larger than this keep their file icon: the same limit as for previewing one.
    nonisolated private static let maxImageBytes = PreviewViewController.maxPreviewSize
    /// Limits on the images read for one folder's thumbnails, to bound the time spent.
    private static let maxThumbnailBytes: Int64 = 4 << 30
    private static let maxThumbnails = 400
    /// Images are kept full size up to these sizes (each, and in all); larger ones, such as RAW
    /// photos, are replaced by a copy whose longest side is `reducedPixelSize`, to bound the disk used,
    /// with up to `maxReducedBytes` of those.
    private static let maxKeptImageBytes: Int64 = 16 << 20
    private static let maxKeptBytes: Int64 = 256 << 20
    nonisolated private static let maxReducedBytes = 256 << 20
    /// Enough for one image filling a full-screen preview at the slider's right end.
    nonisolated private static let reducedPixelSize: CGFloat = 2560
    /// Icon sizes in points: the default, and the smallest the size slider (shown when there are
    /// thumbnails) goes. Its largest fits one image to the grid's area, as a selected image is fitted
    /// to the pane. The slider's last setting is kept in the extension's defaults.
    fileprivate static let defaultIconSize: CGFloat = 64
    private static let minIconSize: CGFloat = 32
    /// Saved when the slider is at its right end, so the icons then follow the pane's size.
    private static let largestIconSize: CGFloat = 1_000_000
    private static let iconSizeKey = "ThumbnailIconSize"
    /// Margin around the grid, and the room in a cell beside and below the icon (for the name).
    private static let gridInset: CGFloat = 12
    private static let cellPadding = NSSize(width: 24, height: 40)

    /// Called to uncompress an item: when it's double-clicked, or chosen from its context menu.
    var onUncompress: ((ArchiveNode) -> Void)?

    private let items: [ArchiveNode]
    /// Position in `items` of each entry, by entry index, for placing thumbnails as they arrive.
    private let positions: [Int: Int]
    /// The images extracted for thumbnails.
    private let jobs: [ThumbnailJob]
    /// Extracted images by entry index, ready to make thumbnails from.
    private var imageFiles: [Int: URL] = [:]
    /// Thumbnails by entry index. They're made only for visible items, and the cache drops some when
    /// it's full, so large icons in a big folder don't use too much memory.
    private let thumbnails = NSCache<NSNumber, Thumbnail>()
    /// The pixel size of each thumbnail being made, by entry index.
    private var decoding: [Int: CGFloat] = [:]
    private var undecodable: Set<Int> = []
    /// The icon size the slider asks for; the size used is limited by the grid's area.
    private var requestedIconSize: CGFloat
    /// The largest icon box that fits in the grid's area, set once it's laid out.
    private var maxIconBox = NSSize(width: 256, height: 256)
    private var sizeSlider: NSSlider?
    private let scale: CGFloat
    private let gridLayout = NSCollectionViewFlowLayout()
    private let collectionView = GridCollectionView()
    private let scrollView = NSScrollView()
    private let token = CancellationToken()

    init(title: String, detail: String, icon: NSImage, items: [ArchiveNode],
         archive: ArchiveReader, listing: ArchiveListing, cacheDirectory: URL, scale: CGFloat) {
        self.items = items
        var positions: [Int: Int] = [:]
        for (position, node) in items.enumerated() {
            if let entry = node.entry { positions[entry.index] = position }
        }
        self.positions = positions
        jobs = Self.thumbnailJobs(in: items, cacheDirectory: cacheDirectory)
        self.scale = scale
        let saved = CGFloat(UserDefaults.standard.double(forKey: Self.iconSizeKey))
        requestedIconSize = jobs.isEmpty || saved == 0 ? Self.defaultIconSize : max(saved, Self.minIconSize)
        super.init(frame: .zero)
        thumbnails.totalCostLimit = 100 << 20
        buildViews(title: title, detail: detail, icon: icon)
        extractImages(archive: archive, listing: listing)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Stops extracting images for thumbnails.
    func cancel() {
        token.cancel()
    }

    // MARK: - Views

    private func buildViews(title: String, detail: String, icon: NSImage) {
        let iconView = NSImageView(image: icon)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 32).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        for label in [titleLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let texts = NSStackView(views: [titleLabel, detailLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        // A spacer takes up the spare width, keeping the icon and text at the leading edge and the
        // size slider at the trailing edge.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: jobs.isEmpty ? [iconView, texts, spacer] : [iconView, texts, spacer, makeSizeSlider()])
        header.distribution = .fill
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        let separator = NSBox()
        separator.boxType = .separator

        gridLayout.itemSize = Self.itemSize(for: iconBox)
        gridLayout.minimumInteritemSpacing = 6
        gridLayout.minimumLineSpacing = 6
        gridLayout.sectionInset = NSEdgeInsets(top: Self.gridInset, left: Self.gridInset, bottom: Self.gridInset, right: Self.gridInset)
        collectionView.collectionViewLayout = gridLayout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.dataSource = self
        collectionView.register(GridItem.self, forItemWithIdentifier: GridItem.identifier)
        collectionView.onDoubleClick = { [weak self] position in
            guard let self, self.items.indices.contains(position) else { return }
            self.onUncompress?(self.items[position])
        }
        collectionView.menuForItem = { [weak self] position in
            guard let self, self.items.indices.contains(position) else { return nil }
            let node = self.items[position]
            let item = NSMenuItem(title: PreviewViewController.uncompressTitle(for: [node]),
                                  action: #selector(self.uncompressFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = node
            let menu = NSMenu()
            menu.addItem(item)
            return menu
        }

        let scroll = scrollView
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        // Pinned edge to edge (not in a stack view, which let a short header shrink to its content).
        for view in [header, separator, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if items.isEmpty {
            let empty = NSTextField(labelWithString: "Empty folder")
            empty.textColor = .secondaryLabelColor
            empty.translatesAutoresizingMaskIntoConstraints = false
            addSubview(empty)
            NSLayoutConstraint.activate([
                empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
                empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            ])
        }
    }

    @objc private func uncompressFromMenu(_ item: NSMenuItem) {
        guard let node = item.representedObject as? ArchiveNode else { return }
        onUncompress?(node)
    }

    // MARK: - Icon size

    private var maxIconSize: CGFloat { max(maxIconBox.width, maxIconBox.height) }
    private var iconSize: CGFloat { max(Self.minIconSize, min(requestedIconSize, maxIconSize)) }

    /// The box an icon is fitted to: square, until it's as wide or as tall as the grid's area allows.
    private var iconBox: NSSize {
        NSSize(width: min(iconSize, maxIconBox.width), height: min(iconSize, maxIconBox.height))
    }

    /// The size of a grid cell for an icon box, with room for two lines of name.
    fileprivate static func itemSize(for box: NSSize) -> NSSize {
        NSSize(width: max(104, box.width + cellPadding.width), height: box.height + cellPadding.height)
    }

    override func layout() {
        super.layout()
        updateMaxIconBox()
    }

    /// Fits the largest icon box to the grid's area, so at the slider's right end one image fills it.
    private func updateMaxIconBox() {
        let size = scrollView.frame.size
        guard size.width > 0, size.height > 0 else { return }
        // A legacy scroller takes width whenever it shows; leave room for it so icons don't flip size.
        let scroller = scrollView.scrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let box = NSSize(
            width: max(Self.minIconSize, (size.width - scroller - 2 * Self.gridInset - Self.cellPadding.width - 1).rounded(.down)),
            height: max(Self.minIconSize, (size.height - 2 * Self.gridInset - Self.cellPadding.height).rounded(.down)))
        guard box != maxIconBox else { return }
        let oldBox = iconBox
        maxIconBox = box
        sizeSlider?.maxValue = maxIconSize
        sizeSlider?.doubleValue = iconSize
        if iconBox != oldBox { applyIconBox(keepingTopItem: false) }
    }

    /// A slider like Finder's icon size slider, between small and large photo symbols.
    private func makeSizeSlider() -> NSView {
        let slider = NSSlider(value: iconSize, minValue: Self.minIconSize, maxValue: maxIconSize,
                              target: self, action: #selector(iconSizeChanged(_:)))
        slider.controlSize = .small
        slider.isContinuous = true
        slider.toolTip = "Icon size"
        slider.setAccessibilityLabel("Icon size")
        slider.widthAnchor.constraint(equalToConstant: 100).isActive = true
        sizeSlider = slider
        func symbol(pointSize: CGFloat) -> NSImageView {
            let image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
            let view = NSImageView(image: image ?? NSImage())
            view.contentTintColor = .secondaryLabelColor
            return view
        }
        let control = NSStackView(views: [symbol(pointSize: 9), slider, symbol(pointSize: 14)])
        control.spacing = 6
        control.setContentHuggingPriority(.required, for: .horizontal)
        return control
    }

    @objc private func iconSizeChanged(_ slider: NSSlider) {
        // At the right end the icons follow the pane's size, even after it changes.
        let requested = slider.doubleValue >= slider.maxValue - 0.5 ? Self.largestIconSize : slider.doubleValue.rounded()
        guard requested != requestedIconSize else { return }
        UserDefaults.standard.set(Double(requested), forKey: Self.iconSizeKey)
        let oldBox = iconBox
        requestedIconSize = requested
        if iconBox != oldBox { applyIconBox(keepingTopItem: true) }
    }

    private func applyIconBox(keepingTopItem: Bool) {
        // Keep the item at the top of the view in place, as Finder does. ("Visible" items include
        // some prepared outside the view, so they're filtered to the ones actually in view.)
        let visibleRect = collectionView.visibleRect
        let anchor = !keepingTopItem || visibleRect.minY <= 0 ? nil : collectionView.indexPathsForVisibleItems()
            .filter { gridLayout.layoutAttributesForItem(at: $0)?.frame.intersects(visibleRect) == true }
            .min()
        let box = iconBox
        gridLayout.itemSize = Self.itemSize(for: box)
        for case let item as GridItem in collectionView.visibleItems() {
            guard let path = collectionView.indexPath(for: item) else { continue }
            item.setIconBox(box)
            if let index = items[path.item].entry?.index, let image = thumbnail(forEntry: index) { item.setThumbnail(image) }
        }
        if let anchor {
            scrollView.layoutSubtreeIfNeeded()
            if let frame = gridLayout.layoutAttributesForItem(at: anchor)?.frame {
                collectionView.scroll(NSPoint(x: 0, y: max(0, frame.minY - gridLayout.minimumLineSpacing)))
            }
        }
    }

    // MARK: - Thumbnails

    private static func thumbnailJobs(in items: [ArchiveNode], cacheDirectory: URL) -> [ThumbnailJob] {
        let scratch = cacheDirectory.appendingPathComponent("thumbnails", isDirectory: true)
        var jobs: [ThumbnailJob] = []
        var budget = maxThumbnailBytes
        var keptBudget = maxKeptBytes
        for node in items {
            guard jobs.count < maxThumbnails, let entry = node.entry, entry.kind == .file, !entry.isEncrypted,
                  let type = UTType(filenameExtension: (node.name as NSString).pathExtension), type.conforms(to: .image)
            else { continue }
            // An unknown size is assumed large, so the image is replaced by a smaller copy.
            let size = entry.size ?? maxKeptImageBytes * 4
            let isRaw = type.conforms(to: .rawImage)
            // Usually only the start of a RAW file is read.
            let cost = isRaw ? min(size, maxKeptImageBytes) : size
            guard size <= maxImageBytes, cost <= budget else { continue }
            budget -= cost
            let previewURL = entry.previewURL(in: cacheDirectory)
            if !isRaw, entry.size != nil, size <= maxKeptImageBytes, size <= keptBudget {
                keptBudget -= size
                jobs.append(ThumbnailJob(target: .init(entry: entry, url: previewURL), previewURL: previewURL,
                                         reducedURL: nil, readsStart: false))
            } else {
                // Extracted (if at all) to scratch, not where its preview goes, as it's deleted once reduced.
                jobs.append(ThumbnailJob(target: .init(entry: entry, url: entry.previewURL(in: scratch)), previewURL: previewURL,
                                         reducedURL: scratch.appendingPathComponent("\(entry.index).thumbnail"), readsStart: isRaw))
            }
        }
        return jobs
    }

    private func extractImages(archive: ArchiveReader, listing: ArchiveListing) {
        guard !jobs.isEmpty else { return }
        let jobs = jobs
        let maxImageBytes = Self.maxImageBytes
        let token = token
        Task.detached(priority: .utility) { [weak self] in
            func deliver(_ index: Int, _ url: URL) {
                guard !token.isCancelled else { return }
                Task { @MainActor [weak self] in self?.didExtract(index, url) }
            }
            let fm = FileManager.default
            // Images extracted earlier (e.g. previewed) don't need another pass over the archive.
            var remaining: [ArchiveReader.Target] = []
            var reducedURLs: [Int: URL] = [:]
            var raws: Set<Int> = []
            var reducedBytes = 0
            /// Makes a smaller copy, unless they've used up their space.
            func reduce(_ source: CGImageSource?, orientation: Int?, to url: URL) -> Bool {
                guard reducedBytes < Self.maxReducedBytes, let source,
                      Self.writeReducedCopy(of: source, orientation: orientation, to: url) else { return false }
                reducedBytes += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return true
            }
            for job in jobs {
                let index = job.target.entry.index
                if fm.fileExists(atPath: job.previewURL.path) {
                    deliver(index, job.previewURL)
                } else if let reduced = job.reducedURL, fm.fileExists(atPath: reduced.path) {
                    deliver(index, reduced)
                } else {
                    remaining.append(job.target)
                    reducedURLs[index] = job.reducedURL
                    if job.readsStart { raws.insert(index) }
                }
            }
            guard !remaining.isEmpty, !token.isCancelled else { return }
            // A RAW file's embedded preview is made into the smaller copy; one without a usable
            // preview is written out and decoded after all.
            func readStart(_ target: ArchiveReader.Target, _ data: Data, isWhole: Bool) -> ArchiveReader.StartDecision {
                let index = target.entry.index
                switch RawPreview.find(in: data, isWhole: isWhole) {
                case .needMore(let count):
                    return .needMore(count)
                case .found(let jpeg, let orientation):
                    guard let reduced = reducedURLs[index], reducedBytes < Self.maxReducedBytes else { return .done }
                    guard reduce(CGImageSourceCreateWithData(jpeg as CFData, nil), orientation: orientation, to: reduced)
                    else { return .writeFile }
                    deliver(index, reduced)
                    return .done
                case .none:
                    return .writeFile
                }
            }
            try? archive.extractFiles(remaining, of: listing, maxBytes: maxImageBytes, startsOf: raws,
                                      maxStartBytes: RawPreview.maxBytes, readStart: readStart,
                                      isCancelled: { token.isCancelled }) { target in
                let index = target.entry.index
                guard let reduced = reducedURLs[index] else { return deliver(index, target.url) }
                // Reduced right away, so only one large image is on disk at a time.
                let didReduce = !token.isCancelled && reduce(
                    CGImageSourceCreateWithURL(target.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                    orientation: nil, to: reduced)
                try? fm.removeItem(at: target.url.deletingLastPathComponent())
                if didReduce { deliver(index, reduced) }
            }
        }
    }

    private func didExtract(_ index: Int, _ url: URL) {
        guard !token.isCancelled, let position = positions[index] else { return }
        imageFiles[index] = url
        // Only a visible item needs its thumbnail now; others get theirs when scrolled into view.
        if let item = collectionView.item(at: IndexPath(item: position, section: 0)) as? GridItem,
           let image = thumbnail(forEntry: index) {
            item.setThumbnail(image)
        }
    }

    /// Thumbnails come in a few sizes, so dragging the slider doesn't remake them at every step.
    private var thumbnailPixelSize: CGFloat {
        let box = iconBox
        var points: CGFloat = 64
        while points < max(box.width, box.height) { points *= 2 }
        return points * scale
    }

    /// The entry's thumbnail if one has been made. Starts making one, or a sharper one for the
    /// current icon size, when the image has been extracted; `show` then updates the item.
    private func thumbnail(forEntry index: Int) -> NSImage? {
        let cached = thumbnails.object(forKey: index as NSNumber)
        let pixelSize = thumbnailPixelSize * scale
        if (cached?.pixelSize ?? 0) < pixelSize, (decoding[index] ?? 0) < pixelSize,
           !undecodable.contains(index), let url = imageFiles[index] {
            decoding[index] = pixelSize
            let token = token
            Task.detached(priority: .userInitiated) { [weak self] in
                let thumbnail = token.isCancelled ? nil : Self.thumbnail(of: url, maxPixelSize: pixelSize)
                Task { @MainActor [weak self] in self?.show(thumbnail, pixelSize: pixelSize, forEntry: index) }
            }
        }
        return cached?.image
    }

    private func show(_ decoded: (image: CGImage, size: CGSize)?, pixelSize: CGFloat, forEntry index: Int) {
        if decoding[index] == pixelSize { decoding[index] = nil }
        guard !token.isCancelled, let position = positions[index] else { return }
        guard let (image, size) = decoded else {
            undecodable.insert(index)
            return
        }
        // A sharper one may have arrived first.
        if let cached = thumbnails.object(forKey: index as NSNumber), cached.pixelSize >= pixelSize { return }
        let thumbnail = Thumbnail(image: NSImage(cgImage: image, size: size), pixelSize: pixelSize)
        thumbnails.setObject(thumbnail, forKey: index as NSNumber, cost: image.bytesPerRow * image.height)
        (collectionView.item(at: IndexPath(item: position, section: 0)) as? GridItem)?.setThumbnail(thumbnail.image)
    }

    /// A small version of the image at `url`, decoded without loading the full-size image, and the
    /// size in points the image itself is shown at (as `NSImage` sizes it, from its resolution), so a
    /// thumbnail is never shown larger than the image's own preview.
    nonisolated private static func thumbnail(of url: URL, maxPixelSize: CGFloat) -> (image: CGImage, size: CGSize)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let points = source.longestSideInPoints ?? CGFloat(max(image.width, image.height))
        let factor = points / CGFloat(max(image.width, image.height, 1))
        return (image, CGSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor))
    }

    /// Writes a copy of an image whose longest side is at most `reducedPixelSize`, as JPEG (or PNG, to
    /// keep transparency), with its resolution scaled so it's still shown at the original's size, and
    /// with `orientation` if given (a RAW file's, for its embedded preview), else the image's own.
    /// Returns false if the image can't be read or written.
    nonisolated private static func writeReducedCopy(of source: CGImageSource, orientation: Int?, to destination: URL) -> Bool {
        // The pixels are kept as stored; the orientation is applied when the copy is shown.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: reducedPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return false }
        let isOpaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let partial = destination.appendingPathExtension("partial")
        guard let output = CGImageDestinationCreateWithURL(
            partial as CFURL, (isOpaque ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil)
        else { return false }
        let own = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.8,
            kCGImagePropertyOrientation: orientation ?? (own?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1,
        ]
        if let points = source.longestSideInPoints {
            let dpi = CGFloat(max(image.width, image.height)) * 72 / points
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }
        CGImageDestinationAddImage(output, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(output) else {
            try? FileManager.default.removeItem(at: partial)
            return false
        }
        return (try? FileManager.default.moveItem(at: partial, to: destination)) != nil
    }
}

extension FolderView: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: GridItem.identifier, for: indexPath)
        let node = items[indexPath.item]
        let preview = node.entry.flatMap { self.thumbnail(forEntry: $0.index) }
        (item as? GridItem)?.configure(name: node.name, image: preview ?? PreviewViewController.icon(for: node),
                                       isThumbnail: preview != nil, iconBox: iconBox)
        return item
    }
}

extension CGImageSource {
    /// The longest side of the (first) image, in points from its pixels and resolution, as `NSImage`
    /// sizes it. (Rotation doesn't change it.)
    var longestSideInPoints: CGFloat? {
        let properties = CGImageSourceCopyPropertiesAtIndex(self, 0, nil) as? [CFString: Any] ?? [:]
        func number(_ key: CFString) -> CGFloat { CGFloat((properties[key] as? NSNumber)?.doubleValue ?? 0) }
        let pixels = max(number(kCGImagePropertyPixelWidth), number(kCGImagePropertyPixelHeight))
        let dpi = number(kCGImagePropertyDPIWidth)
        return pixels > 0 ? pixels * 72 / (dpi > 0 ? dpi : 72) : nil
    }
}

extension ArchiveEntry {
    /// Where a preview extracts this entry: a folder of its own, so the real file name (and so the
    /// file's type) is kept.
    func previewURL(in directory: URL) -> URL {
        directory.appendingPathComponent(String(index), isDirectory: true).appendingPathComponent(components.last ?? "")
    }
}

// MARK: - Grid pieces

/// Reports double-clicks, and gives each item a context menu.
private final class GridCollectionView: NSCollectionView {
    var onDoubleClick: ((Int) -> Void)?
    var menuForItem: ((Int) -> NSMenu?)?

    /// Selects the item clicked, as Finder does, so it's clear which one the menu is for.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return nil }
        selectionIndexPaths = [path]
        return menuForItem?(path.item)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            onDoubleClick?(path.item)
        }
    }
}

/// An icon (or thumbnail) above a name of up to two lines.
private final class GridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("GridItem")

    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private lazy var iconWidth = icon.widthAnchor.constraint(equalToConstant: FolderView.defaultIconSize)
    private lazy var iconHeight = icon.heightAnchor.constraint(equalToConstant: FolderView.defaultIconSize)

    override func loadView() {
        let background = SelectionBackground()
        icon.imageScaling = .scaleProportionallyUpOrDown
        // As in Finder, a wide image sits just above its name rather than in the middle of the square.
        icon.imageAlignment = .alignBottom
        label.alignment = .center
        label.font = .systemFont(ofSize: 11)
        label.maximumNumberOfLines = 2
        label.cell?.truncatesLastVisibleLine = true
        label.preferredMaxLayoutWidth = FolderView.itemSize(
            for: NSSize(width: FolderView.defaultIconSize, height: FolderView.defaultIconSize)).width - 8
        for view in [icon, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: background.topAnchor, constant: 6),
            icon.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            iconWidth,
            iconHeight,
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -4),
        ])
        view = background
        imageView = icon
        textField = label
    }

    func configure(name: String, image: NSImage, isThumbnail: Bool, iconBox: NSSize) {
        label.stringValue = name
        view.toolTip = name
        if isThumbnail {
            setThumbnail(image)
        } else {
            icon.image = image
            icon.imageScaling = .scaleProportionallyUpOrDown
        }
        setIconBox(iconBox)
    }

    func setIconBox(_ box: NSSize) {
        iconWidth.constant = box.width
        iconHeight.constant = box.height
        label.preferredMaxLayoutWidth = FolderView.itemSize(for: box).width - 8
    }

    /// A thumbnail is never enlarged past the image's own size, as when the image is selected.
    func setThumbnail(_ image: NSImage) {
        icon.image = image
        icon.imageScaling = .scaleProportionallyDown
    }

    override var isSelected: Bool {
        didSet { (view as? SelectionBackground)?.isSelected = isSelected }
    }
}

/// An image to extract for thumbnails: to where its preview goes, or for a large one, to a scratch
/// file that's replaced by a smaller copy at `reducedURL`.
private struct ThumbnailJob: Sendable {
    let target: ArchiveReader.Target
    /// Where the image's preview goes, used if it's already there.
    let previewURL: URL
    let reducedURL: URL?
    /// A camera RAW file, whose embedded preview is read from its start.
    let readsStart: Bool
}

/// A thumbnail and the pixel size it was made for.
private final class Thumbnail {
    let image: NSImage
    let pixelSize: CGFloat

    init(image: NSImage, pixelSize: CGFloat) {
        self.image = image
        self.pixelSize = pixelSize
    }
}

/// A rounded highlight behind a selected item. Quick Look's window isn't key (Finder keeps the
/// focus), so it uses the unemphasized selection color, as Finder does for an inactive window.
private final class SelectionBackground: NSView {
    var isSelected = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
    }
}
