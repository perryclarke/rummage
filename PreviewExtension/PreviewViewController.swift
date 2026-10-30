import Cocoa
import Quartz
import UniformTypeIdentifiers

final class PreviewViewController: NSViewController, QLPreviewingController {
    /// Entries larger than this are not extracted for preview.
    private static let maxPreviewSize: Int64 = 1 << 30

    private var archiveURL: URL?
    private var listing: ArchiveListing?
    private var root = ArchiveNode(name: "", path: [])

    private let outlineView = NSOutlineView()
    private let detailContainer = NSView()
    private var previewView: NSView?
    private let messageView = MessageView()

    private let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("QLZip-\(UUID().uuidString)", isDirectory: true)
    private var extractionToken: CancellationToken?
    private var didSetInitialDivider = false

    deinit {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    override func loadView() {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = outlineView
        scroll.drawsBackground = false

        let nameColumn = NSTableColumn(identifier: .name)
        nameColumn.title = "Name"
        nameColumn.resizingMask = .autoresizingMask
        let sizeColumn = NSTableColumn(identifier: .size)
        sizeColumn.title = "Size"
        sizeColumn.width = 64
        sizeColumn.minWidth = 50
        sizeColumn.resizingMask = .userResizingMask
        sizeColumn.headerCell.alignment = .right
        outlineView.addTableColumn(nameColumn)
        outlineView.addTableColumn(sizeColumn)
        outlineView.outlineTableColumn = nameColumn
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.style = .sourceList
        outlineView.usesAutomaticRowHeights = false
        outlineView.rowHeight = 22
        outlineView.allowsMultipleSelection = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(toggleExpanded)

        detailContainer.addSubview(messageView)
        messageView.pinEdges(to: detailContainer)

        split.addArrangedSubview(scroll)
        split.addArrangedSubview(detailContainer)
        split.setHoldingPriority(.defaultLow + 10, forSubviewAt: 0)
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        detailContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        view = split
        preferredContentSize = NSSize(width: 980, height: 620)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !didSetInitialDivider, let split = view as? NSSplitView {
            didSetInitialDivider = true
            split.setPosition(320, ofDividerAt: 0)
        }
        view.window?.makeFirstResponder(outlineView)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        archiveURL = url
        Self.removeStaleWorkDirectories()
        let reader = ArchiveReader(url: url)
        let listing = try await Task.detached(priority: .userInitiated) { try reader.list() }.value
        self.listing = listing
        root = ArchiveNode.build(from: listing.entries)
        outlineView.reloadData()

        // A single top-level folder is the common case; open it so the contents are visible immediately.
        if root.children.count == 1, root.children[0].isDirectory {
            outlineView.expandItem(root.children[0])
        }
        showSummary()
    }

    // MARK: - Detail pane

    private func showSummary() {
        guard let archiveURL, let listing else { return }
        let encrypted = listing.entries.contains { $0.isEncrypted }
        var details = "\(root.fileCount.formatted()) \(root.fileCount == 1 ? "file" : "files")"
        if !listing.isRaw { details += ", \(Self.format(bytes: root.totalSize)) uncompressed" }
        if !listing.formatDescription.isEmpty { details += "\n\(listing.formatDescription)" }
        if encrypted { details += "\nSome entries are encrypted" }
        showMessage(icon: NSWorkspace.shared.icon(forFile: archiveURL.path), title: archiveURL.lastPathComponent, detail: details)
    }

    private func showMessage(icon: NSImage?, title: String, detail: String?, busy: Bool = false) {
        removePreview()
        messageView.isHidden = false
        messageView.configure(icon: icon, title: title, detail: detail, busy: busy)
    }

    private func showPreview(of fileURL: URL, node: ArchiveNode, icon: NSImage, token: CancellationToken) async {
        let scale = view.window?.backingScaleFactor ?? 2
        let preview = await EntryPreview.makeView(for: fileURL, scale: scale)
        guard extractionToken === token else { return }
        guard let preview else {
            showMessage(icon: icon, title: node.name, detail: Self.details(for: node) + "\nNo preview available")
            return
        }
        removePreview()
        messageView.isHidden = true
        detailContainer.addSubview(preview)
        preview.pinEdges(to: detailContainer)
        previewView = preview
    }

    private func removePreview() {
        guard let previewView else { return }
        EntryPreview.tearDown(previewView)
        previewView.removeFromSuperview()
        self.previewView = nil
    }

    private func selectionDidChange() {
        extractionToken?.cancel()
        extractionToken = nil

        guard let node = outlineView.item(atRow: outlineView.selectedRow) as? ArchiveNode else {
            showSummary()
            return
        }
        if node.isDirectory {
            let count = node.children.count
            showMessage(
                icon: NSWorkspace.shared.icon(for: .folder),
                title: node.name,
                detail: "\(count.formatted()) \(count == 1 ? "item" : "items"), \(Self.format(bytes: node.totalSize))"
            )
            return
        }
        guard let entry = node.entry else { return }
        let icon = Self.icon(for: node)

        switch entry.kind {
        case .symlink:
            showMessage(icon: icon, title: node.name, detail: "Symbolic link")
            return
        case .other:
            showMessage(icon: icon, title: node.name, detail: "Special file — no preview")
            return
        case .file, .directory:
            break
        }
        if entry.isEncrypted {
            showMessage(icon: icon, title: node.name, detail: "Encrypted — can't be previewed")
            return
        }
        if let size = entry.size, size > Self.maxPreviewSize {
            showMessage(icon: icon, title: node.name, detail: "\(Self.format(bytes: size)) — too large to preview")
            return
        }

        // Each entry gets its own directory so the real filename (and so its type) is preserved.
        let destination = workDirectory
            .appendingPathComponent(String(entry.index), isDirectory: true)
            .appendingPathComponent(node.name)
        let token = CancellationToken()
        extractionToken = token
        if FileManager.default.fileExists(atPath: destination.path) {
            Task { await showPreview(of: destination, node: node, icon: icon, token: token) }
            return
        }
        extract(entry, of: node, to: destination, icon: icon, token: token)
    }

    private func extract(_ entry: ArchiveEntry, of node: ArchiveNode, to destination: URL, icon: NSImage, token: CancellationToken) {
        guard let archiveURL, let listing else { return }

        // Only show a spinner if extraction is noticeably slow, to avoid flicker while arrowing through files.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !token.isCancelled, !token.isFinished, self.extractionToken === token else { return }
            self.showMessage(icon: icon, title: node.name, detail: "Extracting…", busy: true)
        }

        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Bool, Error> in
                let fm = FileManager.default
                let partial = destination.deletingLastPathComponent().appendingPathComponent(".partial-\(UUID().uuidString)")
                do {
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let finished = try ArchiveReader(url: archiveURL).extract(
                        index: entry.index, of: listing, to: partial, isCancelled: { token.isCancelled })
                    if finished {
                        try fm.moveItem(at: partial, to: destination)
                    } else {
                        try? fm.removeItem(at: partial)
                    }
                    return .success(finished)
                } catch {
                    try? fm.removeItem(at: partial)
                    return .failure(error)
                }
            }.value
            token.finish()

            guard let self, self.extractionToken === token else { return }
            switch result {
            case .success(true):
                await self.showPreview(of: destination, node: node, icon: icon, token: token)
            case .success(false):
                break
            case .failure(let error):
                self.showMessage(icon: icon, title: node.name, detail: "Couldn't extract: \(error.localizedDescription)")
            }
        }
    }

    @objc private func toggleExpanded() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? ArchiveNode, node.isDirectory else { return }
        if outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        } else {
            outlineView.expandItem(node)
        }
    }

    // MARK: - Helpers

    private static func format(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func details(for node: ArchiveNode) -> String {
        var parts = [format(bytes: node.totalSize)]
        if let modified = node.entry?.modified {
            parts.append(modified.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }

    /// Deletes extraction folders left behind when Quick Look killed the extension before deinit ran.
    private static func removeStaleWorkDirectories() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        let dirs = (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for dir in dirs where dir.lastPathComponent.hasPrefix("QLZip-") {
            let modified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fm.removeItem(at: dir)
            }
        }
    }

    private static var iconCache: [String: NSImage] = [:]

    fileprivate static func icon(for node: ArchiveNode) -> NSImage {
        if node.isDirectory { return NSWorkspace.shared.icon(for: .folder) }
        let ext = (node.name as NSString).pathExtension.lowercased()
        if let cached = iconCache[ext] { return cached }
        let type = UTType(filenameExtension: ext) ?? .data
        let icon = NSWorkspace.shared.icon(for: type)
        iconCache[ext] = icon
        return icon
    }
}

// MARK: - Outline view

extension PreviewViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? ArchiveNode) ?? root).children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? ArchiveNode) ?? root).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ArchiveNode)?.isDirectory == true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ArchiveNode, let column = tableColumn else { return nil }
        let cell = outlineView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView
            ?? Self.makeCell(identifier: column.identifier)
        switch column.identifier {
        case .name:
            cell.textField?.stringValue = node.name
            cell.imageView?.image = Self.icon(for: node)
        default:
            cell.textField?.stringValue = node.isDirectory || node.entry?.size == nil ? "--" : Self.format(bytes: node.totalSize)
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        selectionDidChange()
    }

    private static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text

        if identifier == .name {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyUpOrDown
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            text.alignment = .right
            text.textColor = .secondaryLabelColor
            text.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(greaterThanOrEqualTo: cell.leadingAnchor, constant: 2),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }
}

// MARK: - Supporting types

private extension NSUserInterfaceItemIdentifier {
    static let name = NSUserInterfaceItemIdentifier("name")
    static let size = NSUserInterfaceItemIdentifier("size")
}

private final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    var isFinished: Bool { lock.withLock { finished } }
    func cancel() { lock.withLock { cancelled = true } }
    func finish() { lock.withLock { finished = true } }
}

/// Centered icon + title + detail, used for folders, the archive summary and errors.
private final class MessageView: NSView {
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.widthAnchor.constraint(equalToConstant: 128).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 128).isActive = true
        titleLabel.font = .boldSystemFont(ofSize: 15)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.alignment = .center
        detailLabel.alignment = .center
        detailLabel.textColor = .secondaryLabelColor
        spinner.style = .spinning
        spinner.controlSize = .small

        let stack = NSStackView(views: [imageView, titleLabel, detailLabel, spinner])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(icon: NSImage?, title: String, detail: String?, busy: Bool) {
        imageView.image = icon
        titleLabel.stringValue = title
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail == nil
        spinner.isHidden = !busy
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }
}

private extension NSView {
    func pinEdges(to other: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor),
            trailingAnchor.constraint(equalTo: other.trailingAnchor),
            topAnchor.constraint(equalTo: other.topAnchor),
            bottomAnchor.constraint(equalTo: other.bottomAnchor),
        ])
    }
}
