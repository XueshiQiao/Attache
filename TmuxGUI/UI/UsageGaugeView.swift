//
//  UsageGaugeView.swift
//  TmuxGUI
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
    static let height: CGFloat = 21

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
            bar.layer?.cornerRadius = 2.5
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

        let barHeight: CGFloat = 5
        track.frame = CGRect(x: 0, y: labelHeight + 3, width: bounds.width, height: barHeight)
        // Clamped for drawing only. `usedPercent` itself is kept as reported,
        // because being over the limit is a real answer and a bar cannot show
        // it — which is why the tooltip carries the number in words.
        let used = min(1, max(0, Double(usage.usedPercent) / 100))
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * used, height: barHeight)

        let elapsed = usage.elapsedFraction()
        let markWidth: CGFloat = 1.5
        // Kept inside the track at both ends, so a window that has just opened
        // or just closed still shows the mark rather than half of it.
        let markX = min(bounds.width - markWidth, max(0, bounds.width * elapsed - markWidth / 2))
        mark.frame = CGRect(x: markX, y: -1.5, width: markWidth, height: barHeight + 3)
    }
}
