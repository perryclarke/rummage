import Cocoa
import os
import Quartz
import UniformTypeIdentifiers

final class PreviewViewController: NSViewController, QLPreviewingController {
    /// Entries larger than this are not extracted for preview.
    private static let maxPreviewSize: Int64 = 1 << 30

    private var archiveURL: URL?
    private var listing: ArchiveListing?
    private var root = ArchiveNode(name: "", path: [])

    private let outlineView = NSOutlineView()
    private let statusBar = StatusBar()
    private let detailContainer = NSView()
    private var previewView: NSView?
    private let messageView = MessageView()

    private let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("QLZip-\(UUID().uuidString)", isDirectory: true)
    private var extractionToken: CancellationToken?
    private var didSetInitialDivider = false
    private var folderChooser: NSOpenPanel?
    /// Identifies the latest uncompress, so an earlier one finishing doesn't overwrite its status.
    private var uncompressCount = 0

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
        outlineView.allowsMultipleSelection = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(uncompressClickedItems)
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        detailContainer.addSubview(messageView)
        messageView.pinEdges(to: detailContainer)

        let listPane = NSStackView(views: [scroll, statusBar])
        listPane.orientation = .vertical
        listPane.alignment = .width
        listPane.spacing = 0

        split.addArrangedSubview(listPane)
        split.addArrangedSubview(detailContainer)
        split.setHoldingPriority(.defaultLow + 10, forSubviewAt: 0)
        listPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
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
        disableQuickLookDoubleClick()
    }

    /// Quick Look opens the archive in its default app (Archive Utility, which extracts everything)
    /// when anything in a preview is double-clicked. Here a double-click uncompresses the clicked
    /// item instead, so turn off Quick Look's recognizer on the views hosting this preview.
    private func disableQuickLookDoubleClick() {
        var ancestor = view.superview
        while let current = ancestor {
            for case let recognizer as NSClickGestureRecognizer in current.gestureRecognizers
            where recognizer.numberOfClicksRequired == 2 {
                recognizer.isEnabled = false
            }
            ancestor = current.superview
        }
    }

    func preparePreviewOfFile(at url: URL) async throws {
        archiveURL = url
        Self.removeStaleWorkDirectories()
        let reader = ArchiveReader(url: url)
        let listingTask = Task.detached(priority: .userInitiated) { try reader.list() }

        // Quick Look shows nothing until this method returns. Listing usually takes milliseconds, but
        // compressed tarballs must be decompressed in full to list them, which can take a while; then
        // return early with a progress message and finish listing in the background.
        // (Finder downloads files that are still in iCloud before it contacts this extension at all,
        // so there's no way to show progress for that here.)
        if let result = await Self.result(of: listingTask, within: .milliseconds(400)) {
            show(try result.get()) // a corrupt archive throws, so Quick Look falls back to its own preview
            return
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        showMessage(icon: icon, title: url.lastPathComponent, detail: "Reading archive…", busy: true)
        Task { [weak self] in
            let result = await listingTask.result
            guard let self else { return }
            switch result {
            case .success(let listing):
                self.show(listing)
            case .failure(let error):
                self.showMessage(icon: icon, title: url.lastPathComponent, detail: "Couldn’t read the archive: \(error.localizedDescription)")
            }
        }
    }

    private func show(_ listing: ArchiveListing) {
        self.listing = listing
        root = ArchiveNode.build(from: listing.entries)
        outlineView.reloadData()

        // A single top-level folder is the common case; open it so the contents are visible immediately.
        if root.children.count == 1, root.children[0].isDirectory {
            outlineView.expandItem(root.children[0])
        }
        showSummary()
    }

    /// The task's result if it finishes within `timeout`, otherwise nil (the task keeps running).
    private static func result<T: Sendable>(of task: Task<T, Error>, within timeout: Duration) async -> Result<T, Error>? {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { continuation in
            let resumeOnce = { @Sendable (value: Result<T, Error>?) in
                if resumed.withLock({ wasResumed in defer { wasResumed = true }; return !wasResumed }) {
                    continuation.resume(returning: value)
                }
            }
            Task { resumeOnce(await task.result) }
            Task {
                try? await Task.sleep(for: timeout)
                resumeOnce(nil)
            }
        }
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
        (preview as? MarkdownView)?.onCopyLink = { [weak self] in
            self?.statusBar.show("Link copied; Quick Look can’t open links", busy: false)
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

        if outlineView.selectedRowIndexes.count > 1 {
            let nodes = Self.outermost(outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? ArchiveNode })
            showMessage(
                icon: NSImage(named: NSImage.multipleDocumentsName),
                title: "\(nodes.count.formatted()) items",
                detail: Self.format(bytes: nodes.reduce(0) { $0 + $1.totalSize })
            )
            return
        }
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

    // MARK: - Uncompressing

    /// The items a double-click or the context menu acts on: the whole selection if the clicked
    /// row is part of it, otherwise just the clicked row.
    private func clickedNodes() -> [ArchiveNode] {
        let row = outlineView.clickedRow
        guard row >= 0 else { return [] }
        let selection = outlineView.selectedRowIndexes
        let rows = selection.contains(row) ? selection : IndexSet(integer: row)
        return Self.outermost(rows.compactMap { outlineView.item(atRow: $0) as? ArchiveNode })
    }

    @objc private func uncompressClickedItems() {
        chooseFolder(toUncompress: clickedNodes())
    }

    private func chooseFolder(toUncompress nodes: [ArchiveNode]) {
        guard let archiveURL, let listing, !nodes.isEmpty, folderChooser == nil else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Uncompress"
        panel.message = "Uncompress \(Self.describe(nodes))"
        panel.directoryURL = archiveURL.deletingLastPathComponent()
        folderChooser = panel
        let completion = { [weak self] (response: NSApplication.ModalResponse) in
            guard let self else { return }
            self.folderChooser = nil
            guard response == .OK, let folder = panel.url else { return }
            self.uncompress(nodes, into: folder, archiveURL: archiveURL, listing: listing)
        }
        // As a free-standing window the chooser can open behind Finder's Quick Look panel, which
        // floats above normal windows. A sheet is shown attached to the Quick Look window instead.
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func uncompress(_ nodes: [ArchiveNode], into folder: URL, archiveURL: URL, listing: ArchiveListing) {
        let uncompressor = Uncompressor(nodes: nodes, into: folder)
        let description = nodes.count == 1 ? "“\(nodes[0].name)”" : "\(nodes.count.formatted()) items"
        uncompressCount += 1
        let id = uncompressCount
        statusBar.show("Uncompressing \(description)…", busy: true)

        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try uncompressor.run(archive: archiveURL, listing: listing) }
            }.value
            guard let self, self.uncompressCount == id else { return }
            switch result {
            case .success:
                var status = "Uncompressed \(description) to “\(FileManager.default.displayName(atPath: folder.path))”"
                if uncompressor.skippedCount > 0 {
                    let count = uncompressor.skippedCount
                    status += " (skipped \(count.formatted()) encrypted \(count == 1 ? "file" : "files"))"
                }
                self.statusBar.show(status, busy: false)
            case .failure(let error):
                self.statusBar.show("Couldn’t uncompress \(description): \(error.localizedDescription)", busy: false)
            }
        }
    }

    /// Drops nodes inside a folder that's also in `nodes`, since the folder includes them.
    private static func outermost(_ nodes: [ArchiveNode]) -> [ArchiveNode] {
        let paths = Set(nodes.map(\.path))
        return nodes.filter { node in
            !(1..<max(node.path.count, 1)).contains { paths.contains(Array(node.path.prefix($0))) }
        }
    }

    /// “a.txt”; “a.txt”, “b.png”, and “c”; or “a.txt”, “b.png”, and 3 more items.
    private static func describe(_ nodes: [ArchiveNode]) -> String {
        let names = nodes.map { "“\($0.name)”" }
        guard names.count > 3 else { return ListFormatter.localizedString(byJoining: names) }
        return ListFormatter.localizedString(byJoining: names.prefix(2) + ["\((names.count - 2).formatted()) more items"])
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

extension PreviewViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let nodes = clickedNodes()
        guard !nodes.isEmpty else { return }
        let title = nodes.count == 1 ? "Uncompress “\(nodes[0].name)”…" : "Uncompress \(nodes.count.formatted()) Items…"
        menu.addItem(withTitle: title, action: #selector(uncompressClickedItems), keyEquivalent: "").target = self
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

/// A line under the file list reporting the progress of an uncompress, or a copied link; hidden
/// until the first one.
private final class StatusBar: NSView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        spinner.style = .spinning
        spinner.controlSize = .small
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [spinner, label])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        for view in [separator, stack] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: separator.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ text: String, busy: Bool) {
        isHidden = false
        label.stringValue = text
        toolTip = text
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
