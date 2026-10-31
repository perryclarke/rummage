import Cocoa

/// A read-only grid showing a `Spreadsheet`, with row numbers, column letters and a tab per sheet.
@MainActor
final class SpreadsheetView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let spreadsheet: Spreadsheet
    private var sheet: Spreadsheet.Sheet
    private let tableView = NSTableView()
    private let noteLabel = NSTextField(labelWithString: "")
    private let bottomBar = NSStackView()
    private let font = NSFont.systemFont(ofSize: 12)
    private lazy var boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)

    init(_ spreadsheet: Spreadsheet) {
        self.spreadsheet = spreadsheet
        sheet = spreadsheet.sheets.first ?? Spreadsheet.Sheet(name: "")
        super.init(frame: .zero)

        tableView.style = .plain
        tableView.rowHeight = 20
        tableView.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        tableView.gridColor = .separatorColor
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnReordering = false
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

        noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.lineBreakMode = .byTruncatingTail
        noteLabel.alignment = .right
        // The note takes up the spare width, keeping the sheet tabs on the left.
        noteLabel.setContentHuggingPriority(.defaultLow - 50, for: .horizontal)
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bottomBar.distribution = .fill
        bottomBar.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 10)
        bottomBar.spacing = 12
        if spreadsheet.sheets.count > 1 {
            bottomBar.addArrangedSubview(makeSheetTabs())
        }
        bottomBar.addArrangedSubview(noteLabel)

        let stack = NSStackView(views: [scroll, bottomBar])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        showSheet(at: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Sheet tabs in a scroll view, so that workbooks with many sheets don't widen the preview.
    private func makeSheetTabs() -> NSView {
        let tabs = NSSegmentedControl(labels: spreadsheet.sheets.map(\.name), trackingMode: .selectOne,
                                      target: self, action: #selector(selectSheet(_:)))
        tabs.controlSize = .small
        tabs.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tabs.selectedSegment = 0
        tabs.sizeToFit()

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.documentView = tabs
        let width = tabs.frame.width
        let preferredWidth = scroll.widthAnchor.constraint(equalToConstant: width)
        preferredWidth.priority = .defaultLow + 10
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(equalToConstant: tabs.frame.height),
            scroll.widthAnchor.constraint(lessThanOrEqualToConstant: width),
            preferredWidth,
        ])
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return scroll
    }

    @objc private func selectSheet(_ sender: NSSegmentedControl) {
        showSheet(at: sender.selectedSegment)
    }

    private func showSheet(at index: Int) {
        guard spreadsheet.sheets.indices.contains(index) else { return }
        sheet = spreadsheet.sheets[index]
        for column in tableView.tableColumns.reversed() {
            tableView.removeTableColumn(column)
        }

        let numbers = NSTableColumn(identifier: .rowNumber)
        numbers.title = ""
        numbers.width = CGFloat(String(sheet.rows.count).count) * 7 + 16
        numbers.resizingMask = []
        tableView.addTableColumn(numbers)
        for index in 0..<sheet.columnCount {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = Spreadsheet.columnName(index)
            column.headerCell.alignment = .center
            column.minWidth = 24
            column.width = sheet.columnWidths[index].map { CGFloat($0) } ?? estimatedWidth(ofColumn: index)
            tableView.addTableColumn(column)
        }
        tableView.reloadData()
        tableView.scroll(.zero)

        if sheet.rows.isEmpty {
            noteLabel.stringValue = "Empty sheet"
        } else if sheet.isTruncated {
            noteLabel.stringValue = "Showing up to \(Spreadsheet.maxRows.formatted()) rows and \(Spreadsheet.maxColumns) columns"
        } else {
            noteLabel.stringValue = ""
        }
        bottomBar.isHidden = spreadsheet.sheets.count == 1 && noteLabel.stringValue.isEmpty
    }

    /// Fits the column to its contents in the first rows, within limits.
    private func estimatedWidth(ofColumn column: Int) -> CGFloat {
        var longest = 0
        for row in sheet.rows.prefix(200) where column < row.count {
            longest = max(longest, row[column]?.text.count ?? 0)
        }
        return min(max(CGFloat(longest) * 7 + 12, 44), 320)
    }

    // MARK: - Table view

    func numberOfRows(in tableView: NSTableView) -> Int {
        sheet.rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let view = tableView.makeView(withIdentifier: .cell, owner: self) as? NSTableCellView ?? makeCellView()
        guard let field = view.textField else { return view }

        if tableColumn.identifier == .rowNumber {
            field.stringValue = String(row + 1)
            field.alignment = .center
            field.font = font
            field.textColor = .secondaryLabelColor
            return view
        }
        let cells = sheet.rows[row]
        let index = Int(tableColumn.identifier.rawValue) ?? 0
        let cell = index < cells.count ? cells[index] : nil
        let text = cell?.text ?? ""
        field.stringValue = text.contains("\n") ? text.replacingOccurrences(of: "\n", with: " ") : text
        field.font = cell?.isBold == true ? boldFont : font
        field.textColor = .labelColor
        switch cell?.alignment ?? .left {
        case .left: field.alignment = .left
        case .center: field.alignment = .center
        case .right: field.alignment = .right
        }
        return view
    }

    private func makeCellView() -> NSTableCellView {
        let view = NSTableCellView()
        view.identifier = .cell
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(field)
        view.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3),
            field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3),
            field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let rowNumber = NSUserInterfaceItemIdentifier("rowNumber")
    static let cell = NSUserInterfaceItemIdentifier("cell")
}
