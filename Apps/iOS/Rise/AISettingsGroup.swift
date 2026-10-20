import UIKit

/// Three joined settings rows. Both pickers use UIKit menus, including the system's glass
/// presentation on iOS 26. Key validation updates that same menu without dismissing it.
final class AISettingsGroup: UIView, UITextFieldDelegate {
    let enabledRow = SettingsToggleRow("AI features", icon: MenuIcons.aiFeatures, colour: .systemOrange, iconSide: 26)
    let providerButton = UIButton(type: .system)
    let keyMenuButton = PanelListMenu.button(label: "API key options")
    let keyField = UITextField()
    /// UITextField truncates a resting secure value with an ellipsis. This clipped display
    /// draws only masking dots. Focusing reveals the original key in the native editor.
    private let maskedKey = UILabel()
    let detail = UILabel()
    private let group = UIView()
    private let providerRow = UIView()
    private let keyRow = UIView()
    private let providerIcon = UIImageView()
    private let keyIcon = UIImageView(image: MenuIcons.apiKey)
    private let providerTitle = UILabel()
    private let keyTitle = UILabel()
    private let dividers = [UIView(), UIView()]
    private let fieldMask = CAGradientLayer()
    private let settings: MobileAISettings
    private var validation = AIKeyValidation.unchecked
    private var validationTask: Task<Void, Never>?
    private var validationID = UUID()
    private var loadingCompletions: [([UIMenuElement]) -> Void] = []
    var onChanged: (() -> Void)?
    var onEditing: (() -> Void)?
    private(set) var saveError: String?
    var buttons: [UIButton] { [enabledRow, providerButton, keyMenuButton] }
    var rowsHeight: CGFloat { (settings.enabled ? 3 : 1)*SiteSettingsPanel.rowHeight }

    init(settings: MobileAISettings = .shared) {
        self.settings = settings
        super.init(frame: .zero)
        group.layer.cornerCurve = .continuous
        group.layer.cornerRadius = MenuPanel.cornerRadius
        group.clipsToBounds = true
        addSubview(group)
        [enabledRow, providerRow, keyRow].forEach(group.addSubview)
        for row in [providerRow, keyRow] { row.backgroundColor = SearchPanel.fill }
        enabledRow.toggle.onTintColor = SiteSettingsPanel.switchBlue
        enabledRow.onChanged = { [weak self] enabled in
            guard let self else { return }
            if !enabled { keyField.resignFirstResponder() }
            settings.enabled = enabled
            refresh()
            onChanged?()
        }
        providerTitle.text = "AI Provider"
        keyTitle.text = "API key"
        for label in [providerTitle, keyTitle] {
            label.font = PanelHeader.font("OpenRunde-Medium", size: 16, fallbackWeight: .medium)
            label.textColor = .label
            label.adjustsFontForContentSizeCategory = true
        }
        for icon in [providerIcon, keyIcon] { icon.tintColor = .systemOrange; icon.contentMode = .scaleAspectFit }
        [providerIcon, providerTitle, providerButton].forEach(providerRow.addSubview)
        [keyIcon, keyTitle, keyMenuButton, keyField].forEach(keyRow.addSubview)
        providerButton.showsMenuAsPrimaryAction = true
        providerButton.preferredMenuElementOrder = .fixed
        providerButton.accessibilityLabel = "AI Provider"
        keyField.delegate = self
        keyField.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        keyField.textColor = .label
        keyField.textAlignment = .right
        keyField.isSecureTextEntry = true
        keyField.autocapitalizationType = .none
        keyField.autocorrectionType = .no
        keyField.spellCheckingType = .no
        keyField.smartQuotesType = .no
        keyField.smartDashesType = .no
        keyField.keyboardType = .asciiCapable
        keyField.returnKeyType = .done
        keyField.placeholder = "Enter key"
        maskedKey.font = .systemFont(ofSize: 16, weight: .regular)
        maskedKey.textColor = .label
        maskedKey.lineBreakMode = .byClipping
        maskedKey.isUserInteractionEnabled = false
        maskedKey.isAccessibilityElement = false
        keyRow.addSubview(maskedKey)
        keyField.addAction(UIAction { [weak self] _ in self?.saveKey() }, for: .editingChanged)
        // The native editor owns selection and horizontal scrolling. Both the resting mask and
        // revealed key use the same fade at the right edge rather than an ellipsis.
        fieldMask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        fieldMask.locations = [0, 0.9, 1]
        fieldMask.startPoint = CGPoint(x: 0, y: 0.5)
        fieldMask.endPoint = CGPoint(x: 1, y: 0.5)
        detail.font = PanelHeader.font("OpenRunde-Regular", size: 13, fallbackWeight: .regular)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        addSubview(detail)
        for divider in dividers {
            divider.backgroundColor = .separator
            group.addSubview(divider)
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        enabledRow.toggle.setOn(settings.enabled, animated: window != nil)
        enabledRow.updateIcon()
        providerRow.isHidden = !settings.enabled
        keyRow.isHidden = !settings.enabled
        dividers.forEach { $0.isHidden = !settings.enabled }
        providerIcon.image = settings.provider == .openRouter ? MenuIcons.openRouter : MenuIcons.openAI
        var config = UIButton.Configuration.plain()
        config.attributedTitle = AttributedString(settings.provider.title, attributes: AttributeContainer([
            .font: PanelHeader.font("OpenRunde-Regular", size: 16, fallbackWeight: .regular),
            .foregroundColor: UIColor.secondaryLabel,
        ]))
        config.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        config.imagePlacement = .trailing
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0)
        config.baseForegroundColor = .secondaryLabel
        providerButton.configuration = config
        providerButton.accessibilityValue = settings.provider.title
        providerButton.menu = UIMenu(options: .singleSelection, children: AIProvider.allCases.map { provider in
            UIAction(title: provider.title,
                     state: provider == settings.provider ? .on : .off) { [weak self] _ in
                guard let self, provider != settings.provider else { return }
                keyField.resignFirstResponder()
                cancelValidation()
                settings.provider = provider
                keyField.text = settings.key(for: provider)
                saveError = nil
                refresh()
            }
        })
        if !keyField.isFirstResponder { keyField.text = settings.key(for: settings.provider) }
        keyField.accessibilityLabel = "\(settings.provider.title) API key"
        updateDetail()
        refreshKeyMenu()
        setNeedsLayout()
    }

    private func updateDetail() {
        detail.text = saveError ?? "Use AI to ask questions about pages and summarise them. Your API key is stored securely on this device."
        detail.textColor = saveError == nil ? .secondaryLabel : .systemRed
    }

    private func saveKey() {
        cancelValidation()
        do { try settings.setKey(keyField.text ?? "", for: settings.provider); saveError = nil }
        catch { saveError = error.localizedDescription }
        updateDetail()
        refreshKeyMenu()
        setNeedsLayout()
    }

    private func cancelValidation() {
        validationID = UUID()
        validationTask?.cancel()
        validationTask = nil
        validation = .unchecked
        let callbacks = loadingCompletions
        loadingCompletions.removeAll()
        withoutMenuAnimation { callbacks.forEach { $0([checkAction()]) } }
    }

    private func checkAction() -> UIAction {
        let title: String, symbol: String
        var attributes: UIMenuElement.Attributes = [.keepsMenuPresented]
        switch validation {
        case .unchecked: title = "Check key"; symbol = "key"
        case .checking: title = "Checking key…"; symbol = ""
        case .valid: title = "Key valid"; symbol = "checkmark.circle"; attributes.insert(.disabled)
        case .invalid: title = "Invalid API key"; symbol = "xmark.circle"; attributes.formUnion([.destructive, .disabled])
        case .unavailable: title = "Couldn’t check key — retry"; symbol = "arrow.clockwise"
        }
        if (keyField.text ?? "").isEmpty || saveError != nil { attributes.insert(.disabled) }
        return UIAction(title: title, image: UIImage(systemName: symbol), attributes: attributes) { [weak self] _ in
            self?.checkKey()
        }
    }

    private func makeKeyMenu() -> UIMenu {
        guard validation == .checking else { return UIMenu(children: [checkAction()]) }
        // UIKit supplies its own animated loading indicator for unresolved deferred elements.
        // Keep it untitled so checking doesn't add a heading or increase the menu's height.
        return UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { completion([]); return }
            if validation == .checking { loadingCompletions.append(completion) }
            else { completion([checkAction()]) }
        }])
    }

    private func withoutMenuAnimation(_ update: () -> Void) {
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            update()
            CATransaction.commit()
        }
    }

    private func refreshKeyMenu(updatingVisible: Bool = true) {
        withoutMenuAnimation {
            keyMenuButton.menu = makeKeyMenu()
            if updatingVisible {
                keyMenuButton.contextMenuInteraction?.updateVisibleMenu { [weak self] _ in self?.makeKeyMenu() ?? UIMenu() }
            }
        }
    }

    private func checkKey() {
        guard validation != .checking, saveError == nil else { return }
        validation = .checking
        let provider = settings.provider, key = settings.key(for: provider), id = UUID()
        validationID = id
        refreshKeyMenu()
        validationTask = Task { [weak self] in
            let clock = ContinuousClock()
            let minimumDisplayEnd = clock.now.advanced(by: .milliseconds(750))
            let result = await AIKeyValidator.check(key, provider: provider)
            do { try await clock.sleep(until: minimumDisplayEnd) }
            catch { return }
            guard !Task.isCancelled, let self, validationID == id else { return }
            validation = result
            validationTask = nil
            let callbacks = loadingCompletions
            loadingCompletions.removeAll()
            withoutMenuAnimation {
                callbacks.forEach { $0([checkAction()]) }
                // Resolving a deferred element already replaces the visible loading row.
                // Replacing the entire visible menu again caused a second transition.
                refreshKeyMenu(updatingVisible: callbacks.isEmpty)
            }
        }
    }

    func height(for width: CGFloat) -> CGFloat {
        rowsHeight+12+detail.sizeThatFits(CGSize(width: max(0,width-32), height: .greatestFiniteMagnitude)).height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rowHeight = SiteSettingsPanel.rowHeight, width = bounds.width, textX: CGFloat = 54
        group.frame = CGRect(x: 0, y: 0, width: width, height: rowsHeight)
        for (index, row) in [enabledRow, providerRow, keyRow].enumerated() {
            row.frame = CGRect(x: 0, y: CGFloat(index)*rowHeight, width: width, height: rowHeight)
        }
        for icon in [providerIcon, keyIcon] { icon.frame = CGRect(x: 17, y: rowHeight/2-13, width: 26, height: 26) }
        let providerWidth = min(width*0.47, providerButton.sizeThatFits(CGSize(width: width, height: rowHeight)).width)
        providerButton.frame = CGRect(x: width-16-providerWidth, y: 0, width: providerWidth, height: rowHeight)
        providerTitle.frame = CGRect(x: textX, y: 0, width: max(0,providerButton.frame.minX-textX-8), height: rowHeight)
        keyTitle.sizeToFit()
        keyTitle.frame = CGRect(x: textX, y: 0, width: keyTitle.bounds.width, height: rowHeight)
        keyMenuButton.frame = CGRect(x: keyTitle.frame.maxX+2, y: 8, width: 34, height: rowHeight-16)
        let fieldWidth = min(max(44, providerWidth-8), max(0, width-16-keyMenuButton.frame.maxX-6))
        keyField.frame = CGRect(x: width-16-fieldWidth, y: 0, width: fieldWidth, height: rowHeight)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fieldMask.frame = keyField.bounds
        CATransaction.commit()
        let bulletWidth = ("•" as NSString).size(withAttributes: [.font: maskedKey.font!]).width
        let key = keyField.text ?? ""
        let editing = keyField.isFirstResponder
        let textWidth = editing ? (key as NSString).size(withAttributes: [.font: keyField.font!]).width
            : CGFloat(key.count)*bulletWidth
        let overflowing = textWidth > keyField.bounds.width
        maskedKey.frame = keyField.frame
        maskedKey.text = String(repeating: "•", count: key.count)
        maskedKey.textAlignment = overflowing ? .left : .right
        maskedKey.isHidden = editing || key.isEmpty
        keyField.textColor = editing ? .label : .clear
        maskedKey.layer.mask = nil
        keyField.layer.mask = nil
        if overflowing {
            if editing { keyField.layer.mask = fieldMask }
            else { maskedKey.layer.mask = fieldMask }
        }
        let hairline = 1/max(1,traitCollection.displayScale)
        for (index, divider) in dividers.enumerated() {
            divider.frame = CGRect(x: 16, y: CGFloat(index+1)*rowHeight-hairline/2, width: width-32, height: hairline)
        }
        detail.frame = CGRect(x: 16, y: rowsHeight+12, width: width-32, height: max(0,bounds.height-rowsHeight-12))
    }

    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        textField.isSecureTextEntry = false
        return true
    }
    func textFieldDidBeginEditing(_ textField: UITextField) { setNeedsLayout(); layoutIfNeeded(); onEditing?() }
    func textFieldDidEndEditing(_ textField: UITextField) {
        textField.isSecureTextEntry = true
        textField.textColor = .clear
        saveKey()
        setNeedsLayout(); layoutIfNeeded()
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { textField.resignFirstResponder(); return true }
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard let text = textField.text, let range = Range(range, in: text) else { return false }
        let candidate = text.replacingCharacters(in: range, with: string)
        return candidate.count <= 4096 && !candidate.contains(where: { $0.isNewline })
    }
}
