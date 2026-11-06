//
//  ChatStyle.swift
//  Attache
//

import Cocoa

/// How the chat page looks, apart from what it shows.
///
/// The page's content and behaviour (`ChatPaneView`, `AgentChatModel`) are
/// one thing; this is everything the owner might want drawn another way.
/// Two looks were chosen from the mock-ups (`docs/chat-ui-designs.html`,
/// 2026-11-06), and each is a value here rather than a branch at every
/// drawing site — a third look is a new case, not a new page.
///
/// - `card` (mock-up 3): the window keeps its glass, and the conversation is
///   a solid rounded sheet set into it with a margin, the way the terminal's
///   pane cards sit; tool steps step back (small grey lines, the tool's name
///   a monospaced tag in front, thinking a thin rule — hierarchy mock-up A in
///   `docs/chat-hierarchy-designs.html`); the composer is a pill.
/// - `glass` (mock-up 1): one sheet of glass for the whole window, with
///   every reply on a solid card of its own so text never sits on the
///   wallpaper; tool steps share a card; the composer is a raised card.
///
/// Chosen by `chat_style` in the settings file.
enum ChatStyle: String {
    case card
    case glass

    @MainActor static var current: ChatStyle { AppSettings.chatStyle }

    /// The margin around the solid sheet, or nil for no sheet: the page is
    /// the window's glass.
    var sheetInset: NSEdgeInsets? {
        switch self {
        case .card: NSEdgeInsets(top: 4, left: 2, bottom: 10, right: 10)
        case .glass: nil
        }
    }

    var sheetRadius: CGFloat { 12 }

    /// Whether each reply sits on a solid card of its own.
    var repliesOnCards: Bool { self == .glass }

    /// `quiet`: small grey lines that step back from the replies. `timeline`:
    /// a rule with a dot per step. `card`: a bordered card.
    enum ToolLayout { case quiet, timeline, card }
    var toolLayout: ToolLayout { self == .card ? .quiet : .card }

    /// The person's own messages: a tint with ordinary text, or the accent
    /// itself with text on it.
    var userBubbleIsSolid: Bool { self == .glass }

    /// The composer's corners: a pill, or a card's.
    func composerRadius(height: CGFloat) -> CGFloat {
        self == .card ? height / 2 : 12
    }
}
