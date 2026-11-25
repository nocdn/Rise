import UIKit

/// Autofill Information, from Source's Edit in Settings: the card's copy, row by row, to change
/// and add to. Name, work and address come first, each detail a field at its row's end; then phone
/// numbers, emails and websites, each list ending in a row that adds one more; then the birthday,
/// with the system's date picker. Each change is kept as it's made, and remembered as made here,
/// so that picking the card again replaces only what the card has (`AutofillProfile.refreshed`).
final class AutofillInfoPanel: UIView, UITextFieldDelegate, UIGestureRecognizerDelegate {
    private typealias Detail = AutofillProfile.Detail
    enum List: CaseIterable { case phones, emails, websites }

    private let header = PanelHeader(title: "Autofill Information")
    var closeButton: AnimatedSymbolButton { header.closeButton }
    private let scroll = UIScrollView()
    private let store: AutofillStore
    private var profile = AutofillProfile()
    private var saving = false

    private let titleRow = SettingsMenuRow("Title", icon: nil, colour: .clear)
    private let countryRow = SettingsMenuRow("Country", icon: nil, colour: .clear)
    private var detailRows: [Detail: FieldRow] = [:]
    private let birthdayRow = BirthdayRow()
    private let addRows: [List: AddRow] = [.phones: AddRow("Add another phone"), .emails: AddRow("Add another email"),
                                           .websites: AddRow("Add another website")]
    private let names = Group(), work = Group(), address = Group(), birthday = Group()
    private let lists: [List: Group] = [.phones: Group(), .emails: Group(), .websites: Group()]
    private var groups: [Group] { [names, work, address, lists[.phones]!, lists[.emails]!, lists[.websites]!, birthday] }
    private let ageNote = UILabel()
    private let footnote = UILabel()
    var buttons: [UIButton] { [closeButton, titleRow.button, countryRow.button]+List.allCases.compactMap { addRows[$0] }+[birthdayRow.addButton] }
    var keyboardInset: CGFloat = 0 {
        didSet { setNeedsLayout(); layoutIfNeeded(); revealEditing() }
    }
    /// The content grew or shrank, for the sheet to follow where it isn't at its limit.
    var onHeightChange: (() -> Void)?

    static let titles = ["Mr", "Mrs", "Miss", "Ms", "Mx", "Dr", "Prof", "Rev"]
    static let phoneLabels = ["Mobile", "iPhone", "Home", "Work", "Main", "Fax", "Other"]
    static let emailLabels = ["Home", "Work", "iCloud", "School", "Other"]

    init(store: AutofillStore = .shared) {
        self.store = store
        super.init(frame: .zero)
        header.closeButton.accessibilityLabel = "Back to Settings"
        addSubview(header)
        addSubview(scroll)
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        groups.forEach(scroll.addSubview)
        func row(_ title: String, _ detail: Detail, _ content: UITextContentType?, capitalisation: UITextAutocapitalizationType = .words) -> FieldRow {
            let row = FieldRow(title)
            row.detail = detail
            row.field.textContentType = content
            row.field.autocapitalizationType = capitalisation
            detailRows[detail] = row
            return row
        }
        names.setRows([titleRow, row("First name", .givenName, .givenName), row("Middle name", .middleName, .middleName),
                       row("Last name", .familyName, .familyName)])
        work.setRows([row("Company", .organization, .organizationName), row("Position", .jobTitle, .jobTitle)])
        address.setRows([row("Address line 1", .line1, .streetAddressLine1), row("Address line 2", .line2, .streetAddressLine2),
                         row("Town or city", .city, .addressCity), row("County", .county, .addressState),
                         row("Postcode", .postalCode, .postalCode, capitalisation: .allCharacters), countryRow])
        birthday.setRows([birthdayRow])
        for row in detailRows.values { row.field.delegate = self }
        for list in List.allCases {
            addRows[list]?.addAction(UIAction { [weak self] _ in self?.add(list) }, for: .primaryActionTriggered)
        }
        // A tap off the rows puts the keyboard away: between groups, at the sides, on the notes
        // or the title bar. Rows focus their own field, and buttons and menus act as they do.
        let dismiss = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        dismiss.cancelsTouchesInView = false
        dismiss.delegate = self
        addGestureRecognizer(dismiss)
        birthdayRow.onChange = { [weak self] components in self?.setBirthday(components) }
        birthdayRow.onRemove = { [weak self] in self?.setBirthday(nil) }
        for label in [ageNote, footnote] {
            label.font = PanelHeader.font("OpenRunde-Regular", size: 13, fallbackWeight: .regular)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            scroll.addSubview(label)
        }
        footnote.text = "Refreshing your contact card updates what it has. Anything you add here stays."
        NotificationCenter.default.addObserver(forName: AutofillStore.didChange, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // A county looked up while it's open, say; never over what's being typed.
                guard let self, !self.saving, self.window != nil, self.editingRow == nil else { return }
                self.reload()
            }
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Showing the card

    /// Shows the card as it's kept now.
    func reload() {
        profile = store.profile ?? AutofillProfile()
        for (detail, row) in detailRows { row.field.text = profile[detail] }
        showTitle()
        showCountry()
        for list in List.allCases {
            let rows = items(of: list).map { item in makeRow(list, label: item.label, value: item.value) }
            lists[list]?.setRows(rows+[addRows[list]!])
        }
        birthdayRow.show(profile.birthday)
        showAge()
        setNeedsLayout()
    }

    private func items(of list: List) -> [(label: String, value: String)] {
        switch list {
        case .phones: profile.phones.map { ($0.label, $0.number) }
        case .emails: profile.emails.map { ($0.label, $0.value) }
        case .websites: profile.urls.map { (Self.websiteTitle($0.value), $0.value) }
        }
    }

    private func showTitle() {
        let current = profile.namePrefix
        var titles = Self.titles
        if !current.isEmpty, !titles.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) { titles.insert(current, at: 0) }
        let choose = { [weak self] (title: String) in
            self?.update { $0.set(.namePrefix, to: title) }
            self?.showTitle()
        }
        titleRow.show(current.isEmpty ? "None" : current, menu: UIMenu(options: .singleSelection, children: [
            UIMenu(options: .displayInline, children: [UIAction(title: "None", state: current.isEmpty ? .on : .off) { _ in choose("") }]),
            UIMenu(options: .displayInline, children: titles.map { title in
                UIAction(title: title, state: title.caseInsensitiveCompare(current) == .orderedSame ? .on : .off) { _ in choose(title) }
            }),
        ]))
    }

    /// Every country by name, this one's and the device's first.
    private func showCountry() {
        let address = profile.addresses.first
        let code = address?.isoCountryCode.uppercased() ?? ""
        let name = address.map(AutofillValues.countryName) ?? ""
        let choose = { [weak self] (country: (code: String, name: String)) in
            self?.update { profile in
                profile.set(.country, to: country.name)
                profile.addresses[0].isoCountryCode = country.code.lowercased()
            }
            self?.showCountry()
        }
        let action = { (country: (code: String, name: String)) in
            UIAction(title: country.name, state: country.code == code ? .on : .off) { _ in choose(country) }
        }
        let local = Locale.current.region?.identifier ?? ""
        let first = Self.countries.filter { $0.code == code || $0.code == local }
        countryRow.show(name.isEmpty ? "None" : name, menu: UIMenu(options: .singleSelection, children: [
            UIMenu(options: .displayInline, children: first.map(action)),
            UIMenu(options: .displayInline, children: Self.countries.map(action)),
        ]))
    }

    static let countries: [(code: String, name: String)] = {
        let excluded: Set<String> = ["EU", "EZ", "UN", "QO", "XA", "XB", "ZZ"]
        return Locale.Region.isoRegions.map(\.identifier)
            .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) && !excluded.contains($0) }
            .compactMap { code -> (code: String, name: String)? in
                Locale.current.localizedString(forRegionCode: code).map { (code: code, name: $0) }
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    private func showAge() {
        let age = AutofillValues.age(profile.birthday, now: Date())
        ageNote.text = age.map { "Forms asking your age get \($0)." }
        ageNote.isHidden = age == nil
    }

    /// LinkedIn, GitHub or X by its address, otherwise a website.
    static func websiteTitle(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        let host = (URL(string: trimmed.contains("://") ? trimmed : "https://"+trimmed)?.host ?? "").lowercased()
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("."+domain) }
        if on("linkedin.com") { return "LinkedIn" }
        if on("github.com") { return "GitHub" }
        if on("x.com") || on("twitter.com") { return "X" }
        return "Website"
    }

    // MARK: Lists

    private func makeRow(_ list: List, label: String, value: String) -> FieldRow {
        let row = FieldRow(label)
        row.list = list
        row.field.text = value
        row.field.delegate = self
        row.field.clearButtonMode = .whileEditing
        row.field.autocapitalizationType = .none
        row.field.autocorrectionType = .no
        row.field.spellCheckingType = .no
        switch list {
        case .phones:
            row.field.keyboardType = .phonePad
            row.field.textContentType = .telephoneNumber
            row.field.placeholder = "Number"
        case .emails:
            row.field.keyboardType = .emailAddress
            row.field.textContentType = .emailAddress
            row.field.placeholder = "Email"
        case .websites:
            row.field.keyboardType = .URL
            row.field.textContentType = .URL
            row.field.placeholder = "Link"
        }
        showLabel(label, of: row)
        return row
    }

    /// A phone's or email's label, with a menu to change it or delete the row; a website's, by its address.
    private func showLabel(_ label: String, of row: FieldRow) {
        row.labelText = label
        guard let list = row.list, list != .websites else { return row.showTitle(label, menu: nil) }
        var labels = list == .phones ? Self.phoneLabels : Self.emailLabels
        if !label.isEmpty, !labels.contains(label) { labels.insert(label, at: 0) }
        let choices = labels.map { choice in
            UIAction(title: choice, state: choice == label ? .on : .off) { [weak self, weak row] _ in
                guard let self, let row else { return }
                showLabel(choice, of: row)
                guard let index = index(of: row), index < items(of: list).count else { return }
                update { profile in
                    if list == .phones { profile.phones[index].label = choice } else { profile.emails[index].label = choice }
                }
            }
        }
        let delete = UIAction(title: list == .phones ? "Delete Number" : "Delete Email", image: UIImage(systemName: "trash"),
                              attributes: .destructive) { [weak self, weak row] _ in
            guard let self, let row else { return }
            row.field.text = ""
            if row.field.isFirstResponder { row.field.resignFirstResponder() } else { commit(row) }
        }
        row.showTitle(label.isEmpty ? (list == .phones ? "Phone" : "Email") : label, menu: UIMenu(children: [
            UIMenu(options: [.displayInline, .singleSelection], children: choices),
            UIMenu(options: .displayInline, children: [delete]),
        ]))
    }

    private func index(of row: FieldRow) -> Int? {
        guard let list = row.list else { return nil }
        return lists[list]?.rows.firstIndex(of: row)
    }

    /// A row for one more, where the add row was, that row moving down; its field ready to type in.
    private func add(_ list: List) {
        guard let group = lists[list], let addRow = addRows[list] else { return }
        // An empty one still open is the one to fill.
        if let empty = group.rows.compactMap({ $0 as? FieldRow }).first(where: { ($0.field.text ?? "").isEmpty }) {
            empty.field.becomeFirstResponder()
            return
        }
        let used = Set(items(of: list).map(\.label))
        let label = switch list {
        case .phones: ["Mobile", "Home", "Work"].first { !used.contains($0) } ?? "Other"
        case .emails: ["Home", "Work"].first { !used.contains($0) } ?? "Other"
        case .websites: "Website"
        }
        let row = makeRow(list, label: label, value: "")
        row.isNew = true
        row.frame = addRow.frame
        row.alpha = 0
        group.insert(row, at: group.rows.count-1)
        row.layoutIfNeeded()
        animateLayout { row.alpha = 1 }
        row.field.becomeFirstResponder()
    }

    private func remove(_ row: FieldRow) {
        guard let group = row.superview as? Group else { return }
        group.remove(row)
        group.sendSubviewToBack(row)
        animateLayout({ row.alpha = 0 }) { _ in row.removeFromSuperview() }
    }

    // MARK: Editing

    /// Saves a change to the card's copy as it's kept now, so a county looked up meanwhile stays.
    private func update(_ change: (inout AutofillProfile) -> Void) {
        var current = store.profile ?? profile
        change(&current)
        guard current != store.profile else { profile = current; return }
        profile = current
        saving = true
        defer { saving = false }
        try? store.save(current)
    }

    private func setBirthday(_ components: DateComponents?) {
        update { profile in
            if let components, let day = components.day, let month = components.month {
                profile.birthday = AutofillProfile.Birthday(day: day, month: month, year: components.year)
                profile.edited.insert(Detail.birthday.rawValue)
            } else {
                profile.birthday = nil
                profile.edited.remove(Detail.birthday.rawValue)
            }
        }
        birthdayRow.show(profile.birthday)
        showAge()
        animateLayout()
    }

    private var editingRow: FieldRow? {
        allFieldRows.first { $0.field.isFirstResponder }
    }

    private var allFieldRows: [FieldRow] {
        groups.flatMap(\.rows).compactMap { $0 as? FieldRow }
    }

    private func row(of field: UITextField) -> FieldRow? {
        var view = field.superview
        while let current = view, !(current is FieldRow) { view = current.superview }
        return view as? FieldRow
    }

    /// What a row's field holds, kept: a detail as typed, a list's entry as typed, or gone if it's emptied.
    private func commit(_ row: FieldRow) {
        let text = (row.field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let detail = row.detail {
            update { $0.set(detail, to: text) }
            row.field.text = profile[detail]
            return
        }
        guard let list = row.list, let index = index(of: row) else { return }
        let exists = index < items(of: list).count && !row.isNew
        if text.isEmpty {
            if exists {
                update { profile in
                    switch list {
                    case .phones: profile.phones.remove(at: index)
                    case .emails: profile.emails.remove(at: index)
                    case .websites: profile.urls.remove(at: index)
                    }
                }
            }
            remove(row)
            return
        }
        let region = profile.addresses.first.flatMap { $0.isoCountryCode.isEmpty ? nil : $0.isoCountryCode }
            ?? Locale.current.region?.identifier.lowercased()
        update { profile in
            switch list {
            case .phones:
                if exists { profile.phones[index].number = text }
                else { profile.phones.append(.init(label: row.labelText, number: text, region: region, added: true)) }
            case .emails:
                if exists { profile.emails[index].value = text }
                else { profile.emails.append(.init(label: row.labelText, value: text, added: true)) }
            case .websites:
                if exists { profile.urls[index].value = text; profile.urls[index].label = Self.websiteTitle(text) }
                else { profile.urls.append(.init(label: Self.websiteTitle(text), value: text, added: true)) }
            }
        }
        row.isNew = false
        if list == .websites { showLabel(Self.websiteTitle(text), of: row) }
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        textField.textColor = .label
        revealEditing()
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        textField.textColor = .secondaryLabel
        if let row = row(of: textField) { commit(row) }
    }

    /// Return goes on to the next field down, and from the last puts the keyboard away.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let rows = allFieldRows
        if let index = rows.firstIndex(where: { $0.field === textField }), index+1 < rows.count {
            rows[index+1].field.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
        }
        return true
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard let text = textField.text, let range = Range(range, in: text) else { return false }
        return text.replacingCharacters(in: range, with: string).count <= 500
    }

    private func revealEditing() {
        guard let row = editingRow else { return }
        scroll.scrollRectToVisible(row.convert(row.bounds, to: scroll).insetBy(dx: 0, dy: -16), animated: true)
    }

    func canPullToClose(at point: CGPoint, velocity: CGPoint) -> Bool {
        guard scroll.bounds.contains(convert(point, to: scroll)) else { return true }
        return editingRow == nil && velocity.y > abs(velocity.x)
            && scroll.contentOffset.y <= -scroll.adjustedContentInset.top+1
    }

    // MARK: Layout

    private func animateLayout(_ animations: (() -> Void)? = nil, completion: ((Bool) -> Void)? = nil) {
        let change = {
            self.layoutContent()
            animations?()
        }
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else { change(); completion?(true); onHeightChange?(); return }
        UIView.animate(springDuration: 0.35, bounce: 0, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction], animations: change, completion: completion)
        onHeightChange?()
    }

    private static func contentWidth(_ width: CGFloat) -> CGFloat {
        4*MenuPanel.tileSize(width: width).width+3*MenuPanel.spacing
    }

    /// Its whole height, header and all, at `width`.
    func naturalHeight(width: CGFloat) -> CGFloat {
        PanelHeader.height+contentHeight(width: width)
    }

    private func contentHeight(width: CGFloat) -> CGFloat {
        let textWidth = max(0, Self.contentWidth(width)-32)
        var y = MenuPanel.top
        for group in groups {
            y += group.height
            if group === birthday, !ageNote.isHidden {
                y += 12+ageNote.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
            }
            y += SiteSettingsPanel.groupGap
        }
        return y+footnote.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height+16
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: PanelHeader.height)
        scroll.frame = CGRect(x: 0, y: PanelHeader.height, width: bounds.width, height: max(0, bounds.height-PanelHeader.height))
        scroll.contentInset.bottom = keyboardInset
        scroll.verticalScrollIndicatorInsets.bottom = keyboardInset
        layoutContent()
    }

    @objc private func dismissKeyboard() { endEditing(true) }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard editingRow != nil, var view = touch.view else { return false }
        while view !== self {
            if view is FieldRow || view is UIControl { return false }
            guard let parent = view.superview else { return false }
            view = parent
        }
        return true
    }

    private func layoutContent() {
        let width = Self.contentWidth(bounds.width), x = (bounds.width-width)/2, textWidth = max(0, width-32)
        var y = MenuPanel.top
        for group in groups {
            group.frame = CGRect(x: x, y: y, width: width, height: group.height)
            group.setNeedsLayout()
            group.layoutIfNeeded()
            y = group.frame.maxY
            if group === birthday, !ageNote.isHidden {
                let height = ageNote.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
                ageNote.frame = CGRect(x: x+16, y: y+12, width: textWidth, height: height)
                y = ageNote.frame.maxY
            }
            y += SiteSettingsPanel.groupGap
        }
        let height = footnote.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        footnote.frame = CGRect(x: x+16, y: y, width: textWidth, height: height)
        scroll.contentSize = CGSize(width: bounds.width, height: footnote.frame.maxY+16)
    }
}

/// Rows joined into one rounded group, a hairline between each.
private final class Group: UIView {
    private(set) var rows: [UIView] = []
    private var dividers: [UIView] = []
    var height: CGFloat { CGFloat(rows.count)*SiteSettingsPanel.rowHeight }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerCurve = .continuous
        layer.cornerRadius = MenuPanel.cornerRadius
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func setRows(_ rows: [UIView]) {
        for row in self.rows where !rows.contains(row) { row.removeFromSuperview() }
        self.rows = rows
        rows.forEach(addSubview)
        updateDividers()
    }

    func insert(_ row: UIView, at index: Int) {
        rows.insert(row, at: index)
        addSubview(row)
        updateDividers()
    }

    /// Takes the row out of the order; it stays shown until it's removed from the group.
    func remove(_ row: UIView) {
        rows.removeAll { $0 === row }
        updateDividers()
    }

    private func updateDividers() {
        while dividers.count < max(0, rows.count-1) {
            let divider = UIView()
            divider.backgroundColor = .separator
            divider.isUserInteractionEnabled = false
            dividers.append(divider)
        }
        while dividers.count > max(0, rows.count-1) { dividers.removeLast().removeFromSuperview() }
        for divider in dividers { addSubview(divider) }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rowHeight = SiteSettingsPanel.rowHeight
        for (index, row) in rows.enumerated() {
            row.frame = CGRect(x: 0, y: CGFloat(index)*rowHeight, width: bounds.width, height: rowHeight)
        }
        let hairline = 1/max(1, traitCollection.displayScale)
        for (index, divider) in dividers.enumerated() {
            divider.frame = CGRect(x: 16, y: CGFloat(index+1)*rowHeight-hairline/2, width: bounds.width-32, height: hairline)
        }
    }
}

@MainActor private let titleFont = PanelHeader.font("OpenRunde-Medium", size: 16, fallbackWeight: .medium)
@MainActor private let valueFont = PanelHeader.font("OpenRunde-Regular", size: 16, fallbackWeight: .regular)

/// A title, and a field at the row's end for what it holds, right-aligned. A phone's or email's
/// row is titled with its label, which a menu changes.
private final class FieldRow: UIView, UIGestureRecognizerDelegate {
    private let title = UILabel()
    private let labelButton = UIButton(type: .system)
    let field = UITextField()
    var detail: AutofillProfile.Detail?
    var list: AutofillInfoPanel.List?
    var labelText = ""
    /// Added and not yet kept.
    var isNew = false

    init(_ text: String) {
        super.init(frame: .zero)
        backgroundColor = SearchPanel.fill
        title.text = text
        title.font = titleFont
        title.textColor = .label
        title.adjustsFontForContentSizeCategory = true
        labelButton.isHidden = true
        labelButton.showsMenuAsPrimaryAction = true
        labelButton.preferredMenuElementOrder = .fixed
        field.font = valueFont
        field.adjustsFontForContentSizeCategory = true
        field.textAlignment = .right
        field.textColor = .secondaryLabel
        field.returnKeyType = .next
        field.accessibilityLabel = text
        field.attributedPlaceholder = NSAttributedString(string: "Add", attributes: [.foregroundColor: UIColor.tertiaryLabel, .font: valueFont])
        [title, labelButton, field].forEach(addSubview)
        let tap = UITapGestureRecognizer(target: self, action: #selector(focus))
        tap.delegate = self
        addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var accessibilityElements: [Any]? {
        get { labelButton.isHidden ? [field] : [labelButton, field] }
        set {}
    }

    /// Titled `text`, as plain text, or with a menu.
    func showTitle(_ text: String, menu: UIMenu?) {
        field.accessibilityLabel = text
        if let placeholder = field.placeholder, !placeholder.isEmpty {
            field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor.tertiaryLabel, .font: valueFont])
        }
        guard let menu else {
            labelButton.isHidden = true
            title.isHidden = false
            title.text = text
            setNeedsLayout()
            return
        }
        title.isHidden = true
        labelButton.isHidden = false
        var config = UIButton.Configuration.plain()
        config.attributedTitle = AttributedString(text, attributes: AttributeContainer([.font: titleFont]))
        config.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))?
            .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
        config.imagePlacement = .trailing
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0)
        config.baseForegroundColor = .label
        labelButton.configuration = config
        labelButton.menu = menu
        labelButton.accessibilityLabel = "Label"
        labelButton.accessibilityValue = text
        setNeedsLayout()
    }

    @objc private func focus() { field.becomeFirstResponder() }

    /// Anywhere on the row but the field itself, which places its own caret, and the label's menu.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = touch.view else { return true }
        return !view.isDescendant(of: field) && !view.isDescendant(of: labelButton)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let leading: UIView = labelButton.isHidden ? title : labelButton
        let width = min(leading.sizeThatFits(bounds.size).width, bounds.width*0.5)
        leading.frame = CGRect(x: 16, y: 0, width: width, height: bounds.height)
        let fieldX = leading.frame.maxX+12
        field.frame = CGRect(x: fieldX, y: 0, width: max(0, bounds.width-16-fieldX), height: bounds.height)
    }
}

/// A list's last row: a plus, in Autofill's colour, and what it adds.
private final class AddRow: UIButton {
    private let plus = UIImageView(image: UIImage(systemName: "plus.circle.fill", withConfiguration:
        UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)))
    private let label = UILabel()

    init(_ text: String) {
        super.init(frame: .zero)
        plus.tintColor = AutofillSettingsGroup.colour
        plus.contentMode = .center
        label.text = text
        label.font = titleFont
        label.textColor = .label
        label.adjustsFontForContentSizeCategory = true
        for view in [plus, label] {
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            addSubview(view)
        }
        accessibilityLabel = text
        darkensWhenPressed(restingFill: SearchPanel.fill)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        plus.frame = CGRect(x: 14, y: 0, width: 26, height: bounds.height)
        label.frame = CGRect(x: plus.frame.maxX+10, y: 0, width: max(0, bounds.width-plus.frame.maxX-26), height: bounds.height)
    }
}

/// The birthday, with the system's compact date picker; Add where there's none. Holding its title
/// offers to remove it.
private final class BirthdayRow: UIView, UIContextMenuInteractionDelegate {
    private let title = UILabel()
    private let picker = UIDatePicker()
    let addButton = UIButton(type: .system)
    var onChange: ((DateComponents) -> Void)?
    var onRemove: (() -> Void)?
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = SearchPanel.fill
        title.text = "Birthday"
        title.font = titleFont
        title.textColor = .label
        title.adjustsFontForContentSizeCategory = true
        title.isUserInteractionEnabled = true
        title.addInteraction(UIContextMenuInteraction(delegate: self))
        picker.datePickerMode = .date
        picker.preferredDatePickerStyle = .compact
        picker.calendar = calendar
        picker.maximumDate = Date()
        picker.minimumDate = calendar.date(from: DateComponents(year: 1900, month: 1, day: 1))
        picker.accessibilityLabel = "Birthday"
        picker.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            onChange?(calendar.dateComponents([.year, .month, .day], from: picker.date))
        }, for: .valueChanged)
        var config = UIButton.Configuration.plain()
        config.attributedTitle = AttributedString("Add", attributes: AttributeContainer([.font: valueFont]))
        config.baseForegroundColor = .tertiaryLabel
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0)
        addButton.configuration = config
        addButton.accessibilityLabel = "Add birthday"
        // Shown, but kept only once a date's picked.
        addButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let year = calendar.component(.year, from: Date())-30
            picker.date = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? Date()
            picker.isHidden = false
            addButton.isHidden = true
            setNeedsLayout()
        }, for: .primaryActionTriggered)
        [title, picker, addButton].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ birthday: AutofillProfile.Birthday?) {
        picker.isHidden = birthday == nil
        addButton.isHidden = birthday != nil
        // A birthday kept without its year shows in 2000, until one's picked.
        if let birthday, let date = calendar.date(from: DateComponents(year: birthday.year ?? 2000, month: birthday.month, day: birthday.day)) {
            picker.date = date
        }
        setNeedsLayout()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard !picker.isHidden else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [UIAction(title: "Remove Birthday", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                self?.onRemove?()
            }])
        })
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        title.sizeToFit()
        title.frame = CGRect(x: 16, y: 0, width: title.bounds.width, height: bounds.height)
        let pickerSize = picker.sizeThatFits(bounds.size)
        picker.frame = CGRect(x: bounds.width-16-pickerSize.width, y: (bounds.height-pickerSize.height)/2,
                              width: pickerSize.width, height: pickerSize.height)
        let addWidth = addButton.sizeThatFits(bounds.size).width
        addButton.frame = CGRect(x: bounds.width-16-addWidth, y: 0, width: addWidth, height: bounds.height)
    }
}
