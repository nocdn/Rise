import AppKit
import AVKit

/// Particle Rename Lab (scripts/particle-rename-lab.sh): the reference recording above Rise's
/// version of it, both at actual size, with buttons for each state and sliders for the timing.
///
/// `--strip <png>` instead writes a contact sheet of the reveal at the reference's frame times,
/// for comparing the two without a screen recording.
@main @MainActor final class Lab: NSObject, NSApplicationDelegate {
    static var shared: Lab?
    static func main() {
        let app = NSApplication.shared, lab = Lab(); shared = lab
        app.delegate = lab; app.setActivationPolicy(.regular); app.run()
    }

    private var window: NSWindow!
    private let row = RowMock()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private let oldName = NSTextField(string: "97103328759-2026-08-01-2026-08-31.pdf")
    private let newName = NSTextField(string: "Lunar Statement Aug 2026.pdf")
    private let stateLabel = NSTextField(labelWithString: "")
    private let scrubber = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var speed: Double = 1
    private var playAllToken = UUID()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--strip"), index+1 < arguments.count { writeStrip(to: arguments[index+1]); exit(0) }
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 720), styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Particle Rename Lab"
        window.contentView = content()
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        row.title.onStateChange = { [weak self] state in self?.showState(state) }
        row.title.setText(oldName.stringValue); row.detail(for: .text, old: oldName.stringValue, renamed: false)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let main = NSMenu(), item = NSMenuItem(); main.addItem(item)
        let menu = NSMenu(); menu.addItem(withTitle: "Quit Particle Rename Lab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = menu; NSApp.mainMenu = main
    }

    // MARK: Layout

    private func content() -> NSView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        stack.addArrangedSubview(caption("Reference, at actual size"))
        stack.addArrangedSubview(referencePlayer())
        stack.addArrangedSubview(caption("Rise"))
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([row.widthAnchor.constraint(equalToConstant: 339), row.heightAnchor.constraint(equalToConstant: 75)])
        stack.addArrangedSubview(row)
        stateLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular); stateLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(stateLabel)

        stack.addArrangedSubview(buttons([
            ("Old name", #selector(showOld)), ("Dissolve", #selector(dissolve)), ("Thinking", #selector(thinking)),
            ("Reveal", #selector(reveal)), ("New name", #selector(showNew)), ("Play all", #selector(playAll)), ("Reset", #selector(reset)),
        ]))
        stack.addArrangedSubview(form([("Old name", oldName), ("New name", newName)]))

        scrubber.target = self; scrubber.action = #selector(scrub(_:)); scrubber.isContinuous = true
        let resume = NSButton(title: "Resume", target: self, action: #selector(resume))
        stack.addArrangedSubview(form([("Scrub", hStack([scrubber, resume]))]))

        let tuning = row.title.tuning
        stack.addArrangedSubview(form([
            ("Speed", slider(value: 1, range: 0.05...1.5, format: "%.2f×") { [weak self] in self?.setSpeed($0) }),
            ("Sweep", slider(value: Double(tuning.sweepSpeed), range: 80...700, format: "%.0f pt/s") { [weak self] in self?.row.title.tuning.sweepSpeed = CGFloat($0) }),
            ("Ease-out", slider(value: Double(tuning.sweepEase), range: 1...3, format: "%.2f") { [weak self] in self?.row.title.tuning.sweepEase = CGFloat($0) }),
            ("Flight", slider(value: tuning.flight, range: 0.05...0.8, format: "%.2f s") { [weak self] in self?.row.title.tuning.flight = $0 }),
            ("Solidify", slider(value: tuning.solidify, range: 0.03...0.6, format: "%.2f s") { [weak self] in self?.row.title.tuning.solidify = $0 }),
            ("Stagger", slider(value: tuning.stagger, range: 0...0.4, format: "%.2f s") { [weak self] in self?.row.title.tuning.stagger = $0 }),
            ("Glow", slider(value: Double(tuning.glowStrength), range: 0...1, format: "%.2f") { [weak self] in self?.row.title.tuning.glowStrength = CGFloat($0) }),
            ("Settle", slider(value: Double(tuning.settle), range: 0...1, format: "%.2f") { [weak self] in self?.row.title.tuning.settle = CGFloat($0) }),
            ("Density", slider(value: Double(tuning.density), range: 0.08...0.8, format: "%.2f /pt²") { [weak self] in self?.row.title.tuning.density = CGFloat($0) }),
            ("Dot spacing", slider(value: Double(tuning.dotSpacing), range: 0.6...2.4, format: "%.2f pt") { [weak self] in self?.row.title.tuning.dotSpacing = CGFloat($0) }),
            ("Drift", slider(value: Double(tuning.drift), range: 0...3, format: "%.2f pt") { [weak self] in self?.row.title.tuning.drift = CGFloat($0) }),
        ]))
        let looks = NSSegmentedControl(labels: ["Reference", "Dark popover", "Light popover"], trackingMode: .selectOne, target: self, action: #selector(look(_:)))
        looks.selectedSegment = 0
        stack.addArrangedSubview(form([("Background", looks)]))
        row.setLook(.reference)
        return stack
    }

    private func referencePlayer() -> NSView {
        let view = AVPlayerView(); view.controlsStyle = .none
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: 339), view.heightAnchor.constraint(equalToConstant: 75)])
        if let url = Bundle.main.url(forResource: "particle-rename-reference", withExtension: "mp4") {
            let item = AVPlayerItem(url: url), player = AVQueuePlayer()
            player.isMuted = true; looper = AVPlayerLooper(player: player, templateItem: item)
            view.player = player; self.player = player; player.play()
        }
        return view
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 11, weight: .medium); label.textColor = .secondaryLabelColor
        return label
    }
    private func buttons(_ items: [(String, Selector)]) -> NSStackView {
        hStack(items.map { NSButton(title: $0.0, target: self, action: $0.1) })
    }
    private func hStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 8; return stack
    }
    private func form(_ rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.column(at: 0).xPlacement = .trailing; grid.rowSpacing = 6; grid.columnSpacing = 10
        for (_, view) in rows { if let field = view as? NSTextField, field.isEditable { field.widthAnchor.constraint(equalToConstant: 360).isActive = true } }
        return grid
    }
    private var sliderActions: [ObjectIdentifier: (Double) -> Void] = [:]
    private var sliderReadouts: [ObjectIdentifier: (NSTextField, String)] = [:]
    private func slider(value: Double, range: ClosedRange<Double>, format: String, action: @escaping (Double) -> Void) -> NSView {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: #selector(slid(_:)))
        slider.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let readout = NSTextField(labelWithString: String(format: format, value))
        readout.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); readout.widthAnchor.constraint(equalToConstant: 80).isActive = true
        sliderActions[ObjectIdentifier(slider)] = action; sliderReadouts[ObjectIdentifier(slider)] = (readout, format)
        return hStack([slider, readout])
    }
    @objc private func slid(_ slider: NSSlider) {
        sliderActions[ObjectIdentifier(slider)]?(slider.doubleValue)
        if let (readout, format) = sliderReadouts[ObjectIdentifier(slider)] { readout.stringValue = String(format: format, slider.doubleValue) }
    }

    // MARK: Actions

    private func setSpeed(_ value: Double) {
        speed = value; row.title.timeScale = value
        player?.rate = Float(value)
    }
    private func showState(_ state: ParticleTextView.State) {
        stateLabel.stringValue = "state: \(state.rawValue)"
        if state == .text || state == .cloud { scrubber.doubleValue = state == .text ? 1 : 0 }
    }
    @objc private func showOld() { cancelPlayAll(); row.title.isPaused = false; row.title.setText(oldName.stringValue); row.detail(for: .text, old: oldName.stringValue, renamed: false) }
    @objc private func dissolve() {
        cancelPlayAll(); row.title.isPaused = false
        if row.title.state != .text || row.title.text != oldName.stringValue { row.title.setText(oldName.stringValue) }
        row.detail(for: .dissolving, old: oldName.stringValue, renamed: false); row.title.dissolve()
    }
    @objc private func thinking() { cancelPlayAll(); row.title.isPaused = false; row.title.showCloud(); row.detail(for: .cloud, old: oldName.stringValue, renamed: false) }
    @objc private func reveal() {
        cancelPlayAll(); row.title.isPaused = false
        row.title.reveal(newName.stringValue); row.detail(for: .revealing, old: oldName.stringValue, renamed: true)
    }
    @objc private func showNew() { cancelPlayAll(); row.title.isPaused = false; row.title.setText(newName.stringValue); row.detail(for: .text, old: oldName.stringValue, renamed: true) }
    @objc private func reset() { showOld(); player?.seek(to: .zero); player?.rate = Float(speed) }
    /// Old name, scattering into the cloud, a moment of thinking, then the new name.
    @objc private func playAll() {
        showOld()
        let token = UUID(); playAllToken = token
        after(0.5) { [weak self] in
            guard let self, self.playAllToken == token else { return }
            self.row.detail(for: .dissolving, old: self.oldName.stringValue, renamed: false); self.row.title.dissolve()
            self.after(self.row.title.transitionDuration+1.4) { [weak self] in
                guard let self, self.playAllToken == token else { return }
                self.row.title.reveal(self.newName.stringValue); self.row.detail(for: .revealing, old: self.oldName.stringValue, renamed: true)
            }
        }
    }
    private func cancelPlayAll() { playAllToken = UUID() }
    private func after(_ seconds: Double, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now()+seconds/max(speed, 0.05), execute: body)
    }
    @objc private func scrub(_ slider: NSSlider) {
        cancelPlayAll()
        if row.title.state == .text || row.title.state == .cloud { row.title.reveal(newName.stringValue); row.detail(for: .revealing, old: oldName.stringValue, renamed: true) }
        row.title.scrub(to: slider.doubleValue)
    }
    @objc private func resume() { row.title.isPaused = false }
    @objc private func look(_ control: NSSegmentedControl) {
        row.setLook([RowMock.Look.reference, .dark, .light][control.selectedSegment])
    }

    // MARK: Strip

    /// The reveal at the reference's frame times (60 fps), each frame on the reference's colour.
    private func writeStrip(to path: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 339, height: 75), styleMask: [.borderless], backing: .buffered, defer: false)
        let row = RowMock(frame: NSRect(x: 0, y: 0, width: 339, height: 75)); row.setLook(.reference)
        window.contentView = row; row.layoutSubtreeIfNeeded()
        let times = stride(from: 0.0, through: 1.15, by: 0.05).map { $0 }
        let frames = row.title.revealFrames(of: "Lunar Statement Aug 2026.pdf", from: nil, times: times)
        let scale: CGFloat = 2, frameSize = row.title.bounds.size
        let sheet = NSImage(size: NSSize(width: frameSize.width*scale, height: frameSize.height*scale*CGFloat(frames.count)), flipped: true) { rect in
            NSColor(srgbRed: 0.29, green: 0.25, blue: 0.93, alpha: 1).setFill(); rect.fill()
            for (index, frame) in frames.enumerated() {
                frame.draw(in: NSRect(x: 0, y: CGFloat(index)*frameSize.height*scale, width: frameSize.width*scale, height: frameSize.height*scale),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            return true
        }
        guard let tiff = sheet.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(frames.count) frames at \(times) s to \(path)")
    }
}

/// A download row as the reference draws one: a file icon, the title the particles form,
/// and the old name below.
@MainActor final class RowMock: NSView {
    enum Look { case reference, dark, light }
    let title = ParticleTextView()
    private let icon = NSImageView(), detailLabel = NSTextField(labelWithString: "")
    private let background = CAGradientLayer(), material = NSVisualEffectView()
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        background.cornerRadius = 22; background.cornerCurve = .continuous
        background.startPoint = CGPoint(x: 0, y: 0.5); background.endPoint = CGPoint(x: 1, y: 0.5)
        background.colors = [NSColor(srgbRed: 0.18, green: 0.44, blue: 0.95, alpha: 1).cgColor, NSColor(srgbRed: 0.42, green: 0.22, blue: 0.93, alpha: 1).cgColor]
        material.material = .popover; material.state = .active; material.wantsLayer = true
        material.layer?.cornerRadius = 22; material.layer?.cornerCurve = .continuous
        layer?.addSublayer(background); addSubview(material)
        icon.image = NSWorkspace.shared.icon(for: .pdf)
        detailLabel.font = .systemFont(ofSize: 11); detailLabel.lineBreakMode = .byTruncatingMiddle
        [icon, title, detailLabel].forEach(addSubview)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let card = bounds.insetBy(dx: 6, dy: 6)
        background.frame = card; material.frame = card
        CATransaction.commit()
        icon.frame = NSRect(x: 22, y: 21, width: 32, height: 32)
        title.frame = NSRect(x: 61, y: 16, width: 212, height: 22)
        detailLabel.frame = NSRect(x: 63, y: 39, width: 210, height: 15)
    }

    func setLook(_ look: Look) {
        background.isHidden = look != .reference; material.isHidden = look == .reference
        appearance = NSAppearance(named: look == .light ? .aqua : .darkAqua)
        title.textColor = look == .reference ? .white : .labelColor
        detailLabel.textColor = look == .reference ? NSColor.white.withAlphaComponent(0.55) : .secondaryLabelColor
        title.needsDisplay = true
    }

    /// The old name, struck through once the new one is on its way.
    func detail(for state: ParticleTextView.State, old: String, renamed: Bool) {
        if state == .text && !renamed { detailLabel.stringValue = "2.1 MB · PDF"; return }
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingMiddle
        detailLabel.attributedStringValue = NSAttributedString(string: old, attributes: [
            .paragraphStyle: style, .strikethroughStyle: NSUnderlineStyle.single.rawValue, .font: NSFont.systemFont(ofSize: 11), .foregroundColor: detailLabel.textColor ?? .secondaryLabelColor,
        ])
    }
}
