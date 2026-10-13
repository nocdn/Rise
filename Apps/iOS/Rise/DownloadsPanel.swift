import QuickLookThumbnailing
import UIKit
import UniformTypeIdentifiers

/// More's Downloads: Site settings' title and X over a list laid out as on the Mac, each file's
/// thumbnail or icon beside its name, with its size or progress below. A row opens its file in
/// Quick Look; its dots open a menu to show it in Files, share it, or take it off the list. The
/// title's dots act on the whole list, or, in Multi Select, on the files ticked.
final class DownloadsPanel: UIView {
    /// A little taller than Site settings' rows, for a file's two lines.
    static let rowHeight: CGFloat = 64
    static let maximumVisibleRows = 4
    /// A touch darker than More's tiles in light mode, and lighter in dark mode.
    static let rowFill = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.07) : UIColor(red: 243/255, green: 244/255, blue: 247/255, alpha: 1) }
    static let pressedRowFill = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.14) : UIColor(red: 230/255, green: 231/255, blue: 235/255, alpha: 1) }
    static let pressedScale: CGFloat = 0.97

    /// Tall as Site settings for up to three downloads, and a little taller for more, scrolling past four.
    static func height(rows: Int) -> CGFloat {
        SiteSettingsPanel.rowsTop+CGFloat(min(max(rows, 3), maximumVisibleRows))*rowHeight
    }

    private let header = PanelHeader(title: "Downloads")
    var closeButton: AnimatedSymbolButton { header.closeButton }
    /// The dots after the title, for the whole list, headed by how many files there are.
    let listMenuButton = UIButton(type: .system)
    var buttons: [UIButton] { [closeButton, listMenuButton] }
    /// The rounded list, which scrolls once there are more downloads than fit.
    let list = List()
    private let empty = UILabel()
    private var rows: [Row] = []
    private var dividers: [UIView] = []
    var rowCount: Int { rows.count }
    var isScrollable: Bool { list.contentSize.height > list.bounds.height+0.5 }

    var open: ((MobileDownloads.Item) -> Void)?
    var menu: ((MobileDownloads.Item, UIButton) -> [UIMenuElement])?
    var listMenu: (() -> [UIMenuElement])?
    var onTouchDown: (() -> Void)?
    /// Multi Select: rows tick and untick rather than open, their icons turned into checkboxes.
    private(set) var isSelecting = false
    private(set) var selected: Set<UUID> = []
    var items: [MobileDownloads.Item] { rows.map(\.item) }

    /// The system's dots, drawn a little closer together.
    private static let listDots: UIImage = {
        let side: CGFloat = 3, step: CGFloat = 4.75
        return UIGraphicsImageRenderer(size: CGSize(width: 2*step+side, height: side)).image { context in
            UIColor.black.setFill()
            for index in 0..<3 {
                context.cgContext.fillEllipse(in: CGRect(x: CGFloat(index)*step, y: 0, width: side, height: side))
            }
        }.withRenderingMode(.alwaysTemplate)
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(header)
        listMenuButton.setImage(Self.listDots, for: .normal)
        listMenuButton.tintColor = .secondaryLabel
        listMenuButton.showsMenuAsPrimaryAction = true
        // As written, clearing last, rather than flipped to put the first item nearest the dots
        // when the menu opens upwards.
        listMenuButton.preferredMenuElementOrder = .fixed
        listMenuButton.accessibilityLabel = "Downloads Options"
        header.accessory = listMenuButton
        updateListMenu()
        list.layer.cornerCurve = .continuous
        list.layer.cornerRadius = MenuPanel.cornerRadius
        // Rows fill themselves, so one pressed shrinks away from its neighbours.
        list.backgroundColor = .clear
        list.delaysContentTouches = false
        list.showsHorizontalScrollIndicator = false
        list.alwaysBounceVertical = false
        addSubview(list)
        empty.text = "No downloads yet"
        empty.font = PanelHeader.font("OpenRunde-Medium", size: 16, fallbackWeight: .medium)
        empty.adjustsFontForContentSizeCategory = true
        empty.textColor = .secondaryLabel
        empty.textAlignment = .center
        list.addSubview(empty)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rebuilds the rows when downloads come or go; otherwise refreshes them in place.
    func reload(_ items: [MobileDownloads.Item]) {
        if items.map(\.id) == rows.map(\.item.id) {
            rows.forEach { $0.update() }
            updateListMenu()
            return
        }
        let kept = Dictionary(uniqueKeysWithValues: rows.map { ($0.item.id, $0) })
        rows.filter { row in !items.contains { $0.id == row.item.id } }.forEach { $0.removeFromSuperview() }
        rows = items.map { item in
            if let row = kept[item.id] { row.update(); return row }
            let row = Row(item: item)
            row.addAction(UIAction { [weak self, weak row] _ in
                guard let self, let row else { return }
                if isSelecting { toggle(row) } else if row.item.state == .finished { open?(row.item) }
            }, for: .primaryActionTriggered)
            row.setSelecting(isSelecting, animated: false)
            row.addAction(UIAction { [weak self] _ in self?.onTouchDown?() }, for: .touchDown)
            row.moreButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self, weak row] completion in
                guard let self, let row else { completion([]); return }
                completion(menu?(row.item, row.moreButton) ?? [])
            }])
            list.addSubview(row)
            return row
        }
        dividers.forEach { $0.removeFromSuperview() }
        dividers = rows.dropFirst().map { _ in
            let divider = UIView()
            divider.backgroundColor = .separator
            divider.isUserInteractionEnabled = false
            list.addSubview(divider)
            return divider
        }
        empty.isHidden = !rows.isEmpty
        list.backgroundColor = rows.isEmpty ? Self.rowFill : .clear
        selected.formIntersection(items.map(\.id))
        if rows.isEmpty { setSelecting(false, animated: false) }
        updateListMenu()
        setNeedsLayout()
    }

    func setSelecting(_ selecting: Bool, animated: Bool = true) {
        selected = []
        rows.forEach { $0.setChecked(false, animated: false) }
        if selecting != isSelecting {
            isSelecting = selecting
            rows.forEach { $0.setSelecting(selecting, animated: animated && window != nil) }
        }
        updateListMenu()
    }

    /// Ticks every file, or, if they all are already, none.
    func toggleAll() {
        let all = Set(items.map(\.id))
        selected = selected == all ? [] : all
        rows.forEach { $0.setChecked(selected.contains($0.item.id), animated: true) }
        updateListMenu()
    }

    private func toggle(_ row: Row) {
        let id = row.item.id
        if selected.remove(id) == nil { selected.insert(id) }
        row.setChecked(selected.contains(id), animated: true)
        updateListMenu()
    }

    /// The menu's heading counts the files; its actions are read when it opens.
    private func updateListMenu() {
        let count = isSelecting ? selected.count : rows.count
        let title = isSelecting ? (count == 0 ? "Select Files" : "\(count) selected")
            : count == 1 ? "1 file" : "\(count) files"
        listMenuButton.menu = UIMenu(title: title, children: [
            UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.listMenu?() ?? []) },
        ])
    }

    /// Refreshes one download's progress.
    func update(_ item: MobileDownloads.Item) {
        rows.first { $0.item === item }?.update()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: PanelHeader.height)
        // As wide as Site settings' list, and More's tiles.
        let width = 4*MenuPanel.tileSize(width: bounds.width).width+3*MenuPanel.spacing
        let visible = CGFloat(min(max(rows.count, 1), Self.maximumVisibleRows))
        list.frame = CGRect(x: bounds.midX-width/2, y: SiteSettingsPanel.rowsTop, width: width, height: visible*Self.rowHeight)
        list.contentSize = CGSize(width: width, height: CGFloat(rows.count)*Self.rowHeight)
        empty.frame = CGRect(x: 16, y: 0, width: max(0, width-32), height: Self.rowHeight)
        for (index, row) in rows.enumerated() {
            // By bounds and center, as pressed rows are scaled.
            row.bounds = CGRect(x: 0, y: 0, width: width, height: Self.rowHeight)
            row.center = CGPoint(x: width/2, y: (CGFloat(index)+0.5)*Self.rowHeight)
            // The list's own corners, kept as the first or last row shrinks.
            var corners: CACornerMask = []
            if index == 0 { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
            if index == rows.count-1 { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
            row.layer.maskedCorners = corners
            row.layer.cornerRadius = corners.isEmpty ? 0 : MenuPanel.cornerRadius
        }
        let hairline = 1/max(1, traitCollection.displayScale)
        for (index, divider) in dividers.enumerated() {
            divider.frame = CGRect(x: 16, y: CGFloat(index+1)*Self.rowHeight-hairline/2, width: width-32, height: hairline)
        }
    }

    /// Rows take touches at once, so they darken straight away, and a drag that starts on one
    /// still scrolls.
    final class List: UIScrollView {
        override func touchesShouldCancel(in view: UIView) -> Bool { true }
    }

    final class Row: UIButton {
        let item: MobileDownloads.Item
        let moreButton = UIButton(type: .system)
        private let icon = UIImageView()
        private let ring = ProgressRing()
        /// The icon, or the ring while downloading, which Multi Select swaps for the checkbox.
        private let badge = UIView()
        private let checkbox = UIImageView(image: UIImage(systemName: "circle"))
        private let title = UILabel()
        private let detail = UILabel()
        private var thumbnailFor: URL?

        init(item: MobileDownloads.Item) {
            self.item = item
            super.init(frame: .zero)
            icon.contentMode = .scaleAspectFit
            icon.isUserInteractionEnabled = false
            title.font = PanelHeader.font("OpenRunde-Medium", size: 16, fallbackWeight: .medium)
            title.adjustsFontForContentSizeCategory = true
            title.textColor = .label
            title.lineBreakMode = .byTruncatingMiddle
            detail.font = SearchPanel.roundedFont(ofSize: 13, weight: .medium)
            detail.adjustsFontForContentSizeCategory = true
            detail.textColor = .secondaryLabel
            detail.lineBreakMode = .byTruncatingTail
            for view in [icon, ring] as [UIView] { badge.addSubview(view) }
            checkbox.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            checkbox.contentMode = .center
            checkbox.tintColor = .tertiaryLabel
            checkbox.alpha = 0
            for view in [badge, checkbox, title, detail] as [UIView] {
                view.isUserInteractionEnabled = false
                view.isAccessibilityElement = false
                addSubview(view)
            }
            moreButton.setImage(UIImage(systemName: "ellipsis", withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
            moreButton.tintColor = .secondaryLabel
            moreButton.showsMenuAsPrimaryAction = true
            moreButton.preferredMenuElementOrder = .fixed
            addSubview(moreButton)
            layer.cornerCurve = .continuous
            shrinksWhenPressed(to: DownloadsPanel.pressedScale, filled: true,
                               restingFill: DownloadsPanel.rowFill, pressedFill: DownloadsPanel.pressedRowFill)
            update()
        }

        required init?(coder: NSCoder) { fatalError() }

        func update() {
            title.text = item.name
            let finished = item.state == .finished
            icon.isHidden = !finished
            ring.isHidden = finished
            ring.update(fraction: item.fraction, failed: item.state == .failed)
            let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
            switch item.state {
            case .finished: detail.text = format(item.totalBytes)
            case .failed: detail.text = "Failed"
            case .downloading:
                let size = item.totalBytes > 0 ? "\(format(item.receivedBytes)) of \(format(item.totalBytes))"
                    : item.receivedBytes > 0 ? "\(format(item.receivedBytes)) downloaded" : "Starting…"
                detail.text = item.bytesPerSecond > 0 ? "\(size) · \(format(Int64(item.bytesPerSecond)))/s" : size
            }
            if finished, thumbnailFor != item.url { loadThumbnail() }
            accessibilityLabel = "\(item.name), \(detail.text ?? "")"
            accessibilityHint = finished ? "Opens in Quick Look" : nil
            moreButton.accessibilityLabel = "More for \(item.name)"
        }

        /// Swaps the icon for a checkbox, as Send swaps in beside Find, and hides the row's dots.
        func setSelecting(_ selecting: Bool, animated: Bool) {
            moreButton.isUserInteractionEnabled = !selecting
            moreButton.accessibilityElementsHidden = selecting
            guard animated, !UIAccessibility.isReduceMotionEnabled else {
                BlurCrossfade.stop(in: self)
                badge.alpha = selecting ? 0 : 1
                checkbox.alpha = selecting ? 1 : 0
                badge.transform = .identity
                checkbox.transform = .identity
                moreButton.alpha = selecting ? 0 : 1
                return
            }
            BlurCrossfade.swap(from: selecting ? badge : checkbox, to: selecting ? checkbox : badge, style: .symbol)
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.moreButton.alpha = selecting ? 0 : 1
            }
        }

        func setChecked(_ checked: Bool, animated: Bool) {
            let image = UIImage(systemName: checked ? "checkmark.circle.fill" : "circle")!
            if animated, !UIAccessibility.isReduceMotionEnabled {
                checkbox.setSymbolImage(image, contentTransition: .replace)
            } else { checkbox.image = image }
            checkbox.tintColor = checked ? SiteSettingsPanel.switchBlue : .tertiaryLabel
            accessibilityTraits = checked ? [.button, .selected] : .button
        }

        /// The file's own picture, as Files shows it, or its type's icon.
        private func loadThumbnail() {
            let url = item.url
            thumbnailFor = url
            icon.image = UIImage(systemName: "doc")
            icon.tintColor = .secondaryLabel
            let side: CGFloat = 36
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                       scale: traitCollection.displayScale, representationTypes: .all)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
                guard let image = thumbnail?.uiImage else { return }
                DispatchQueue.main.async {
                    guard let self, self.thumbnailFor == url else { return }
                    self.icon.image = image
                }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let column = CGRect(x: 14, y: bounds.midY-18, width: 36, height: 36)
            // By bounds and center, as they scale as they swap.
            for view in [badge, checkbox] {
                view.bounds = CGRect(origin: .zero, size: column.size)
                view.center = CGPoint(x: column.midX, y: column.midY)
            }
            // Audio's icon fills more of its square than documents' do.
            let isAudio = UTType(filenameExtension: item.url.pathExtension)?.conforms(to: .audio) == true
            icon.frame = isAudio ? badge.bounds.insetBy(dx: 3, dy: 3) : badge.bounds
            ring.frame = badge.bounds.insetBy(dx: 5, dy: 5)
            moreButton.bounds = CGRect(x: 0, y: 0, width: 44, height: bounds.height)
            moreButton.center = CGPoint(x: bounds.width-6-22, y: bounds.midY)
            let x = column.maxX+12, width = max(0, moreButton.frame.minX-x)
            let titleHeight = ceil(title.font.lineHeight), detailHeight = ceil(detail.font.lineHeight)
            let top = bounds.midY-(titleHeight+2+detailHeight)/2
            title.frame = CGRect(x: x, y: top, width: width, height: titleHeight)
            detail.frame = CGRect(x: x, y: top+titleHeight+2, width: width, height: detailHeight)
        }
    }

    /// A download's progress, as on the Mac: a ring filling clockwise, or turning while its size is unknown.
    final class ProgressRing: UIView {
        private let track = CAShapeLayer(), fill = CAShapeLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            for shape in [track, fill] {
                shape.fillColor = nil
                shape.lineWidth = 2.5
                shape.lineCap = .round
                layer.addSublayer(shape)
            }
            fill.strokeColor = SiteSettingsPanel.switchBlue.cgColor
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (ring: ProgressRing, _: UITraitCollection) in
                ring.track.strokeColor = UIColor.label.withAlphaComponent(0.14).resolvedColor(with: ring.traitCollection).cgColor
            }
            track.strokeColor = UIColor.label.withAlphaComponent(0.14).resolvedColor(with: traitCollection).cgColor
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            let path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
                                    radius: max(0, min(bounds.width, bounds.height)/2-1.5),
                                    startAngle: -.pi/2, endAngle: 3 * .pi/2, clockwise: true).cgPath
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for shape in [track, fill] {
                shape.frame = bounds
                shape.path = path
            }
            CATransaction.commit()
        }

        func update(fraction: Double?, failed: Bool) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fill.strokeColor = (failed ? UIColor.systemRed : SiteSettingsPanel.switchBlue).cgColor
            fill.strokeEnd = failed ? 1 : CGFloat(fraction ?? 0.25)
            CATransaction.commit()
            if fraction == nil, !failed, !UIAccessibility.isReduceMotionEnabled {
                guard fill.animation(forKey: "spin") == nil else { return }
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = 2*Double.pi
                spin.duration = 1.1
                spin.repeatCount = .infinity
                spin.isRemovedOnCompletion = false
                fill.add(spin, forKey: "spin")
            } else { fill.removeAnimation(forKey: "spin") }
        }
    }
}
