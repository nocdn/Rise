import AppKit

/// The palette lab: a copy of Rise, built by scripts/palette-lab.sh, whose new tab palette stays
/// open beside a panel of every value it's drawn with (`AddressTuning`), changed live. It keeps
/// its own profile and settings, apart from the everyday Rise.
enum PaletteLab {
    static let isOn = Bundle.main.object(forInfoDictionaryKey: "RisePaletteLab") as? Bool == true
        || ProcessInfo.processInfo.environment["RISE_PALETTE_LAB"] == "1"
    private static let key = "Rise.PaletteLab.Tuning"
    /// The values left last time, kept between launches.
    @MainActor static func load() {
        guard let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode(AddressTuning.self, from: data) else { return }
        AddressAppearance.tuning = saved
    }
    @MainActor static func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(AddressAppearance.tuning), forKey: key)
    }
}

extension BrowserController {
    /// Puts the panel at the window's right and opens the new tab palette, to stay.
    func installPaletteLab() {
        guard let window, paletteLab == nil else { return }
        PaletteLab.load()
        let panel = PaletteLabPanel(theme: { [weak self] in self?.theme ?? .neutral })
        panel.setTheme = { [weak self] theme in
            guard let self else { return }
            automaticTheme = false; self.theme = theme; update(); paletteLab?.refresh()
        }
        panel.onChange = { [weak self] in
            PaletteLab.save(); self?.palette.applyTuning(); self?.layoutChrome()
        }
        let container = NSView()
        window.contentView = container
        let width = PaletteLabPanel.width, bounds = container.bounds
        root.frame = NSRect(x: 0, y: 0, width: bounds.width-width, height: bounds.height); root.autoresizingMask = [.width, .height]
        panel.frame = NSRect(x: bounds.width-width, y: 0, width: width, height: bounds.height); panel.autoresizingMask = [.minXMargin, .height]
        container.addSubview(root); container.addSubview(panel)
        paletteLab = panel
        // Escape and Enter start the palette over rather than close it.
        palette.dismiss = { [weak self] in self?.paletteCreatesTab = true; self?.showPalette(text: "") }
        window.minSize.width = 720+width
        if window.frame.width < 1200 { window.setContentSize(NSSize(width: 1480, height: 920)); window.center() }
        DispatchQueue.main.asyncAfter(deadline: .now()+0.4) { [weak self] in self?.newTab() }
    }
}

/// The lab's panel: native sliders, pop-ups and colour wells for each of the palette's values.
/// None of them takes the keyboard, so typing stays in the palette.
@MainActor final class PaletteLabPanel: NSVisualEffectView {
    static let width: CGFloat = 330
    var onChange: (() -> Void)?
    var setTheme: ((RiseTheme) -> Void)?
    private let theme: () -> RiseTheme
    private let stack = NSStackView()
    /// Brings each control back in line with the values, after a reset or a change of theme.
    private var refreshers: [() -> Void] = []
    private var actions: [LabAction] = []
    private var tuning: AddressTuning {
        get { AddressAppearance.tuning }
        set { AddressAppearance.tuning = newValue }
    }

    init(theme: @escaping () -> RiseTheme) {
        self.theme = theme
        super.init(frame: .zero)
        material = .sidebar; blendingMode = .behindWindow; state = .active
        build()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() { refreshers.forEach { $0() } }
    private func changed() { onChange?(); refresh() }

    // MARK: Layout

    private func build() {
        let edge = NSBox(); edge.boxType = .separator
        let title = NSTextField(labelWithString: "Palette Lab"); title.font = .systemFont(ofSize: 15, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: "Every change shows at once. Click a value to put it back.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor

        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 20, right: 16)
        let document = FlippedView(); document.addSubview(stack)
        let scroll = NSScrollView(); scroll.documentView = document; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false; scroll.autohidesScrollers = true

        let reset = button("Reset All") { [weak self] _ in self?.tuning = AddressTuning(); self?.changed() }
        let copy = button("Copy Values") { [weak self] sender in
            guard let self, let button = sender as? NSButton else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(tuning.changes, forType: .string)
            button.title = "Copied"
            DispatchQueue.main.asyncAfter(deadline: .now()+1.2) { button.title = "Copy Values" }
        }
        let buttons = NSStackView(views: [reset, NSView(), copy]); buttons.distribution = .fill

        for view in [edge, title, note, scroll, buttons, stack, document] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        [edge, title, note, scroll, buttons].forEach(addSubview)
        NSLayoutConstraint.activate([
            edge.leadingAnchor.constraint(equalTo: leadingAnchor), edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor), edge.widthAnchor.constraint(equalToConstant: 1),
            // Below the titlebar.
            title.topAnchor.constraint(equalTo: topAnchor, constant: 40), title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            note.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3), note.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        section("Appearance")
        add(themePicker())
        add(familyPicker())
        slider("SF Pro width", \.sfWidth, 30...150, step: 1)

        section("Palette")
        slider("New tab width", \.newTabWidth, 360...900, step: 1)
        slider("Width, no sidebar", \.centeredNewTabWidth, 360...1000, step: 1)
        slider("⌘L width", \.addressWidth, 360...1000, step: 1)
        slider("Corner radius", \.cornerRadius, 0...32, step: 0.5)
        slider("Padding", \.inset, 0...32, step: 0.5)
        slider("Field height", \.newTabHeaderHeight, 28...96, step: 1)
        slider("⌘L field height", \.headerHeight, 28...96, step: 1)
        slider("Field icon inset", \.fieldIconInset, 0...40, step: 0.5)
        slider("Field text inset", \.fieldTextInset, 8...80, step: 0.5)
        slider("Field end inset", \.fieldTrailingInset, 0...40, step: 0.5)
        slider("Gap above rows", \.rowsTop, 0...32, step: 0.5)

        section("Rows")
        slider("Row height", \.rowHeight, 20...72, step: 1)
        slider("Row spacing", \.rowSpacing, 0...20, step: 0.5)
        slider("Row corner radius", \.rowRadius, 0...24, step: 0.5)
        slider("Row icon inset", \.rowIconInset, 0...32, step: 0.5)
        slider("Row text inset", \.rowTextInset, 8...80, step: 0.5)
        slider("Row end inset", \.rowTrailingInset, 0...40, step: 0.5)

        section("Text")
        slider("Typed size", \.textSize, 9...24, step: 0.5)
        slider("Typed weight", \.textWeight, 100...900, step: 10)
        slider("Placeholder size", \.placeholderSize, 9...24, step: 0.5)
        slider("Placeholder weight", \.placeholderWeight, 100...900, step: 10)
        slider("Site search size", \.siteSearchSize, 9...24, step: 0.5)
        slider("Site search weight", \.siteSearchWeight, 100...900, step: 10)
        slider("Row title size", \.rowSize, 9...24, step: 0.5)
        slider("Row title weight", \.rowWeight, 100...900, step: 10)
        slider("Row address size", \.addressSize, 9...24, step: 0.5)
        slider("Row address weight", \.addressWeight, 100...900, step: 10)
        slider("Row letter spacing", \.rowKern, -1...2, step: 0.01)
        slider("Title–address gap", \.addressGap, 0...24, step: 0.5)

        section("Icons")
        slider("Field icon size", \.fieldIconSize, 8...32, step: 0.5)
        slider("Row icon size", \.rowIconSize, 8...32, step: 0.5)

        section("Colours")
        for (role, name) in [(AddressTuning.ColorRole.background, "Background"), (.text, "Text"), (.secondary, "Placeholder, addresses"),
                             (.icon, "Icons"), (.rowSelection, "Row highlight"), (.textSelection, "Text selection"),
                             (.border, "Border"), (.shadow, "Shadow")] {
            add(colorRow(name, role))
        }

        section("Shadow and border")
        slider("Shadow opacity", 0...1, step: 0.01, get: { [unowned self] in tuning.shadowOpacity ?? AddressAppearance.defaultShadowOpacity(theme()) },
               set: { [unowned self] in tuning.shadowOpacity = $0 }, isDefault: { [unowned self] in tuning.shadowOpacity == nil })
        slider("Shadow blur", \.shadowBlur, 0...80, step: 1)
        slider("Shadow offset", \.shadowOffset, -20...40, step: 0.5)
        slider("Border width", \.borderWidth, 0...3, step: 0.25)
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
    }
    private func section(_ name: String) {
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 11, weight: .semibold); label.textColor = .secondaryLabelColor
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(16, after: last) }
        add(label)
        stack.setCustomSpacing(6, after: label)
    }
    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.widthAnchor.constraint(equalToConstant: 124).isActive = true
        return label
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views); row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        return row
    }
    private func action(_ run: @escaping (Any) -> Void) -> LabAction {
        let action = LabAction(run); actions.append(action); return action
    }
    private func button(_ title: String, _ run: @escaping (Any) -> Void) -> NSButton {
        let action = action(run)
        let button = NSButton(title: title, target: action, action: #selector(LabAction.fire(_:)))
        button.bezelStyle = .rounded; button.refusesFirstResponder = true
        return button
    }

    // MARK: Controls

    private func slider(_ name: String, _ key: WritableKeyPath<AddressTuning, CGFloat>, _ range: ClosedRange<Double>, step: Double) {
        slider(name, range, step: step, get: { [unowned self] in tuning[keyPath: key] },
               set: { [unowned self] in tuning[keyPath: key] = $0 ?? AddressTuning()[keyPath: key] },
               isDefault: { [unowned self] in tuning[keyPath: key] == AddressTuning()[keyPath: key] })
    }
    /// A slider, snapping to `step`, beside its value; clicking the value puts it back. `set(nil)` resets.
    private func slider(_ name: String, _ range: ClosedRange<Double>, step: Double, get: @escaping () -> CGFloat,
                        set: @escaping (CGFloat?) -> Void, isDefault: @escaping () -> Bool) {
        let slider = NSSlider(value: get(), minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        slider.controlSize = .small; slider.isContinuous = true; slider.refusesFirstResponder = true
        let value = NSButton(title: "", target: nil, action: nil)
        value.isBordered = false; value.refusesFirstResponder = true; value.alignment = .right
        value.toolTip = "Click to put back Rise's own value"
        value.widthAnchor.constraint(equalToConstant: 46).isActive = true
        let digits = step >= 1 ? 0 : step >= 0.1 ? 1 : 2
        let refresh = {
            let current = get()
            slider.doubleValue = current
            value.attributedTitle = NSAttributedString(string: String(format: "%.\(digits)f", current), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: isDefault() ? .regular : .semibold),
                .foregroundColor: isDefault() ? NSColor.secondaryLabelColor : NSColor.controlAccentColor])
        }
        let move = action { [weak self] _ in
            set(CGFloat((slider.doubleValue/step).rounded()*step)); self?.changed()
        }
        slider.target = move; slider.action = #selector(LabAction.fire(_:))
        let reset = action { [weak self] _ in set(nil); self?.changed() }
        value.target = reset; value.action = #selector(LabAction.fire(_:))
        refreshers.append(refresh)
        add(row([label(name), slider, value]))
    }
    private func themePicker() -> NSView {
        let themes: [(RiseTheme, String)] = [(.neutral, "Light"), (.dark, "Dark")]
        let picker = NSSegmentedControl(labels: themes.map(\.1), trackingMode: .selectOne, target: nil, action: nil)
        picker.controlSize = .small; picker.refusesFirstResponder = true
        let pick = action { [weak self] _ in self?.setTheme?(themes[picker.selectedSegment].0) }
        picker.target = pick; picker.action = #selector(LabAction.fire(_:))
        refreshers.append { [unowned self] in picker.selectedSegment = themes.firstIndex { $0.0 == theme() } ?? 0 }
        return row([label("Theme"), picker])
    }
    private func familyPicker() -> NSView {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.controlSize = .small; popUp.font = .systemFont(ofSize: 11); popUp.refusesFirstResponder = true
        popUp.addItems(withTitles: AddressTuning.Family.allCases.map(\.rawValue))
        let pick = action { [weak self] _ in
            guard let self, let family = AddressTuning.Family(rawValue: popUp.titleOfSelectedItem ?? "") else { return }
            tuning.family = family; changed()
        }
        popUp.target = pick; popUp.action = #selector(LabAction.fire(_:))
        refreshers.append { [unowned self] in popUp.selectItem(withTitle: tuning.family.rawValue) }
        return row([label("Font"), popUp])
    }
    private func colorRow(_ name: String, _ role: AddressTuning.ColorRole) -> NSView {
        let well = NSColorWell(style: .minimal); well.supportsAlpha = true; well.refusesFirstResponder = true
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let reset = NSButton(title: "", target: nil, action: nil)
        reset.isBordered = false; reset.refusesFirstResponder = true; reset.toolTip = "Click to go back to the theme's colour"
        let pick = action { [weak self] _ in self?.tuning.setColor(role, well.color); self?.changed() }
        well.target = pick; well.action = #selector(LabAction.fire(_:))
        let back = action { [weak self] _ in self?.tuning.setColor(role, nil); self?.changed() }
        reset.target = back; reset.action = #selector(LabAction.fire(_:))
        refreshers.append { [unowned self] in
            let custom = tuning.color(role)
            well.color = custom ?? AddressAppearance.themeColor(role, theme())
            reset.attributedTitle = NSAttributedString(string: custom == nil ? "Theme's" : "Custom", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: custom == nil ? .regular : .semibold),
                .foregroundColor: custom == nil ? NSColor.secondaryLabelColor : NSColor.controlAccentColor])
        }
        return row([label(name), well, reset])
    }
}

/// A closure as a control's target.
final class LabAction: NSObject {
    private let run: (Any) -> Void
    init(_ run: @escaping (Any) -> Void) { self.run = run }
    @objc func fire(_ sender: Any) { run(sender) }
}
