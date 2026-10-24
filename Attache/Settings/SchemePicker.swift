//
//  SchemePicker.swift
//  Attache
//

import AppKit
import GhosttyTheme
import SwiftUI

// The terminal scheme section of the Appearance page.
//
// Two slots, one scheme each — the one used in light mode and the one used in
// dark mode — and a list that edits whichever slot is selected. That was
// always the model; what the old page got wrong was saying so. A segmented
// control in front of all 485 schemes read as a filter, and finding one of
// the 87 light schemes for the light slot meant scrolling past 398 dark ones.
// So the slots are cards now, and the list opens on the schemes that suit the
// slot being edited, with Light / Dark / All one click away — a dark scheme
// in light mode is unusual, not wrong, and stays possible.

/// Light or dark by the background's L*, the rule `ChromeTheme` and its check
/// use, so this page and the chrome never disagree about a scheme. 398 dark
/// and 87 light in the catalog as shipped.
enum SchemeTone {
    static func isDark(_ definition: GhosttyThemeDefinition) -> Bool {
        if let cached = cache[definition.name] { return cached }
        let dark = ChromeTheme.color(hex: definition.background)
            .map { ChromeTheme.lightness(of: $0) < 50 } ?? true
        cache[definition.name] = dark
        return dark
    }

    @MainActor private static var cache = [String: Bool]()
}

/// Which schemes the list shows. nil in `SchemePickerSection` means "the one
/// that suits the slot", so switching slots puts the list back on it.
enum SchemeFilter: String, CaseIterable {
    case light, dark, all

    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .all: "All"
        }
    }

    @MainActor func admits(_ definition: GhosttyThemeDefinition) -> Bool {
        switch self {
        case .all: true
        case .dark: SchemeTone.isDark(definition)
        case .light: !SchemeTone.isDark(definition)
        }
    }
}

struct SchemePickerSection: View {
    @EnvironmentObject var store: SettingsStore
    /// The window's own scheme, which follows the app's appearance — what
    /// "Follow System" resolves against, observed rather than read once.
    @Environment(\.colorScheme) private var colorScheme

    @State private var editingDarkSlot: Bool?
    @State private var filter: SchemeFilter?
    @State private var query = ""
    /// The scheme under the pointer or the keyboard cursor: what the preview
    /// shows instead of the slot's own until it is clicked.
    @State private var previewName: String?
    @State private var keyboardIndex: Int?
    /// Bumped to put the keyboard in the search field: on appear, and after
    /// a slot card took the click.
    @State private var focusRequest = 0
    @State private var scrollToSelection = 0
    /// When the keyboard last moved the cursor. A list scrolled by the
    /// keyboard slides a new tile under a pointer that has not moved, and
    /// that hover must not take the cursor back.
    @State private var lastKeyboardMove = Date.distantPast

    /// Two fixed columns, so ↑ and ↓ can move by a row without measuring.
    private static let columns = 2

    // MARK: Derived state

    private var liveSlotIsDark: Bool {
        switch store.appearance {
        case .system: colorScheme == .dark
        case .light: false
        case .dark: true
        }
    }

    /// Opens on the slot that is on screen, so the list starts on the scheme
    /// the user is looking at.
    private var isEditingDarkSlot: Bool { editingDarkSlot ?? liveSlotIsDark }

    /// The tone that suits the slot — unless the slot holds a scheme of the
    /// other tone, which would then be filtered out of its own list.
    private var currentFilter: SchemeFilter {
        if let filter { return filter }
        let dark = isEditingDarkSlot
        let own = definition(named: slotName(dark: dark), dark: dark)
        guard SchemeTone.isDark(own) == dark else { return .all }
        return dark ? .dark : .light
    }

    private func slotName(dark: Bool) -> String {
        dark ? store.darkThemeName : store.lightThemeName
    }

    private func definition(named name: String, dark: Bool) -> GhosttyThemeDefinition {
        AppSettings.themeDefinition(
            named: name,
            default: dark ? AppSettings.defaultDarkThemeName : AppSettings.defaultLightThemeName
        )
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// Case and spaces ignored on both sides, so `ayulight` finds `Ayu Light`
    /// — a scheme's spacing is not something anyone types from memory.
    private func matches(_ definition: GhosttyThemeDefinition) -> Bool {
        trimmedQuery.isEmpty || Self.folded(definition.name).contains(Self.folded(trimmedQuery))
    }

    private static func folded(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    private var visible: [GhosttyThemeDefinition] {
        SettingsStore.allThemes.filter { currentFilter.admits($0) && matches($0) }
    }

    private func count(_ filter: SchemeFilter) -> Int {
        SettingsStore.allThemes.filter { filter.admits($0) && matches($0) }.count
    }

    // MARK: Actions

    private func choose(_ name: String) {
        if isEditingDarkSlot {
            store.setDarkThemeName(name)
        } else {
            store.setLightThemeName(name)
        }
        previewName = nil
    }

    private func editSlot(dark: Bool) {
        editingDarkSlot = dark
        query = ""
        keyboardIndex = nil
        previewName = nil
        filter = nil
        focusRequest += 1
        // Even when the slot did not change — a second click on the same
        // card — the list goes back to the slot's own scheme.
        scrollToSelection += 1
    }

    /// ↓ from the field lands on the first scheme; after that ↑↓ step one
    /// scheme at a time in reading order. Not a row at a time: ← → belong to
    /// the field's own caret, so a row step would leave the right column
    /// unreachable.
    @discardableResult
    private func moveKeyboard(by step: Int) -> Bool {
        let list = visible
        guard !list.isEmpty else { return false }
        let next = keyboardIndex.map { min(list.count - 1, max(0, $0 + step)) } ?? 0
        keyboardIndex = next
        previewName = list[next].name
        lastKeyboardMove = Date()
        return true
    }

    @discardableResult
    private func chooseKeyboardSelection() -> Bool {
        let list = visible
        guard let index = keyboardIndex, list.indices.contains(index) else { return false }
        choose(list[index].name)
        return true
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                slotCard(dark: false)
                slotCard(dark: true)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    searchField
                    filterPicker
                    grid
                }
                .frame(width: 262)
                preview
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(.vertical, 4)
        .onAppear { focusRequest += 1 }
    }

    // MARK: Slots

    private func slotCard(dark: Bool) -> some View {
        let scheme = definition(named: slotName(dark: dark), dark: dark)
        let isLive = liveSlotIsDark == dark
        let pinnedAway = store.appearance != .system && !isLive
        let mismatched = SchemeTone.isDark(scheme) != dark
        let selected = isEditingDarkSlot == dark
        return Button { editSlot(dark: dark) } label: {
            HStack(spacing: 10) {
                SchemeChip(definition: scheme)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(dark ? "In dark mode" : "In light mode")
                            .font(.caption).foregroundStyle(.secondary)
                        if isLive {
                            badge("Showing now", fill: .green, text: .white)
                        } else if pinnedAway {
                            Text("Not used while pinned to \(store.appearance.title)")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        if mismatched {
                            badge(SchemeTone.isDark(scheme) ? "Dark scheme" : "Light scheme",
                                  fill: .orange.opacity(0.18), text: .orange)
                        }
                    }
                    Text(scheme.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1),
                                  lineWidth: selected ? 2 : 1)
            )
            .opacity(pinnedAway ? 0.65 : 1)
        }
        .buttonStyle(.plain)
    }

    private func badge(_ text: String, fill: Color, text textColour: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(textColour)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(fill))
            .lineLimit(1)
            .fixedSize()
    }

    // MARK: List

    private var searchField: some View {
        NativeSearchField(
            text: $query,
            placeholder: "Search schemes",
            focusRequest: focusRequest,
            onMove: { up in moveKeyboard(by: keyboardIndex == nil ? 0 : (up ? -1 : 1)) },
            onSubmit: { _ = chooseKeyboardSelection() }
        )
    }

    private var filterPicker: some View {
        Picker(selection: Binding(
            get: { currentFilter },
            set: { filter = $0; keyboardIndex = nil; previewName = nil }
        )) {
            ForEach(SchemeFilter.allCases, id: \.self) { option in
                Text("\(option.title) \(count(option))").tag(option)
            }
        } label: { EmptyView() }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
    }

    private var grid: some View {
        let list = visible
        let selectedName = slotName(dark: isEditingDarkSlot)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // A fixed target for "back to the top": the first scheme is
                    // not one when the list is empty or not yet laid out.
                    Color.clear.frame(height: 0).id(Self.gridTop)
                    if list.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: Self.columns),
                            spacing: 6
                        ) {
                            ForEach(Array(list.enumerated()), id: \.element.name) { index, scheme in
                                SchemeTile(
                                    definition: scheme,
                                    query: trimmedQuery,
                                    isSelected: scheme.name == selectedName,
                                    hasKeyboardCursor: index == keyboardIndex
                                )
                                .onTapGesture { choose(scheme.name) }
                                .onHover { inside in
                                    // The pointer moving onto a tile takes the
                                    // preview over from the keyboard cursor, so
                                    // the dashed tile and the preview never name
                                    // two different schemes.
                                    guard Date().timeIntervalSince(lastKeyboardMove) > 0.4 else { return }
                                    if inside {
                                        keyboardIndex = nil
                                        previewName = scheme.name
                                    } else if previewName == scheme.name, keyboardIndex == nil {
                                        previewName = nil
                                    }
                                }
                                .id(scheme.name)
                            }
                        }
                        .padding(2)
                    }
                }
            }
            .frame(height: 360)
            // The old list kept its scroll offset when a search shortened it,
            // which can leave a filtered list scrolled past its own end and
            // looking empty. Back to the top on every change of what is shown.
            // Opens on the slot's own scheme rather than the top of the list.
            // On the next turn, once the lazy grid has laid out rows to
            // scroll among.
            .onAppear {
                DispatchQueue.main.async { proxy.scrollTo(selectedName, anchor: .center) }
            }
            .onChange(of: isEditingDarkSlot) {
                let name = slotName(dark: isEditingDarkSlot)
                DispatchQueue.main.async { proxy.scrollTo(name, anchor: .center) }
            }
            .onChange(of: scrollToSelection) {
                let name = slotName(dark: isEditingDarkSlot)
                DispatchQueue.main.async { proxy.scrollTo(name, anchor: .center) }
            }
            .onChange(of: trimmedQuery) { scrollToTop(proxy, list: visible) }
            .onChange(of: currentFilter) { scrollToTop(proxy, list: visible) }
            .onChange(of: keyboardIndex) {
                guard let index = keyboardIndex, visible.indices.contains(index) else { return }
                proxy.scrollTo(visible[index].name)
            }
        }
    }

    private static let gridTop = "scheme-grid-top"

    /// What is shown changed, so a preview of something possibly no longer
    /// in it goes too — the dashed tile and the preview never part company.
    private func scrollToTop(_ proxy: ScrollViewProxy, list _: [GhosttyThemeDefinition]) {
        keyboardIndex = nil
        previewName = nil
        proxy.scrollTo(Self.gridTop, anchor: .top)
    }

    private var emptyState: some View {
        let others = SettingsStore.allThemes.filter { matches($0) && !currentFilter.admits($0) }.count
        return VStack(spacing: 8) {
            Text("No \(currentFilter.title.lowercased()) schemes match “\(trimmedQuery)”.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if others > 0 {
                Text("\(others) other scheme\(others == 1 ? "" : "s") match.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show All") { filter = .all }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: Preview

    private var preview: some View {
        let dark = isEditingDarkSlot
        let current = slotName(dark: dark)
        let shownName = previewName ?? current
        let scheme = definition(named: shownName, dark: dark)
        let previewing = shownName != current
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(scheme.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(SchemeTone.isDark(scheme) ? "Dark" : "Light")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(previewing ? "Previewing — click to use" : "Current for \(dark ? "dark" : "light") mode")
                    .font(.caption)
                    .foregroundStyle(previewing ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
            SchemeSession(definition: scheme, fontFamily: store.fontFamily)
            SchemePalette(definition: scheme)
        }
    }
}

// MARK: - Pieces

private func colour(_ hex: String?) -> Color? {
    hex.flatMap(ChromeTheme.color(hex:)).map(Color.init(nsColor:))
}

/// The slot card's thumbnail: background, two strokes of text, six colours.
private struct SchemeChip: View {
    let definition: GhosttyThemeDefinition

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(colour(definition.foreground) ?? .primary).frame(width: 26, height: 3)
            Capsule().fill(colour(definition.palette[4]) ?? .blue).frame(width: 16, height: 3)
            HStack(spacing: 2) {
                ForEach(1 ... 6, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1).fill(colour(definition.palette[index]) ?? .clear)
                        .frame(height: 5)
                }
            }
        }
        .padding(5)
        .frame(width: 46, height: 36)
        .background(RoundedRectangle(cornerRadius: 6).fill(colour(definition.background) ?? .clear))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15)))
    }
}

/// One scheme in the list: enough to scan by — a prompt, a diff line and the
/// eight normal colours — with the full picture left to the preview.
private struct SchemeTile: View {
    let definition: GhosttyThemeDefinition
    let query: String
    let isSelected: Bool
    let hasKeyboardCursor: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            VStack(alignment: .leading, spacing: 1) {
                (Text("❯ ").foregroundColor(colour(definition.palette[2]))
                    + Text("git diff").foregroundColor(colour(definition.foreground)))
                (Text("- old ").foregroundColor(colour(definition.palette[1]))
                    + Text("+ new").foregroundColor(colour(definition.palette[2])))
                HStack(spacing: 2) {
                    ForEach(0 ..< 8, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(colour(definition.palette[index]) ?? .clear)
                            .frame(height: 6)
                    }
                }
                .padding(.top, 4)
            }
            .font(.system(size: 9.5, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(colour(definition.background) ?? .clear))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15)))

            HStack(spacing: 3) {
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
                Text(highlightedName).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, 2)
        }
        .padding(3)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(hasKeyboardCursor ? Color.accentColor.opacity(0.7) : .clear,
                              style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
        )
        .help(definition.name)
    }

    private var highlightedName: AttributedString {
        var text = AttributedString(definition.name)
        if !query.isEmpty, let range = text.range(of: query, options: .caseInsensitive) {
            text[range].backgroundColor = .yellow.opacity(0.45)
        }
        return text
    }
}

/// A short real session in the scheme: the colours programs actually reach
/// for, each in the place they reach for it — `ls` (blue directories, green
/// executables, cyan links), a diff (red and green), a comment in bright
/// black (the faint text light schemes most often lose), a yellow warning,
/// and a selection and cursor in the scheme's own colours.
private struct SchemeSession: View {
    let definition: GhosttyThemeDefinition
    let fontFamily: String

    var body: some View {
        Text(session)
            .font(fontFamily.isEmpty
                ? .system(size: 11, design: .monospaced)
                : .custom(fontFamily, fixedSize: 11))
            .lineSpacing(2)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(colour(definition.background) ?? .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.15)))
            .clipped()
    }

    private var session: AttributedString {
        var out = AttributedString()
        func add(_ text: String, _ index: Int? = nil, bold: Bool = false,
                 foreground: String? = nil, background: String? = nil)
        {
            var run = AttributedString(text)
            let hex = foreground ?? index.flatMap { definition.palette[$0] } ?? definition.foreground
            run.foregroundColor = colour(hex)
            if let background { run.backgroundColor = colour(background) }
            if bold { run.inlinePresentationIntent = .stronglyEmphasized }
            out += run
        }
        func prompt() {
            add("~/code", 4); add(" "); add("main", 5); add(" "); add("❯", 2); add(" ")
        }
        prompt(); add("ls\n")
        add("docs", 4, bold: true); add("  "); add("src", 4, bold: true); add("  ")
        add("build.sh", 2); add("  "); add("latest", 6); add("  "); add("README.md\n")
        add("\n")
        prompt(); add("git diff\n")
        add("@@ -12,3 +12,3 @@\n", 6)
        add("- let theme = \"dark\"\n", 1)
        add("+ let theme = ", 2)
        add("scheme.name",
            foreground: definition.selectionForeground ?? definition.foreground,
            background: definition.selectionBackground ?? definition.palette[8])
        add(" ", foreground: definition.cursorText ?? definition.background,
            background: definition.cursorColor ?? definition.foreground)
        add("\n")
        add("  // follows the system appearance\n", 8)
        add("\n")
        add("warning:", 3); add(" 2 files changed")
        return out
    }
}

/// All sixteen colours, normal over bright, each marked when it falls under
/// 3:1 against the background — WCAG's floor for large text and graphics,
/// and the point below which a colour used for text stops being readable.
private struct SchemePalette: View {
    let definition: GhosttyThemeDefinition

    private static let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0 ..< 2, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0 ..< 8, id: \.self) { column in
                        swatch(row * 8 + column)
                    }
                }
            }
            HStack {
                Text("Top: normal · bottom: bright")
                Spacer(minLength: 8)
                Text("low: under 3:1")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
    }

    private func swatch(_ index: Int) -> some View {
        let hex = definition.palette[index]
        let ratio: CGFloat? = {
            guard let fg = hex.flatMap(ChromeTheme.color(hex:)),
                  let bg = ChromeTheme.color(hex: definition.background) else { return nil }
            return ChromeTheme.contrastRatio(fg, bg)
        }()
        let name = (index >= 8 ? "bright " : "") + Self.names[index % 8]
        return RoundedRectangle(cornerRadius: 5)
            .fill(colour(hex) ?? .clear)
            .frame(height: 24)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.15)))
            .overlay(alignment: .topTrailing) {
                if let ratio, ratio < 3 {
                    Text("low")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.orange))
                        .padding(2)
                }
            }
            .help(ratio.map { "\(name) · #\(hex ?? "") · \(String(format: "%.1f", $0)):1 on the background" } ?? name)
    }
}

// MARK: - Search field

/// AppKit's own search field — magnifier, placeholder that leaves when you
/// type, text from the left, clear button — because SwiftUI has none to put
/// in a page. A `TextField` in a grouped `Form` is not one: it lays its title
/// out as a *label* on the left and right-aligns what is typed against the
/// far edge, which is exactly how the old picker read as a search box that
/// would not take input when it had been taking it all along.
///
/// ↑ ↓ and Return come through the field editor's own commands rather than a
/// key-press hook, so an input method composing text keeps them: AppKit asks
/// the input method first and only sends `moveUp:` and `insertNewline:` here
/// once it has declined them. Escape is the field's own, which clears it.
private struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusRequest: Int
    /// `true` for ↑.
    let onMove: (Bool) -> Void
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.isAutomaticTextCompletionEnabled = false
        // The clear button on a field that is not being edited changes the
        // value without a text-change notification; the action catches it.
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        // Never under an input method's uncommitted text.
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if !composing, field.stringValue != text { field.stringValue = text }
        if context.coordinator.appliedFocusRequest != focusRequest {
            context.coordinator.appliedFocusRequest = focusRequest
            // Next turn: on the first pass the field has no window yet.
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        var appliedFocusRequest = -1

        init(parent: NativeSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        @objc func searchChanged(_ field: NSSearchField) {
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(true)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(false)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            default:
                return false
            }
        }
    }
}
