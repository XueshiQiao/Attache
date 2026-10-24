//
//  TmuxPaneColours.swift
//  Attache
//

import Foundation

/// The colours a program in a pane is told its terminal has, as the
/// `refresh-client -r` reports that tell tmux.
///
/// A program that picks its own palette from the terminal's background —
/// Claude Code's `auto` theme is the one that prompted this — asks with OSC 11,
/// and tmux answers for the terminal. With no report, tmux 3.6a answers from
/// the first client on the session in attach order, and a control client
/// counts as one whose background is black: measured 2026-10-24 on an isolated
/// `-L` server, a pane with nothing but a control client attached is answered
/// `rgb:0000/0000/0000` and `997;1` (dark). This app attaches its control
/// client before its terminal, so every pane was told "dark" over a light
/// scheme — and while Ghostty.app was attached first, it was told whatever
/// Ghostty.app's own theme was.
///
/// A report from a control client outranks every client
/// (`window_pane_get_bg_control_client` is consulted first), so it is the
/// colour this app's terminal actually paints that the pane hears.
nonisolated struct TmuxPaneColours: Equatable {
    /// Six hex digits each, lowercased, no `#`.
    let foreground: String
    let background: String

    /// From the theme catalog's hex strings. nil for anything that is not six
    /// hex digits (an optional leading `#` allowed): the result is spliced
    /// into a command line, so nothing else may reach it.
    init?(foreground: String, background: String) {
        guard let fg = Self.normalised(foreground), let bg = Self.normalised(background)
        else { return nil }
        self.foreground = fg
        self.background = bg
    }

    /// One command per colour, because tmux keeps only the last `-r` given to
    /// a single `refresh-client`.
    ///
    /// Double quotes, because tmux's parser turns `\033` into ESC only
    /// inside them; `\\` is the backslash of the ST terminator. The pane id
    /// is checked rather than trusted, for the same reason the colours are.
    func reportCommands(paneID: String) -> [String] {
        guard paneID.first == "%", paneID.count > 1,
              paneID.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else { return [] }
        return [("10", foreground), ("11", background)].map { code, hex in
            "refresh-client -r \"\(paneID):\\033]\(code);\(Self.xcolor(hex))\\033\\\\\""
        }
    }

    /// The command that makes tmux tell running programs to ask again:
    /// the global `window-style`, written back with the value it already has.
    ///
    /// A report changes what tmux *answers*, not what it *says*: measured on
    /// an isolated 3.6a server, a pane with mode 2031 on heard nothing when
    /// the report moved from light to dark. tmux sends `997` only to panes
    /// flagged `PANE_THEMECHANGED`, and of the things that set that flag the
    /// only one a control client can cause without changing anything is
    /// setting `window-style` — which flags every pane on the server, even
    /// when the value is the one already there. Measured: report light,
    /// re-set, the pane hears `997;2`; report dark, re-set, it hears `997;1`;
    /// a window-level `window-style` is untouched by the global write.
    ///
    /// Read and written back rather than appended to: `set-option -gwa
    /// window-style ''` looks like a no-op and is not — measured 2026-10-24,
    /// `fg=colour3,bg=default` came back `fg=colour3,bg=default,,` after two.
    ///
    /// nil when the value would not come back byte for byte: `quote` drops
    /// control characters, and a style may legally hold a newline. No
    /// announcement is better than a changed option.
    static func reassertWindowStyle(currentValue value: String) -> String? {
        guard value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
        else { return nil }
        return "set-option -gw window-style \(TmuxCommand.quote(value))"
    }

    /// `rrggbb` → `rgb:rrrr/gggg/bbbb`, the form terminals answer OSC 10/11
    /// with and the one tmux's report parser was written against.
    static func xcolor(_ hex: String) -> String {
        let chars = Array(hex)
        let channels = stride(from: 0, to: 6, by: 2).map { String(chars[$0 ..< $0 + 2]) }
        return "rgb:" + channels.map { $0 + $0 }.joined(separator: "/")
    }

    private static func normalised(_ text: String) -> String? {
        let hex = (text.hasPrefix("#") ? String(text.dropFirst()) : text).lowercased()
        // `isHexDigit` alone admits the fullwidth forms.
        guard hex.count == 6, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return hex
    }
}
