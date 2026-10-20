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
    private let fillGradient = CAGradientLayer()

    /// The brand accent color used to produce the subtle ambient glow and flowing gradient.
    var accentColor: NSColor = .systemBlue {
        didSet {
            if accentColor != oldValue { apply() }
        }
    }

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

        track.wantsLayer = true
        track.layer?.cornerRadius = 2.0
        track.layer?.masksToBounds = false

        fill.wantsLayer = true
        fillGradient.cornerRadius = 2.0
        fillGradient.startPoint = CGPoint(x: 0, y: 0.5)
        fillGradient.endPoint = CGPoint(x: 1, y: 0.5)
        fill.layer = fillGradient
        fill.layer?.masksToBounds = false

        mark.wantsLayer = true
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

        // 保持纯粹的品牌流光渐变与专属微发光，不随用量高低变色
        let colors = Self.flowingColors(for: accentColor).map { $0.cgColor }
        fillGradient.colors = colors
        fillGradient.shadowColor = accentColor.cgColor
        fillGradient.shadowRadius = 3.5
        fillGradient.shadowOpacity = 0.50
        fillGradient.shadowOffset = .zero

        track.layer?.backgroundColor = theme.faintText.withAlphaComponent(0.18).cgColor
        mark.layer?.backgroundColor = theme.text.withAlphaComponent(0.65).cgColor

        toolTip = Self.tooltip(for: usage, title: titleLabel.stringValue)
        needsLayout = true
    }

    private static func flowingColors(for base: NSColor) -> [NSColor] {
        guard let srgb = base.usingColorSpace(.sRGB) else { return [base, base] }
        let c1 = NSColor(
            srgbRed: max(0, srgb.redComponent * 0.92),
            green: max(0, srgb.greenComponent * 0.92),
            blue: max(0, srgb.blueComponent * 0.92),
            alpha: 1.0
        )
        let c2 = NSColor(
            srgbRed: min(1, srgb.redComponent * 1.16 + 0.04),
            green: min(1, srgb.greenComponent * 1.16 + 0.04),
            blue: min(1, srgb.blueComponent * 1.16 + 0.04),
            alpha: 1.0
        )
        return [c1, c2]
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
        fillGradient.frame = fill.bounds
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
        /// A light stone, so the pip stays visible on the dark rail without
        /// borrowing Claude's orange or Gemini's blue. The bar itself is
        /// still the green / amber / red usage colour; this is only the dot.
        static let grok = ProviderDescriptor(
            title: "Grok",
            accent: NSColor(srgbRed: 0.82, green: 0.84, blue: 0.88, alpha: 1.0)
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
        cardBox.layer?.borderWidth = 0
        leftRule.layer?.cornerRadius = 1
        dotView.layer?.cornerRadius = 2.5

        headerLabel.stringValue = provider.title
        headerLabel.font = .systemFont(ofSize: 9.5, weight: .semibold)
        headerLabel.isSelectable = false
        headerLabel.refusesFirstResponder = true
        addSubview(headerLabel)

        for gauge in allGauges {
            gauge.accentColor = provider.accent
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

    var hideCardBackground: Bool = false {
        didSet {
            if hideCardBackground != oldValue {
                cardBox.isHidden = hideCardBackground || (scheme != .cardA)
                needsLayout = true
            }
        }
    }

    func applyTheme() {
        let theme = ChromeTheme.current
        headerLabel.textColor = theme.mutedText
        dotView.layer?.backgroundColor = provider.accent.cgColor

        cardBox.layer?.backgroundColor = theme.hover.withAlphaComponent(0.42).cgColor
        cardBox.layer?.borderWidth = 0
        cardBox.layer?.borderColor = nil
        topDivider.layer?.backgroundColor = theme.separator.cgColor
        leftRule.layer?.backgroundColor = provider.accent.withAlphaComponent(0.6).cgColor

        cardBox.isHidden = hideCardBackground || (scheme != .cardA)
        topDivider.isHidden = (scheme != .inlineB)
        leftRule.isHidden = (scheme != .leftRuleC)
        dotView.isHidden = (scheme == .leftRuleC)

        for gauge in allGauges {
            gauge.applyTheme()
        }
        needsLayout = true
    }

    var compactHeight: CGFloat {
        let active = visibleGauges
        guard !active.isEmpty else { return 0 }
        let headerH: CGFloat = 13
        let gaugeH = active[0].rowHeight
        let gap: CGFloat = 4.0
        let gaugesTotal = CGFloat(active.count) * gaugeH + CGFloat(max(0, active.count - 1)) * gap
        return headerH + 3.5 + gaugesTotal
    }

    var preferredHeight: CGFloat {
        if hideCardBackground { return compactHeight }
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
            contentX = hideCardBackground ? 0 : 10
            contentW = hideCardBackground ? bounds.width : max(0, bounds.width - 20)
            y = hideCardBackground ? 0 : 7
            dotView.frame = CGRect(x: contentX, y: y + 4, width: 5, height: 5)
            headerLabel.frame = CGRect(x: contentX + 9, y: y, width: max(0, contentW - 9), height: headerH)
            y += headerH + 4

        case .inlineB:
            topDivider.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
            contentX = 2
            contentW = max(0, bounds.width - 4)
            y = 6
            dotView.frame = CGRect(x: contentX, y: y + 4, width: 5, height: 5)
            headerLabel.frame = CGRect(x: contentX + 9, y: y, width: max(0, contentW - 9), height: headerH)
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

/// An integrated, borderless deck (Scheme 2) that groups all active provider
/// rate-limit sections into a unified translucent capsule, separated by
/// subtle hairline dividers.
final class UsageDeckView: NSView {
    let grokSection = UsageProviderSectionView(provider: .grok, scheme: .cardA)
    let claudeSection = UsageProviderSectionView(provider: .claude, scheme: .cardA)
    let geminiSection = UsageProviderSectionView(provider: .gemini, scheme: .cardA)

    private var dividers = [NSView]()

    override var isFlipped: Bool { true }

    var allSections: [UsageProviderSectionView] {
        [grokSection, claudeSection, geminiSection]
    }

    var visibleSections: [UsageProviderSectionView] {
        allSections.filter { !$0.isHidden && $0.compactHeight > 0 }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 0
        layer?.masksToBounds = false
        isHidden = true

        for s in allSections {
            s.hideCardBackground = true
            addSubview(s)
        }
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func applyTheme() {
        let theme = ChromeTheme.current
        layer?.backgroundColor = theme.hover.withAlphaComponent(0.40).cgColor

        for s in allSections {
            s.applyTheme()
            s.hideCardBackground = true
        }

        for d in dividers {
            d.layer?.backgroundColor = theme.separator.withAlphaComponent(0.35).cgColor
        }
        needsLayout = true
    }

    func showClaudeUsage(_ usage: AccountUsage?) {
        guard claudeSection.usage != usage else { return }
        claudeSection.usage = usage
        syncVisibility()
    }

    func showGeminiUsage(_ usage: AccountUsage?) {
        guard geminiSection.usage != usage else { return }
        geminiSection.usage = usage
        syncVisibility()
    }

    func showGrokUsage(_ usage: AccountUsage?) {
        guard grokSection.usage != usage else { return }
        grokSection.usage = usage
        syncVisibility()
    }

    private func syncVisibility() {
        let active = visibleSections
        let shouldHide = active.isEmpty
        if isHidden != shouldHide {
            isHidden = shouldHide
        }
        needsLayout = true
    }

    var preferredHeight: CGFloat {
        let active = visibleSections
        guard !active.isEmpty else { return 0 }
        let topPad: CGFloat = 8
        let bottomPad: CGFloat = 8
        let gap: CGFloat = 7
        var total: CGFloat = topPad + bottomPad
        for (idx, section) in active.enumerated() {
            total += section.compactHeight
            if idx < active.count - 1 {
                total += gap + 1
            }
        }
        return total
    }

    override func layout() {
        super.layout()
        let active = visibleSections
        guard !active.isEmpty else {
            for d in dividers { d.isHidden = true }
            return
        }

        let theme = ChromeTheme.current
        let topPad: CGFloat = 8
        let gap: CGFloat = 7
        let insetX: CGFloat = 9
        let contentW = max(0, bounds.width - insetX * 2)

        let neededDividers = max(0, active.count - 1)
        while dividers.count < neededDividers {
            let d = NSView()
            d.wantsLayer = true
            d.layer?.backgroundColor = theme.separator.withAlphaComponent(0.35).cgColor
            dividers.append(d)
            addSubview(d)
        }
        for (i, d) in dividers.enumerated() {
            d.isHidden = (i >= neededDividers)
        }

        var y: CGFloat = topPad
        for (idx, section) in active.enumerated() {
            let h = section.compactHeight
            section.frame = CGRect(x: insetX, y: y, width: contentW, height: h)
            section.needsLayout = true
            y += h

            if idx < active.count - 1 {
                y += floor(gap / 2)
                dividers[idx].frame = CGRect(x: insetX, y: y, width: contentW, height: 1)
                y += 1 + ceil(gap / 2)
            }
        }
    }
}

