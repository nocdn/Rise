import UIKit

/// The panel's search: a rounded field like the New Page button, with Google's suggestions
/// underneath as the person types. Choosing a suggestion searches Google for it; Go opens what
/// was typed, as an address when it looks like one.
final class SearchPanel: UIView, UITextFieldDelegate {
    static let fieldHeight: CGFloat = 48
    static let rowHeight: CGFloat = 48
    /// Between the field and the first suggestion.
    static let rowsGap: CGFloat = 10
    /// As many as fit above the keyboard on an iPhone.
    static let maximumSuggestions = 4
    static let inset: CGFloat = 16
    /// Suggestions sit this far inside the field's left edge, which balances them better than lining up.
    static let rowIndent: CGFloat = 5
    /// How small a suggestion gets while pressed.
    static let pressedScale: CGFloat = 0.97
    /// The field and as many suggestions as show.
    static var height: CGFloat { fieldHeight+rowsGap+CGFloat(maximumSuggestions)*rowHeight }
    /// The field's corners: rounded, rather than a capsule.
    static let cornerRadius: CGFloat = 14
    /// The field's fill, as on Arc Search's, translucent over dark pages.
    static let fill = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.1) : UIColor(red: 248/255, green: 249/255, blue: 250/255, alpha: 1) }
    /// The fill under a finger: a little darker, or lighter over dark pages.
    static let pressedFill = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.16) : UIColor(red: 236/255, green: 237/255, blue: 240/255, alpha: 1) }
    /// The magnifying glass's colour, beside each suggestion.
    static let iconColor = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.5) : UIColor(red: 165/255, green: 167/255, blue: 172/255, alpha: 1) }
    /// The field's text is the system's semibold rounded; the suggestions are Open Runde Medium,
    /// bundled under the SIL Open Font License.
    static var fieldFont: UIFont { roundedFont(weight: .semibold) }
    static var font: UIFont {
        let font = UIFont(name: "OpenRunde-Medium", size: 17) ?? roundedFont(ofSize: 17, weight: .medium, scaled: false)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: font)
    }
    static func roundedFont(ofSize size: CGFloat = 17, weight: UIFont.Weight, scaled: Bool = true) -> UIFont {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        let rounded = font.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? font
        return scaled ? UIFontMetrics(forTextStyle: .body).scaledFont(for: rounded) : rounded
    }
    /// The system's bold magnifying glass at 16 points, redrawn with its handle as thick as its ring
    /// and about as long. Drawn rather than a symbol, so the suggestions' buttons don't resize it
    /// to their text.
    static let searchIcon: UIImage = {
        let line: CGFloat = 2.5, outerRadius: CGFloat = 7.33
        let centre = CGPoint(x: 7.4, y: 7.4), radius = outerRadius-line/2
        // The handle's tip, round cap included, from the ring's centre; the symbol's reaches 11.8.
        let tip: CGFloat = 11.9, diagonal = 1/CGFloat(2).squareRoot()
        let point = { (distance: CGFloat) in CGPoint(x: centre.x+distance*diagonal, y: centre.y+distance*diagonal) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in
            UIColor.black.setStroke()
            let ring = UIBezierPath(arcCenter: centre, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
            ring.lineWidth = line
            ring.stroke()
            let handle = UIBezierPath()
            handle.move(to: point(radius))
            handle.addLine(to: point(tip-line/2))
            handle.lineWidth = line
            handle.lineCapStyle = .round
            handle.stroke()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }()

    let field = SearchField()
    private(set) var editingAddress: AddressBar?
    private(set) var suggestions: [String] = []
    private var rows: [UIButton] = []
    private var fetch: Task<Void, Never>?
    /// One soft click for clearing; two in quick succession for opening a page.
    private let click = UIImpactFeedbackGenerator(style: .rigid)
    /// The address editor's X, always at the field's end: it clears the field, or once it's empty
    /// closes the panel.
    let clearButton = AnimatedSymbolButton(symbol: "xmark", pointSize: 14, weight: .bold)
    /// Stands in for the X while a held New Page's speech is transcribed.
    let transcribing = UIActivityIndicatorView(style: .medium)
    /// Closes the panel, as X does on an empty field.
    var onClose: @MainActor () -> Void = {}
    /// Counts openings, so a transcription lands only in the opening it was said for.
    private var opening = 0
    /// Opens a page the person chose.
    var onOpen: @MainActor (URL) -> Void = { _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        field.backgroundColor = Self.fill
        field.layer.cornerCurve = .continuous
        field.layer.cornerRadius = Self.cornerRadius
        field.placeholder = "Search or enter URL"
        field.font = Self.fieldFont
        field.adjustsFontForContentSizeCategory = true
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 18, height: 1))
        field.leftViewMode = .always
        field.keyboardType = .webSearch
        field.returnKeyType = .go
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.delegate = self
        field.addAction(UIAction { [weak self] _ in self?.queryChanged() }, for: .editingChanged)
        addSubview(field)
        useClearButton()
        clearButton.accessibilityLabel = "Clear"
        clearButton.shrinksWhenPressed(to: AddressBar.pressedScale)
        clearButton.addAction(UIAction { [weak self] _ in self?.clearOrClose() }, for: .primaryActionTriggered)
        addSubview(clearButton)
        transcribing.hidesWhenStopped = true
        transcribing.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        transcribing.accessibilityLabel = "Transcribing"
        addSubview(transcribing)
    }

    /// The field's own clear button gives way to the X, with room kept for it.
    private func useClearButton() {
        field.clearButtonMode = .never
        field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: Self.fieldHeight))
        field.rightViewMode = .always
        clearButton.isHidden = transcribing.isAnimating
    }

    /// Clears what's typed, as the address editor's X does, or closes the panel if there's nothing.
    private func clearOrClose() {
        guard !(field.text ?? "").isEmpty else { onClose(); return }
        field.text = ""
        queryChanged()
        click.impactOccurred(intensity: 0.5)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width-2*Self.inset
        let frame = CGRect(x: Self.inset, y: 0, width: width, height: Self.fieldHeight)
        if let editingAddress {
            editingAddress.frame = frame
            editingAddress.layoutIfNeeded()
        } else { field.frame = frame }
        // Where the address editor's X sits. By bounds and center, as it shrinks while pressed.
        clearButton.bounds = CGRect(x: 0, y: 0, width: AddressBar.buttonWidth, height: Self.fieldHeight)
        clearButton.center = CGPoint(x: frame.maxX-AddressBar.outerCentre, y: frame.midY)
        transcribing.center = clearButton.center
        for (index, row) in rows.enumerated() {
            // By bounds and center, as a pressed row is scaled.
            row.bounds = CGRect(x: 0, y: 0, width: width, height: Self.rowHeight)
            row.center = CGPoint(x: bounds.midX, y: Self.fieldHeight+Self.rowsGap+(CGFloat(index)+0.5)*Self.rowHeight)
        }
    }

    /// Each time the panel opens, the field starts empty and focused.
    func begin() {
        fetch?.cancel()
        opening += 1
        stopTranscribing()
        field.text = ""
        show([])
        field.becomeFirstResponder()
        click.prepare()
    }

    /// Shows a small spinner where the clear button would be until `finishTranscribing`, which
    /// is ignored if the panel has since closed or opened again.
    func beginTranscribing() -> Int {
        clearButton.isHidden = true
        transcribing.startAnimating()
        return opening
    }

    /// Puts what was said in the field, after anything typed meanwhile, ready for Go.
    func finishTranscribing(_ text: String, for opening: Int) {
        guard opening == self.opening, transcribing.isAnimating else { return }
        stopTranscribing()
        guard !text.isEmpty else { return }
        let typed = (field.text ?? "").trimmingCharacters(in: .whitespaces)
        field.text = typed.isEmpty ? text : typed+" "+text
        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        queryChanged()
        click.impactOccurred(intensity: 0.5)
    }

    private func stopTranscribing() {
        guard transcribing.isAnimating else { return }
        transcribing.stopAnimating()
        clearButton.isHidden = editingAddress != nil
    }

    /// The address is carried into this panel, rather than crossfading to a duplicate field.
    func beginEditingAddress(_ address: AddressBar, url: URL?) {
        fetch?.cancel()
        opening += 1
        stopTranscribing()
        show([])
        editingAddress = address
        addSubview(address)
        field.text = url?.absoluteString ?? ""
        address.prepareEditing(field, url: url)
        // The address has its own X.
        clearButton.isHidden = true
        click.prepare()
    }

    func focusAddress() {
        guard editingAddress != nil else { return }
        field.isUserInteractionEnabled = true
        field.becomeFirstResponder()
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
    }

    func finishAddressTransition() { editingAddress?.finishEditing() }

    /// Restore the regular New Page field and return the address to More before another opening.
    func releaseAddress() {
        guard let address = editingAddress else { return }
        editingAddress = nil
        address.endEditingAddress()
        addSubview(field)
        bringSubviewToFront(clearButton)
        bringSubviewToFront(transcribing)
        field.backgroundColor = Self.fill
        useClearButton()
        field.alpha = 1
        field.isUserInteractionEnabled = true
        setNeedsLayout()
    }

    func clearAddress() {
        guard let editingAddress else { return }
        editingAddress.host.text = ""
        field.text = ""
        queryChanged()
        field.becomeFirstResponder()
        click.impactOccurred(intensity: 0.5)
    }

    func end() {
        fetch?.cancel()
        opening += 1
        stopTranscribing()
        field.resignFirstResponder()
    }

    private func queryChanged() {
        // Input can arrive while the spring is still running: show it immediately without
        // selecting it again when the label's animation finishes.
        editingAddress?.finishEditing()
        fetch?.cancel()
        let query = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let url = Self.suggestionsURL(for: query) else { show([]); return }
        fetch = Task { [weak self] in
            let response = try? await URLSession.shared.data(from: url)
            // Only the latest query's suggestions show, however the responses arrive.
            guard let data = response?.0, !Task.isCancelled, let self,
                  (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == query
            else { return }
            show(Self.suggestions(from: data))
        }
    }

    private func show(_ suggestions: [String]) {
        let suggestions = Array(suggestions.prefix(Self.maximumSuggestions))
        guard suggestions != self.suggestions else { return }
        self.suggestions = suggestions
        rows.forEach { $0.removeFromSuperview() }
        rows = suggestions.map { suggestion in
            var configuration = UIButton.Configuration.plain()
            configuration.title = suggestion
            configuration.image = Self.searchIcon
            configuration.imagePadding = 12
            configuration.baseForegroundColor = .label
            // The field's grey, rather than the title's colour.
            configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in SearchPanel.iconColor }
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Self.rowIndent, bottom: 0, trailing: 18)
            configuration.titleLineBreakMode = .byTruncatingTail
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = SearchPanel.font
                return attributes
            }
            let row = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                self?.choose(suggestion)
            })
            row.contentHorizontalAlignment = .leading
            row.shrinksWhenPressed(to: Self.pressedScale)
            addSubview(row)
            return row
        }
        setNeedsLayout()
    }

    /// Searches Google for a suggestion.
    func choose(_ suggestion: String) {
        guard let url = Self.searchURL(for: suggestion) else { return }
        open(url)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if let url = Self.destination(for: textField.text ?? "") { open(url) }
        return false
    }

    func textFieldShouldClear(_ textField: UITextField) -> Bool {
        click.impactOccurred(intensity: 0.5)
        return true
    }

    private func open(_ url: URL) {
        click.impactOccurred(intensity: 0.5)
        DispatchQueue.main.asyncAfter(deadline: .now()+0.07) { [click] in click.impactOccurred(intensity: 0.5) }
        onOpen(url)
    }

    static func suggestionsURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://suggestqueries.google.com/complete/search")
        components?.queryItems = [URLQueryItem(name: "client", value: "firefox"), URLQueryItem(name: "ie", value: "utf-8"),
                                  URLQueryItem(name: "oe", value: "utf-8"), URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    /// Google's suggestions come back as `[query, [suggestion, …], …]`.
    static func suggestions(from data: Data) -> [String] {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [Any], response.count > 1 else { return [] }
        return response[1] as? [String] ?? []
    }

    static func searchURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    /// An address when the text looks like one, such as `example.com` or `https://…`, and a
    /// Google search otherwise.
    static func destination(for text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
           url.host != nil {
            return url
        }
        if !text.contains(" "), text.contains("."), !text.hasPrefix("."), !text.hasSuffix("."),
           let url = URL(string: "https://"+text), url.host?.contains(".") == true {
            return url
        }
        return searchURL(for: text)
    }
}

/// The search field, with its clear button as far from the right end as from the top and bottom.
/// Shaking the phone while it's focused clears it, with two sharp taps, rather than offering to
/// undo the typing.
final class SearchField: UITextField {
    private let shake = UIImpactFeedbackGenerator(style: .rigid)

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            UIApplication.shared.applicationSupportsShakeToEdit = false
            shake.prepare()
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { UIApplication.shared.applicationSupportsShakeToEdit = true }
        return resigned
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake, isFirstResponder else { return super.motionEnded(motion, with: event) }
        guard !(text ?? "").isEmpty else { return }
        text = ""
        // As typing would, so the suggestions clear too.
        sendActions(for: .editingChanged)
        shake.impactOccurred(intensity: 1)
        DispatchQueue.main.asyncAfter(deadline: .now()+0.1) { [shake] in shake.impactOccurred(intensity: 1) }
    }

    override func clearButtonRect(forBounds bounds: CGRect) -> CGRect {
        let button = super.clearButtonRect(forBounds: bounds)
        let padding = (bounds.height-button.height)/2
        return CGRect(x: bounds.maxX-padding-button.width, y: bounds.minY+padding, width: button.width, height: button.height)
    }

    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        var rect = super.editingRect(forBounds: bounds)
        guard clearButtonMode != .never, isEditing, !(text ?? "").isEmpty else { return rect }
        rect.size.width = min(rect.width, clearButtonRect(forBounds: bounds).minX-6-rect.minX)
        return rect
    }
}
