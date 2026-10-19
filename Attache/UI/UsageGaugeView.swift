//
//  UsageGaugeView.swift
//  Attache
//

import AppKit

/// One rate-limit window: how much of it has been spent, and how much of it has
/// simply gone by.
///
/// **The mark is the whole point.** A percentage answers "how much have I
/// used", which is the easy half. The question that decides whether to keep
/// working is "am I spending it faster than the clock", and no single number
/// answers that — 63% used means one thing four hours into a five-hour window
/// and something else entirely twenty minutes in. So the bar carries a second
/// mark at `elapsedFraction`, and the comparison is the reading: bar short of
/// the mark is spending slower than the clock, bar past it will run out early.
///
/// Built from plain subviews rather than `draw(_:)` on purpose. A view that
/// draws gets a backing layer taller than itself on macOS 26, and the overhang
/// is not clipped — see the sibling-overdraw note in CLAUDE.md. Nothing here
/// needs a drawing pass, so nothing here takes that risk.
final class UsageGaugeView: NSView {
    enum LayoutStyle {
        /// Label and value on the top row, full-section-width bar below (Schemes A & C).
        case stacked
        /// Title on the left, compact short bar in the middle, value on the right (Scheme B).
        case inlineShort
    }

    static let height: CGFloat = 20
    static let inlineHeight: CGFloat = 15

    var layoutStyle: LayoutStyle = .stacked {
        didSet {
            if layoutStyle != oldValue { needsLayout = true }
        }
    }

    var rowHeight: CGFloat {
        switch layoutStyle {
        case .stacked: Self.height
        case .inlineShort: Self.inlineHeight
        }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let track = NSView()
    private let fill = NSView()
    private let mark = NSView()

    /// The window to draw, or nil to draw nothing.
    var usage: AccountUsage.Window? {
        didSet { apply() }
    }

    /// Half of what this view shows is a clock reading, and nothing else in the
    /// app ticks.
    ///
    /// The countdown, the elapsed mark and the tooltip's "faster than the
    /// clock" are all computed from `Date()` at the moment `usage` is set — and
    /// `usage` is deliberately only set when the *parsed* numbers change, so
    /// that the rail does not rebuild every five seconds. Those two facts
    /// together mean an account nobody is spending against would sit on
    /// `4h54m` for as long as the numbers held still, which is precisely when
    /// the countdown is the only thing on the gauge still moving.
    ///
    /// Thirty seconds keeps a minute-resolution countdown honest. The timer
    /// runs only while the gauge is in a window and has something to draw.
    private var tick: Timer?

    deinit { tick?.invalidate() }

    override var isFlipped: Bool { true }

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 9.5, weight: .regular)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        detailLabel.alignment = .right
        for label in [titleLabel, detailLabel] {
            label.isSelectable = false
            label.refusesFirstResponder = true
            addSubview(label)
        }

        for bar in [track, fill, mark] {
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 2.25
        }
        mark.layer?.cornerRadius = 0.75
        track.addSubview(fill)
        track.addSubview(mark)
        addSubview(track)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func applyTheme() { apply() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTicking()
    }

    private func updateTicking() {
        let wanted = usage != nil && window != nil
        if wanted, tick == nil {
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                self?.refreshClock()
            }
            // `.common`, so the countdown keeps moving while the rail is being
            // scrolled or the window resized rather than freezing for the
            // duration of the gesture.
            RunLoop.main.add(timer, forMode: .common)
            tick = timer
        } else if !wanted {
            tick?.invalidate()
            tick = nil
        }
    }

    /// Everything that came from the clock rather than from the payload.
    private func refreshClock() {
        guard let usage else { return }
        detailLabel.stringValue = "\(usage.usedPercent)% · \(usage.countdown())"
        toolTip = Self.tooltip(for: usage, title: titleLabel.stringValue)
        needsLayout = true
    }

    private func apply() {
        defer { updateTicking() }
        guard let usage else {
            isHidden = true
            return
        }
        isHidden = false
        let theme = ChromeTheme.current

        detailLabel.stringValue = "\(usage.usedPercent)% · \(usage.countdown())"
        titleLabel.textColor = theme.faintText
        detailLabel.textColor = theme.mutedText

        let colour = Self.colour(forUsed: usage.usedPercent)
        track.layer?.backgroundColor = theme.faintText.withAlphaComponent(0.22).cgColor
        fill.layer?.backgroundColor = colour.cgColor
        // Deliberately neutral. The mark is a reference line, not a reading —
        // giving it a hue of its own would make the bar look like two
        // measurements racing rather than one measured against a ruler.
        mark.layer?.backgroundColor = theme.text.withAlphaComponent(0.55).cgColor

        toolTip = Self.tooltip(for: usage, title: titleLabel.stringValue)
        needsLayout = true
    }

    /// Green, amber, red at 50 and 75 — the thresholds coralline uses, so a
    /// rail and a status line on the same screen never disagree about whether
    /// a number is worth worrying about.
    private static func colour(forUsed percent: Int) -> NSColor {
        if percent >= 75 { return .systemRed }
        if percent >= 50 { return .systemYellow }
        return .systemGreen
    }

    private static func tooltip(for usage: AccountUsage.Window, title: String) -> String {
        let elapsed = Int((usage.elapsedFraction() * 100).rounded())
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        var lines = [
            "\(title): \(usage.usedPercent)% used, \(elapsed)% of the window gone",
            "resets at \(formatter.string(from: usage.resetsAt))",
        ]
        // Said in words, because the comparison is the reading and a mark on a
        // 22pt bar is a fine thing to miss.
        if usage.usedPercent > elapsed {
            lines.append("spending faster than the clock")
        } else if usage.usedPercent < elapsed {
            lines.append("spending slower than the clock")
        }
        return lines.joined(separator: "\n")
    }

    override func layout() {
        super.layout()
        guard let usage else { return }

        let barHeight: CGFloat = 4.5
        let used = min(1, max(0, Double(usage.usedPercent) / 100))
        let elapsed = usage.elapsedFraction()
        let markWidth: CGFloat = 1.5

        switch layoutStyle {
        case .stacked:
            let labelHeight: CGFloat = 12
            let detailWidth = min(
                ceil(detailLabel.attributedStringValue.size().width) + 1,
                max(0, bounds.width - 18)
            )
            detailLabel.frame = CGRect(
                x: bounds.maxX - detailWidth, y: 0, width: detailWidth, height: labelHeight
            )
            titleLabel.frame = CGRect(
                x: 0, y: 0,
                width: max(0, detailLabel.frame.minX - 4), height: labelHeight
            )
            track.frame = CGRect(x: 0, y: labelHeight + 2.5, width: bounds.width, height: barHeight)

        case .inlineShort:
            let labelHeight: CGFloat = 13
            let yOffset = floor((bounds.height - labelHeight) / 2)
            let titleWidth: CGFloat = 32
            let detailWidth = min(
                ceil(detailLabel.attributedStringValue.size().width) + 2,
                max(54, bounds.width - titleWidth - 28)
            )
            titleLabel.frame = CGRect(x: 0, y: yOffset, width: titleWidth, height: labelHeight)
            detailLabel.frame = CGRect(
                x: bounds.maxX - detailWidth, y: yOffset, width: detailWidth, height: labelHeight
            )
            let trackX = titleWidth + 4
            let trackW = max(16, detailLabel.frame.minX - trackX - 6)
            let trackY = floor((bounds.height - barHeight) / 2)
            track.frame = CGRect(x: trackX, y: trackY, width: trackW, height: barHeight)
        }

        let trackW = track.bounds.width
        fill.frame = CGRect(x: 0, y: 0, width: trackW * used, height: barHeight)
        let markX = min(trackW - markWidth, max(0, trackW * elapsed - markWidth / 2))
        mark.frame = CGRect(x: markX, y: -1.5, width: markWidth, height: barHeight + 3)
    }
}

/// A self-contained provider usage block (e.g. `Claude`, `Gemini`, or a future
/// provider) with its own header and rate-limit gauges.
///
/// Supports three visual schemes so they can be compared directly inside the
/// live sidebar:
/// - `.cardA`: Recessed rounded card with generous inner padding (`+10pt` inside
///   a `13pt` outer margin = `23pt` inset per side, keeping bars short).
/// - `.inlineB`: Top divider line with single-line compact inline bars (`~52pt` bar width).
/// - `.leftRuleC`: Left `2pt` colored vertical rule with wide horizontal margins.
final class UsageProviderSectionView: NSView {
    enum Scheme: Int, CaseIterable {
        case cardA = 0
        case inlineB = 1
        case leftRuleC = 2
    }

    struct ProviderDescriptor {
        let title: String
        let accent: NSColor

        static let claude = ProviderDescriptor(
            title: "Claude",
            accent: NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1.0)
        )
        static let gemini = ProviderDescriptor(
            title: "Gemini",
            accent: NSColor(srgbRed: 0.40, green: 0.62, blue: 0.96, alpha: 1.0)
        )
    }

    let provider: ProviderDescriptor
    var scheme: Scheme {
        didSet {
            if scheme != oldValue {
                syncGaugeStyles()
                applyTheme()
                needsLayout = true
            }
        }
    }

    var usage: AccountUsage? {
        didSet {
            fiveHourGauge.usage = usage?.fiveHour
            sevenDayGauge.usage = usage?.sevenDay
            threePFiveHourGauge.usage = usage?.threePFiveHour
            threePSevenDayGauge.usage = usage?.threePSevenDay
            argonGauge.usage = usage?.argonSevenDay
            isHidden = (usage == nil || usage?.isEmpty == true)
            needsLayout = true
        }
    }

    private let cardBox = NSView()
    private let topDivider = NSView()
    private let leftRule = NSView()
    private let dotView = NSView()
    private let headerLabel = NSTextField(labelWithString: "")

    private let fiveHourGauge = UsageGaugeView(title: "5h")
    private let sevenDayGauge = UsageGaugeView(title: "Week")
    private let threePFiveHourGauge = UsageGaugeView(title: "3P 5h")
    private let threePSevenDayGauge = UsageGaugeView(title: "3P Week")
    private let argonGauge = UsageGaugeView(title: "Argon")

    private var allGauges: [UsageGaugeView] {
        [fiveHourGauge, sevenDayGauge, threePFiveHourGauge, threePSevenDayGauge, argonGauge]
    }

    override var isFlipped: Bool { true }

    init(provider: ProviderDescriptor, scheme: Scheme = .cardA) {
        self.provider = provider
        self.scheme = scheme
        super.init(frame: .zero)
        isHidden = true

        for v in [cardBox, topDivider, leftRule, dotView] {
            v.wantsLayer = true
            addSubview(v)
        }
        cardBox.layer?.cornerRadius = 7
        cardBox.layer?.borderWidth = 1
        leftRule.layer?.cornerRadius = 1
        dotView.layer?.cornerRadius = 2.5

        headerLabel.stringValue = provider.title
        headerLabel.font = .systemFont(ofSize: 9.5, weight: .semibold)
        headerLabel.isSelectable = false
        headerLabel.refusesFirstResponder = true
        addSubview(headerLabel)

        for gauge in allGauges {
            gauge.isHidden = true
            addSubview(gauge)
        }

        syncGaugeStyles()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    private var visibleGauges: [UsageGaugeView] {
        allGauges.filter { !$0.isHidden }
    }

    private func syncGaugeStyles() {
        let style: UsageGaugeView.LayoutStyle = (scheme == .inlineB) ? .inlineShort : .stacked
        for gauge in allGauges {
            gauge.layoutStyle = style
        }
    }

    func applyTheme() {
        let theme = ChromeTheme.current
        headerLabel.textColor = theme.mutedText
        dotView.layer?.backgroundColor = provider.accent.cgColor

        cardBox.layer?.backgroundColor = theme.hover.withAlphaComponent(0.45).cgColor
        cardBox.layer?.borderColor = theme.separator.cgColor
        topDivider.layer?.backgroundColor = theme.separator.cgColor
        leftRule.layer?.backgroundColor = provider.accent.withAlphaComponent(0.6).cgColor

        cardBox.isHidden = (scheme != .cardA)
        topDivider.isHidden = (scheme != .inlineB)
        leftRule.isHidden = (scheme != .leftRuleC)
        dotView.isHidden = (scheme == .leftRuleC)

        for gauge in allGauges {
            gauge.applyTheme()
        }
        needsLayout = true
    }

    var preferredHeight: CGFloat {
        let active = visibleGauges
        guard !active.isEmpty else { return 0 }
        let headerH: CGFloat = 13
        let gaugeH = active[0].rowHeight
        let gap: CGFloat = (scheme == .inlineB) ? 3.5 : 5.0
        let gaugesTotal = CGFloat(active.count) * gaugeH + CGFloat(max(0, active.count - 1)) * gap

        switch scheme {
        case .cardA:
            return 7 + headerH + 4 + gaugesTotal + 8
        case .inlineB:
            return 6 + headerH + 3.5 + gaugesTotal + 2
        case .leftRuleC:
            return 2 + headerH + 4 + gaugesTotal + 2
        }
    }

    override func layout() {
        super.layout()
        let active = visibleGauges
        guard !active.isEmpty else { return }

        let headerH: CGFloat = 13
        let gaugeH = active[0].rowHeight
        let gap: CGFloat = (scheme == .inlineB) ? 3.5 : 5.0

        let contentX: CGFloat
        let contentW: CGFloat
        var y: CGFloat

        switch scheme {
        case .cardA:
            cardBox.frame = bounds
            contentX = 10
            contentW = max(0, bounds.width - 20)
            y = 7
            dotView.frame = CGRect(x: contentX, y: y + 4, width: 5, height: 5)
            headerLabel.frame = CGRect(x: contentX + 9, y: y, width: contentW - 9, height: headerH)
            y += headerH + 4

        case .inlineB:
            topDivider.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
            contentX = 2
            contentW = max(0, bounds.width - 4)
            y = 6
            dotView.frame = CGRect(x: contentX, y: y + 4, width: 5, height: 5)
            headerLabel.frame = CGRect(x: contentX + 9, y: y, width: contentW - 9, height: headerH)
            y += headerH + 3.5

        case .leftRuleC:
            leftRule.frame = CGRect(x: 4, y: 2, width: 2, height: max(0, bounds.height - 4))
            contentX = 14
            contentW = max(0, bounds.width - 18)
            y = 2
            headerLabel.frame = CGRect(x: contentX, y: y, width: contentW, height: headerH)
            y += headerH + 4
        }

        for gauge in active {
            gauge.frame = CGRect(x: contentX, y: y, width: contentW, height: gaugeH)
            y += gaugeH + gap
        }
    }

    func setHeaderTitle(_ text: String) {
        headerLabel.stringValue = text
    }
}

/// A layer-backed pill button for the sidebar footer (`+ Session`, `+ Server…`,
/// and the live A/B/C scheme switcher). Built from plain subviews rather than
/// `NSButton` bezel drawing so it respects `ChromeTheme` and avoids macOS 26
/// backing-layer overhang.
final class SidebarPillButton: NSView {
    var onClick: (() -> Void)?
    var isSelected: Bool = false {
        didSet {
            if isSelected != oldValue { applyTheme() }
        }
    }

    private let label = NSTextField(labelWithString: "")
    private var hovered = false
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(title: String, fontSize: CGFloat = 10.5, weight: NSFont.Weight = .medium) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        label.stringValue = title
        label.font = .systemFont(ofSize: fontSize, weight: weight)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = false
        label.refusesFirstResponder = true
        addSubview(label)

        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func applyTheme() {
        let theme = ChromeTheme.current
        if isSelected {
            layer?.backgroundColor = theme.accent.withAlphaComponent(0.22).cgColor
            layer?.borderColor = theme.accent.withAlphaComponent(0.65).cgColor
            label.textColor = theme.text
        } else if hovered {
            layer?.backgroundColor = theme.hover.withAlphaComponent(0.85).cgColor
            layer?.borderColor = theme.separator.cgColor
            label.textColor = theme.text
        } else {
            layer?.backgroundColor = theme.hover.withAlphaComponent(0.42).cgColor
            layer?.borderColor = theme.separator.cgColor
            label.textColor = theme.mutedText
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        applyTheme()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        applyTheme()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func layout() {
        super.layout()
        let textH = ceil(label.attributedStringValue.size().height)
        let y = floor((bounds.height - textH) / 2)
        label.frame = CGRect(x: 4, y: y, width: max(0, bounds.width - 8), height: textH)
    }
}

